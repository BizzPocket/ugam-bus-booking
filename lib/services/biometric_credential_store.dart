import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import '../utils/phone_normalize.dart';

/// Abstraction over the biometric prompt so the store is unit-testable
/// without a platform channel.
abstract class BiometricAuthenticator {
  Future<bool> isAvailable();
  Future<bool> authenticate(String localizedReason);
}

class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() async {
    try {
      return await _auth.canCheckBiometrics;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String localizedReason) async {
    try {
      return await _auth.authenticate(
        localizedReason: localizedReason,
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}

/// Abstraction over secure storage so tests use an in-memory map.
abstract class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Stores a single admin credential, gated by a biometric check on retrieval.
/// The password is written to hardware-backed secure storage (Keystore /
/// Keychain) only when the admin opts in, read only after a passing biometric
/// prompt, and never logged.
class BiometricCredentialStore {
  BiometricCredentialStore({
    BiometricAuthenticator? authenticator,
    SecureKeyValueStore? storage,
  })  : _auth = authenticator ?? LocalAuthBiometricAuthenticator(),
        _store = storage ?? FlutterSecureKeyValueStore();

  final BiometricAuthenticator _auth;
  final SecureKeyValueStore _store;

  static const _kPhone = 'ugam_biometric_phone';
  static const _kPassword = 'ugam_biometric_password';

  Future<bool> isAvailable() => _auth.isAvailable();

  /// Checks only the (non-secret) phone key so callers can decide whether to
  /// show an unlock affordance without ever touching the stored password.
  Future<bool> hasCredential(String phone) async {
    final stored = await _store.read(_kPhone);
    return stored != null && stored == normalisePhone(phone);
  }

  Future<void> enroll({required String phone, required String password}) async {
    await _store.write(_kPhone, normalisePhone(phone));
    await _store.write(_kPassword, password);
  }

  /// Runs the biometric prompt; returns the stored credential on success,
  /// null on failure / cancel / no-enrollment.
  Future<({String phone, String password})?> unlock(String phone) async {
    // Gate on the (non-secret) phone key before ever prompting or touching
    // the stored password — the password must not be read until AFTER a
    // passing biometric check.
    if (!await hasCredential(phone)) return null;
    final ok = await _auth.authenticate('Unlock Ugam Booking');
    if (!ok) return null;
    final storedPhone = await _store.read(_kPhone);
    final pw = await _store.read(_kPassword);
    if (storedPhone == null || pw == null) return null;
    return (phone: storedPhone, password: pw);
  }

  Future<void> clear() async {
    await _store.delete(_kPhone);
    await _store.delete(_kPassword);
  }
}
