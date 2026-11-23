// The macOS update install (updater part 2): unpack the verified zip with ditto, accept the new bundle only if it
// satisfies the installed app's own code signing requirement (so only builds signed with our certificate replace
// it), then hand over to assets/update/swap-macos.sh, which waits for this process to quit, swaps the bundle and
// starts it again. Needs the app sandbox off (owner decision).
// Debugging: a refused bundle reports codesign's message; the swap writes swap.log next to its script.

import 'dart:io';

import 'package:flutter/services.dart';

/// The .app bundle around a macOS executable (…/gerdTV.app/Contents/MacOS/gerdTV → …/gerdTV.app).
String bundlePath(String executable) =>
    File(executable).parent.parent.parent.path;

/// The "designated => …" requirement from `codesign -d -r-` output, or null when there is none (unsigned build).
String? designatedRequirement(String codesignOutput) {
  for (final line in codesignOutput.split('\n')) {
    if (line.startsWith('designated => ')) {
      return line.substring('designated => '.length).trim();
    }
  }
  return null;
}

/// Installs [zip] in place of the running app and quits; returns an error message instead when it refuses.
Future<String?> installMacUpdate(String zip) async {
  final installed = bundlePath(Platform.resolvedExecutable);
  final work = await Directory.systemTemp.createTemp('gerdtv-update');
  final unzip = await Process.run('ditto', ['-x', '-k', zip, work.path]);
  if (unzip.exitCode != 0) return 'unzip: ${unzip.stderr}';
  final candidate = '${work.path}/gerdTV.app';
  final req = await Process.run('codesign', ['-d', '-r-', installed]);
  final requirement = designatedRequirement('${req.stdout}\n${req.stderr}');
  if (requirement == null) {
    return 'the installed app has no code signing requirement to check against';
  }
  final check = await Process.run('codesign', [
    '--verify',
    '--deep',
    '--strict',
    '-R=$requirement',
    candidate,
  ]);
  if (check.exitCode != 0) return 'refused: ${check.stderr}'.trim();
  final script = File('${work.path}/swap-macos.sh');
  await script.writeAsString(
    await rootBundle.loadString('assets/update/swap-macos.sh'),
  );
  await Process.start('/bin/bash', [
    script.path,
    '$pid',
    installed,
    candidate,
  ], mode: ProcessStartMode.detached);
  exit(0); // the swap waits for this process to end
}
