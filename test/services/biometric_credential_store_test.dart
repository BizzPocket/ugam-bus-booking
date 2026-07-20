import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/biometric_credential_store.dart';

class _FakeAuth implements BiometricAuthenticator {
  _FakeAuth({this.available = true, this.willPass = true});
  bool available;
  bool willPass;
  int calls = 0;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> authenticate(String localizedReason) async {
    calls++;
    return willPass;
  }
}

class _MemStore implements SecureKeyValueStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}

void main() {
  test('enroll then hasCredential is true for the same (normalised) phone', () async {
    final store = BiometricCredentialStore(
        authenticator: _FakeAuth(), storage: _MemStore());
    await store.enroll(phone: '+91 98765 43210', password: 'pw');
    expect(await store.hasCredential('9876543210'), isTrue);
    expect(await store.hasCredential('9999999999'), isFalse);
  });

  test('unlock returns the credential when biometric passes', () async {
    final auth = _FakeAuth(willPass: true);
    final store =
        BiometricCredentialStore(authenticator: auth, storage: _MemStore());
    await store.enroll(phone: '9876543210', password: 'pw');
    final cred = await store.unlock('9876543210');
    expect(auth.calls, 1);
    expect(cred?.password, 'pw');
    expect(cred?.phone, '9876543210');
  });

  test('unlock returns null when biometric fails', () async {
    final store = BiometricCredentialStore(
        authenticator: _FakeAuth(willPass: false), storage: _MemStore());
    await store.enroll(phone: '9876543210', password: 'pw');
    expect(await store.unlock('9876543210'), isNull);
  });

  test('unlock returns null and does not prompt when nothing enrolled', () async {
    final auth = _FakeAuth();
    final store = BiometricCredentialStore(authenticator: auth, storage: _MemStore());
    expect(await store.unlock('9876543210'), isNull);
    expect(auth.calls, 0); // biometric prompt never shown
  });

  test('clear removes the credential', () async {
    final store = BiometricCredentialStore(
        authenticator: _FakeAuth(), storage: _MemStore());
    await store.enroll(phone: '9876543210', password: 'pw');
    await store.clear();
    expect(await store.hasCredential('9876543210'), isFalse);
  });
}
