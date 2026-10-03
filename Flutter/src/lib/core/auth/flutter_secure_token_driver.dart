import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'secure_token_store.dart';

final class FlutterSecureTokenDriver implements SecureTokenDriver {
  const FlutterSecureTokenDriver({this.storage = const FlutterSecureStorage()});

  final FlutterSecureStorage storage;

  @override
  Future<SecureTokenCredential?> read({required String service}) async {
    final username = await storage.read(key: _usernameKey(service));
    final password = await storage.read(key: _passwordKey(service));
    if (username == null || password == null) {
      return null;
    }
    return SecureTokenCredential(username: username, password: password);
  }

  @override
  Future<bool> write({
    required String service,
    required String username,
    required String password,
  }) async {
    await storage.write(key: _usernameKey(service), value: username);
    await storage.write(key: _passwordKey(service), value: password);
    return true;
  }

  @override
  Future<bool> clear({required String service}) async {
    await storage.delete(key: _usernameKey(service));
    await storage.delete(key: _passwordKey(service));
    return true;
  }

  String _usernameKey(String service) => '$service.username';
  String _passwordKey(String service) => '$service.password';
}
