// Secrets in memory, for widget and integration tests (one copy for both): headless runners have no keyring for
// libsecret, and in widget tests the secure-storage channel never answers, so a real read would hang (the welcome
// screen's pairing reads the open profile's secrets) or, on Linux, take the app down on the first service read.
import 'package:gerdtv/services/secrets.dart';

class MemorySecrets extends Secrets {
  final logins = <String, List<String>>{};
  final services = <String, String>{};

  /// Every service write and delete, as "service.id" (a delete as "-service.id").
  final writes = <String>[];

  @override
  Future<void> write(String profileId, List<String> secrets) async =>
      logins[profileId] = secrets;

  @override
  Future<List<String>?> read(String profileId) async => logins[profileId];

  @override
  Future<void> delete(String profileId) async => logins.remove(profileId);

  @override
  Future<String?> readService(String profileId, String service) async =>
      services['$service.$profileId'];

  @override
  Future<void> writeService(
    String profileId,
    String service,
    String? token,
  ) async {
    writes.add('${token == null ? '-' : ''}$service.$profileId');
    token == null
        ? services.remove('$service.$profileId')
        : services['$service.$profileId'] = token;
  }
}
