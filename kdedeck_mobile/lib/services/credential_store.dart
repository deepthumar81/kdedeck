import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Credentials are scoped to a server endpoint and never placed in preferences.
abstract interface class CredentialStore {
  Future<String?> read(String serverKey);
  Future<void> write(String serverKey, String token);
  Future<void> delete(String serverKey);
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String serverKey) => 'kdedeck.client.token.$serverKey';

  @override
  Future<String?> read(String serverKey) => _storage.read(key: _key(serverKey));

  @override
  Future<void> write(String serverKey, String token) =>
      _storage.write(key: _key(serverKey), value: token);

  @override
  Future<void> delete(String serverKey) =>
      _storage.delete(key: _key(serverKey));
}
