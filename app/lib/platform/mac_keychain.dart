// Keychain items on macOS through Apple's own /usr/bin/security. Why not the Keychain API: besides an item's trusted
// apps, macOS checks its "partition list", and an app without an Apple-issued certificate counts there as the hash
// of that exact build (securityd, clientid.cpp). So after every update of our self-signed app each item asked for
// the keychain password again. `security` is Apple's, its partition ("apple-tool:") doesn't change with our builds.
// The cost (owner decision): any program running as the user can ask `security` for these items as well.
//
// Debugging: `security find-generic-password -s gerdTV -a <key> -w | base64 -d` in Terminal shows a value. Errors
// carry the tool's exit code only, never its input or output, which hold the secret. Codes are the low byte of an
// OSStatus: 44 = not found, 36 = the keychain is locked, 128 = cancelled.

import 'dart:convert';
import 'dart:io';

typedef SecurityRun = Future<({int exitCode, String stdout})> Function(
  List<String> args, {
  String? stdin,
});

class MacKeychain {
  /// [run] is replaced in tests; [keychain] (a file) too: normally it's the user's default, the login keychain.
  const MacKeychain({this._run = _security, this._keychain});

  final SecurityRun _run;
  final String? _keychain;

  static const _service = 'gerdTV';
  static const _notFound = 44;

  List<String> _args(
    String command,
    String key, [
    List<String> more = const [],
  ]) => [command, '-s', _service, '-a', key, ...more, ?_keychain];

  /// The value, or null when there is none. Anything else (locked, cancelled) throws: it must not look like "none".
  Future<String?> read(String key) async {
    final r = await _run(_args('find-generic-password', key, ['-w']));
    if (r.exitCode == _notFound) return null;
    if (r.exitCode != 0) throw StateError('security read: exit ${r.exitCode}');
    return utf8.decode(base64Decode(r.stdout.trim()));
  }

  /// Adds or replaces the value, then reads it back, because `security -i` doesn't report failures reliably.
  Future<void> write(String key, String value) async {
    // base64: no quoting in the command, and `-w` prints non-ASCII values as hex when reading.
    final data = base64Encode(utf8.encode(value));
    final path = _keychain == null ? '' : ' "$_keychain"';
    // On stdin (-i), not as arguments, which every process can see in `ps`. The line ends with a newline or the
    // tool drops it. -U: replace an existing item.
    final line =
        'add-generic-password -U -s $_service -a "$key" -w "$data"$path\n';
    // security cuts a line at 4095 bytes and would store the first part of the value.
    if (line.length > 4095) throw StateError('security write: too long');
    await _run(['-i'], stdin: line);
    if (await read(key) != value) {
      throw StateError('security write: not stored');
    }
  }

  Future<void> delete(String key) async {
    final r = await _run(_args('delete-generic-password', key));
    if (r.exitCode != 0 && r.exitCode != _notFound) {
      throw StateError('security delete: exit ${r.exitCode}');
    }
  }
}

Future<({int exitCode, String stdout})> _security(
  List<String> args, {
  String? stdin,
}) async {
  final p = await Process.start('/usr/bin/security', args);
  final out = p.stdout.transform(utf8.decoder).join();
  // Read and dropped: a full pipe would block the tool, and its messages could hold the secret.
  final err = p.stderr.drain<void>();
  if (stdin != null) p.stdin.write(stdin);
  await p.stdin.close();
  await err;
  return (exitCode: await p.exitCode, stdout: await out);
}
