# Supabase Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Appwrite backend with Supabase free tier across the Flutter app, with no user-visible behavior change. Postgres schema is already deployed (per [`2026-05-10-supabase-migration-design.md`](../specs/2026-05-10-supabase-migration-design.md)).

**Architecture:** Flutter app talks directly to Supabase via `supabase_flutter`. Auth uses synthetic-email mapping `<10-digit-phone>@occubus.local` so the existing phone+password UX stays identical. The two main service classes (`SyncService`, `UserService`) keep their public APIs; only their internals swap. Per-admin scoping moves from app-side filters to Postgres Row-Level Security.

**Tech Stack:** Flutter 3.10+, Dart 3, GetX, sqflite (existing), `supabase_flutter` (new), `flutter_secure_storage` (new).

**Behavior change to flag:** the new schema has one `bus_id` per tour. The Dart `Tour` model currently exposes `List<Bus> buses`. We keep the list shape for source compatibility but it will hold 0 or 1 entries. Multi-bus tours are out of scope for this plan.

**Connection details (compile-time constants):**

- Supabase URL: `https://rhyqjzulpvaeslbaymex.supabase.co`
- Anon (publishable) key: `sb_publishable_aEvruC4m4U4OXCHOnGIMHw_sv1btxwP`

---

## File map

**Created**

- `lib/config/supabase_config.dart` — URL + anon key constants, plus `phoneToSyntheticEmail`.
- `lib/services/supabase_service.dart` — thin wrapper exposing the typed `SupabaseClient` and a `ping()` method for the login screen.
- `lib/utils/phone_normalize.dart` — last-10-digit normaliser, lifted out of `AppwriteConfig`.
- `test/utils/phone_normalize_test.dart` — unit tests for the normaliser.
- `test/config/supabase_config_test.dart` — unit tests for `phoneToSyntheticEmail`.
- `test/models/admin_test.dart` — unit tests for `Admin.fromMap`/`toMap`.

**Deleted**

- `lib/config/appwrite_config.dart`
- `lib/services/appwrite_service.dart`

**Rewritten**

- `pubspec.yaml` — drop `appwrite`, drop `dependency_overrides`, add `supabase_flutter` + `flutter_secure_storage`.
- `lib/main.dart` — async-init Supabase before `runApp`.
- `lib/models/admin.dart` — drop `passwordHash`/`salt`, switch to `fromMap`/`toMap` with snake_case keys.
- `lib/services/admin_auth_service.dart` — thin Supabase Auth wrapper (signin, profile lookup, signup-disabled).
- `lib/controllers/auth_controller.dart` — call Supabase Auth instead of custom hash; restore session via `supabase.auth.currentSession`.
- `lib/services/sync_service.dart` — replace Appwrite SDK calls with `supabase.from(...).select/insert/update/delete`. Public API unchanged.
- `lib/services/user_service.dart` — same; rewrite internals against `admin_contacts` table, public API unchanged.
- `lib/services/contact_sync_service.dart` — replace `AppwriteConfig.normalisePhone` import with the new `phone_normalize.dart` util.
- `lib/controllers/tour_controller.dart` — replace `AppwriteConfig.<x>Collection` constants with table-name strings (`'tours'`, `'passengers'`, `'buses'`); replace `Tour.fromAppwrite`/`toAppwrite` calls with `fromMap`/`toMap`.
- `lib/controllers/user_controller.dart` — same pattern; replace `AppwriteException` catches with `PostgrestException`.
- `lib/screens/customer_booking_request_screen.dart` — write into `booking_requests` table (anon role, no auth required).
- `lib/screens/login_screen.dart` — replace `AppwriteService().ping()` with `SupabaseService.instance.ping()`.
- `lib/models/app_user.dart` — rename `fromAppwrite`/`toAppwrite` → `fromMap`/`toMap`, snake_case keys.
- `lib/models/tour.dart` — `fromAppwrite`/`toAppwrite` → `fromMap`/`toMap`, snake_case keys, single-bus loading.
- `lib/models/passenger.dart` — same pattern.
- `lib/models/bus_details.dart` — same pattern; drop `tourId` field (buses are now per-admin, not per-tour).

**Untouched**

- `lib/services/offline_database.dart` — sqflite is backend-agnostic.
- `lib/services/whatsapp_service.dart`
- All UI screens not listed above.
- `lib/controllers/theme_controller.dart`

---

## Phase 1 — Dependencies and bootstrapping

### Task 1: Swap dependencies

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: Edit `pubspec.yaml`**

Remove the `appwrite: ^12.0.4` line under `dependencies:`. Remove the entire `dependency_overrides:` block (it only existed for Appwrite's transitive `flutter_web_auth_2`). Add these two lines under `dependencies:` immediately after `crypto: ^3.0.6`:

```yaml
  # Supabase backend
  supabase_flutter: ^2.8.0
  # Secure storage for Supabase session refresh tokens
  flutter_secure_storage: ^9.2.2
```

The `crypto: ^3.0.6` dependency stays (Supabase Auth handles password hashing internally, but `crypto` is still pulled in by other transitive consumers — leaving it avoids a churn diff).

- [ ] **Step 2: Install**

Run: `flutter pub get`
Expected: completes successfully, lockfile updates, no analyzer errors yet (we haven't deleted the imports). If you see `appwrite` mentioned in errors, that's expected — they'll resolve as we work through the plan.

- [ ] **Step 3: Commit**

```bash
git add pubspec.yaml pubspec.lock
git commit -m "Swap appwrite for supabase_flutter dependencies"
```

---

### Task 2: Create phone normaliser utility

**Files:**
- Create: `lib/utils/phone_normalize.dart`
- Create: `test/utils/phone_normalize_test.dart`

The current `AppwriteConfig.normalisePhone` has callers in five files. Lift it out so we can delete `appwrite_config.dart` cleanly.

- [ ] **Step 1: Write the failing test**

Create `test/utils/phone_normalize_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/phone_normalize.dart';

void main() {
  group('normalisePhone', () {
    test('strips spaces, +91 prefix, returns last 10 digits', () {
      expect(normalisePhone('+91 93271 48044'), '9327148044');
    });
    test('returns input unchanged if already 10 digits', () {
      expect(normalisePhone('9327148044'), '9327148044');
    });
    test('returns full string when fewer than 10 digits', () {
      expect(normalisePhone('123'), '123');
    });
    test('strips dashes and parens', () {
      expect(normalisePhone('(932) 714-8044'), '9327148044');
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/utils/phone_normalize_test.dart`
Expected: FAIL with `Target of URI doesn't exist: 'package:occubusbooking/utils/phone_normalize.dart'`.

- [ ] **Step 3: Write the implementation**

Create `lib/utils/phone_normalize.dart`:

```dart
String normalisePhone(String phone) {
  final cleaned = phone.replaceAll(RegExp(r'[^\d]'), '');
  return cleaned.length >= 10
      ? cleaned.substring(cleaned.length - 10)
      : cleaned;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/utils/phone_normalize_test.dart`
Expected: PASS, 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/utils/phone_normalize.dart test/utils/phone_normalize_test.dart
git commit -m "Extract phone normaliser into util with tests"
```

---

### Task 3: Create Supabase config

**Files:**
- Create: `lib/config/supabase_config.dart`
- Create: `test/config/supabase_config_test.dart`

- [ ] **Step 1: Write the failing test**

Create `test/config/supabase_config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/config/supabase_config.dart';

void main() {
  group('phoneToSyntheticEmail', () {
    test('uses last 10 digits + @occubus.local', () {
      expect(
        SupabaseConfig.phoneToSyntheticEmail('+91 93271 48044'),
        '9327148044@occubus.local',
      );
    });
    test('handles already-normalised input', () {
      expect(
        SupabaseConfig.phoneToSyntheticEmail('9327148044'),
        '9327148044@occubus.local',
      );
    });
  });
  test('url and anon key constants are non-empty', () {
    expect(SupabaseConfig.url, isNotEmpty);
    expect(SupabaseConfig.anonKey, isNotEmpty);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/config/supabase_config_test.dart`
Expected: FAIL with `Target of URI doesn't exist`.

- [ ] **Step 3: Write the config**

Create `lib/config/supabase_config.dart`:

```dart
import '../utils/phone_normalize.dart';

class SupabaseConfig {
  static const String url = 'https://rhyqjzulpvaeslbaymex.supabase.co';
  static const String anonKey =
      'sb_publishable_aEvruC4m4U4OXCHOnGIMHw_sv1btxwP';

  /// Maps a phone number to the synthetic email Supabase Auth uses for sign-in.
  /// We don't run a real email infrastructure — the local-part is the last
  /// 10 digits of the phone, and the domain is `occubus.local`.
  static String phoneToSyntheticEmail(String phone) =>
      '${normalisePhone(phone)}@occubus.local';

  SupabaseConfig._();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/config/supabase_config_test.dart`
Expected: PASS, all tests green.

- [ ] **Step 5: Commit**

```bash
git add lib/config/supabase_config.dart test/config/supabase_config_test.dart
git commit -m "Add SupabaseConfig with phone-to-email mapping"
```

---

### Task 4: Initialize Supabase in `main.dart`

**Files:**
- Modify: `lib/main.dart`

- [ ] **Step 1: Read the current `main.dart`**

Run: `cat lib/main.dart`
Expected: shows the existing `void main() async { ... runApp(const MyApp()); }`.

- [ ] **Step 2: Replace `lib/main.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'config/supabase_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );

  runApp(const MyApp());
}
```

- [ ] **Step 3: Verify the app still builds**

Run: `flutter analyze lib/main.dart`
Expected: no errors. (Other files may still error — that's fine.)

- [ ] **Step 4: Commit**

```bash
git add lib/main.dart
git commit -m "Initialize Supabase before runApp"
```

---

### Task 5: Create `SupabaseService` wrapper

**Files:**
- Create: `lib/services/supabase_service.dart`

- [ ] **Step 1: Write the file**

```dart
import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin wrapper around the Supabase client. Exposes the typed client and a
/// `ping()` helper that the login screen uses for connectivity checks.
class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  static SupabaseService get instance => _instance;
  SupabaseService._internal();

  SupabaseClient get client => Supabase.instance.client;

  /// Verifies the project is reachable. Throws on network/auth failure.
  /// Uses a tiny `select` against booking_requests (anon-readable on insert,
  /// but `select count` works under the anon role for any RLS-enabled table —
  /// returns 0 when no rows match).
  Future<String> ping() async {
    await client
        .from('booking_requests')
        .select('id')
        .limit(1);
    return 'OK';
  }
}
```

- [ ] **Step 2: Verify it analyzes**

Run: `flutter analyze lib/services/supabase_service.dart`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/services/supabase_service.dart
git commit -m "Add SupabaseService wrapper with ping"
```

> **Note on the `ping()` method:** the anon role's RLS policy on `booking_requests` allows `INSERT` only, not `SELECT`. PostgREST will return an empty array (not an error) for a forbidden `SELECT` under RLS. That's still a successful round-trip and confirms the project is reachable, which is all `ping()` needs to prove. If the project is paused or unreachable, the request throws.

---

## Phase 2 — Auth replacement

### Task 6: Trim the `Admin` model

**Files:**
- Modify: `lib/models/admin.dart`
- Create: `test/models/admin_test.dart`

The `passwordHash` and `salt` fields are gone — Supabase Auth owns hashing. Switch the (de)serialiser to snake_case keys to match Postgres column names.

- [ ] **Step 1: Write the failing test**

Create `test/models/admin_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/admin.dart';

void main() {
  group('Admin.fromMap', () {
    test('reads snake_case Postgres columns', () {
      final admin = Admin.fromMap({
        'id': 'uuid-abc',
        'phone': '9327148044',
        'name': 'Zeel',
        'whatsapp_number': '9327148044',
      });
      expect(admin.id, 'uuid-abc');
      expect(admin.phone, '9327148044');
      expect(admin.name, 'Zeel');
      expect(admin.whatsappNumber, '9327148044');
    });
    test('whatsappNumber may be null', () {
      final admin = Admin.fromMap({
        'id': 'x',
        'phone': '9999999999',
        'name': 'Test',
      });
      expect(admin.whatsappNumber, isNull);
    });
  });
  group('Admin.effectiveWhatsappNumber', () {
    test('falls back to phone when whatsapp_number is null', () {
      final a = Admin(id: 'x', phone: '9327148044', name: 'Z');
      expect(a.effectiveWhatsappNumber, '9327148044');
    });
    test('uses whatsapp_number when set', () {
      final a = Admin(
        id: 'x',
        phone: '9327148044',
        name: 'Z',
        whatsappNumber: '8888888888',
      );
      expect(a.effectiveWhatsappNumber, '8888888888');
    });
  });
}
```

- [ ] **Step 2: Run the test (will fail to compile)**

Run: `flutter test test/models/admin_test.dart`
Expected: FAIL — `Admin` constructor still requires `passwordHash` and `salt`.

- [ ] **Step 3: Replace `lib/models/admin.dart`**

```dart
/// Mirrors the `public.admins` table. The synthetic email used for Supabase
/// Auth sign-in is derived from `phone` at call time (see SupabaseConfig).
class Admin {
  final String id;
  final String phone;
  final String name;
  final String? whatsappNumber;
  final DateTime? createdAt;

  Admin({
    required this.id,
    required this.phone,
    required this.name,
    this.whatsappNumber,
    this.createdAt,
  });

  /// The number customers should message in the booking handoff.
  /// Falls back to the login phone when an explicit WhatsApp number is
  /// not configured on the admin record.
  String get effectiveWhatsappNumber =>
      (whatsappNumber == null || whatsappNumber!.isEmpty)
          ? phone
          : whatsappNumber!;

  factory Admin.fromMap(Map<String, dynamic> map) {
    return Admin(
      id: (map['id'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      whatsappNumber: map['whatsapp_number']?.toString(),
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'].toString())
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'phone': phone,
        'name': name,
        if (whatsappNumber != null && whatsappNumber!.isNotEmpty)
          'whatsapp_number': whatsappNumber,
      };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/models/admin_test.dart`
Expected: PASS, all 4 tests.

- [ ] **Step 5: Commit**

```bash
git add lib/models/admin.dart test/models/admin_test.dart
git commit -m "Trim Admin model: drop hash/salt, snake_case serialisation"
```

---

### Task 7: Rewrite `AdminAuthService` against Supabase Auth

**Files:**
- Modify: `lib/services/admin_auth_service.dart`

The class shrinks to a thin wrapper. Public surface kept: `findByPhone`, `signIn`, `anyAdminExists`. `verifyPassword` and `createAdmin` go away — Supabase Auth handles them.

- [ ] **Step 1: Replace `lib/services/admin_auth_service.dart` entirely**

```dart
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../models/admin.dart';
import '../utils/phone_normalize.dart';

/// Looks up admins in the `admins` table and signs them into Supabase Auth.
/// Phone matching is normalised to the last 10 digits.
///
/// Admin accounts are created via the Supabase dashboard (not from the app);
/// `createAdmin` is therefore intentionally absent.
class AdminAuthService {
  static final AdminAuthService _instance = AdminAuthService._internal();
  factory AdminAuthService() => _instance;
  AdminAuthService._internal();

  SupabaseClient get _client => Supabase.instance.client;

  /// Returns the admin record for [phone] or null if no row matches.
  /// Throws on network failure so the UI can show a real error rather than
  /// silently treating a connection blip as "not an admin".
  Future<Admin?> findByPhone(String phone) async {
    final last10 = normalisePhone(phone);
    final rows = await _client
        .from('admins')
        .select()
        .eq('phone', last10)
        .limit(1);
    if (rows.isEmpty) return null;
    return Admin.fromMap(Map<String, dynamic>.from(rows.first));
  }

  /// Signs the admin in via Supabase Auth using the synthetic email mapping.
  /// Returns the freshly fetched admin row on success. Throws AuthException
  /// on bad credentials or network failure.
  Future<Admin> signIn({required String phone, required String password}) async {
    await _client.auth.signInWithPassword(
      email: SupabaseConfig.phoneToSyntheticEmail(phone),
      password: password,
    );
    // After sign-in, RLS lets us read our own admins row.
    final uid = _client.auth.currentUser!.id;
    final row = await _client
        .from('admins')
        .select()
        .eq('id', uid)
        .single();
    return Admin.fromMap(Map<String, dynamic>.from(row));
  }

  /// Sign out — clears the Supabase session.
  Future<void> signOut() async => _client.auth.signOut();

  /// True when at least one admin row exists. Used by the first-run setup
  /// guard. Anon role can `select` from admins only when RLS allows it; for
  /// our policies this returns an empty array (not an error) when not
  /// authenticated, so this method should only be called from a logged-in
  /// session. Defensively, it returns true on any non-empty response and
  /// false otherwise.
  Future<bool> anyAdminExists() async {
    final rows = await _client.from('admins').select('id').limit(1);
    return rows.isNotEmpty;
  }
}
```

- [ ] **Step 2: Verify analyze**

Run: `flutter analyze lib/services/admin_auth_service.dart`
Expected: no errors specific to this file. Other files may still reference the old `verifyPassword`/`createAdmin` API — those break now and we fix them in Task 8.

- [ ] **Step 3: Commit**

```bash
git add lib/services/admin_auth_service.dart
git commit -m "Rewrite AdminAuthService against Supabase Auth"
```

---

### Task 8: Rewire `AuthController` to use Supabase sessions

**Files:**
- Modify: `lib/controllers/auth_controller.dart`

The controller's two-step phone-then-password flow stays. Step 1 still calls `findByPhone` to gate the password screen. Step 2 now calls `AdminAuthService.signIn(...)` instead of doing local hash compare. Session restoration shifts from `SharedPreferences` keys to `supabase.auth.currentSession`.

- [ ] **Step 1: Replace `lib/controllers/auth_controller.dart` entirely**

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/admin.dart';
import '../models/profile.dart';
import '../services/admin_auth_service.dart';
import '../utils/app_snackbar.dart';
import 'user_controller.dart';

/// Phone+password admin auth backed by Supabase Auth (synthetic-email mapping).
/// Non-admin phones drop straight into a passenger session (no auth) so
/// first-time customers can browse without friction.
class AuthController extends GetxController {
  static const _keyPhone = 'auth_phone';
  static const _keyRole = 'auth_role';
  static const _keyName = 'auth_name';

  final phoneController = TextEditingController();
  final passwordController = TextEditingController();

  final isLoading = false.obs;
  final phoneNumber = ''.obs;

  final awaitingAdminPassword = false.obs;
  final Rxn<Admin> pendingAdmin = Rxn<Admin>();

  final isLoggedIn = false.obs;
  final userName = ''.obs;
  final userPhone = ''.obs;
  final userRole = UserRole.passenger.obs;
  final Rxn<Profile> currentProfile = Rxn<Profile>();
  final Rxn<Admin> currentAdmin = Rxn<Admin>();

  AdminAuthService get _adminAuth => AdminAuthService();
  SupabaseClient get _client => Supabase.instance.client;

  bool get isAdmin => userRole.value == UserRole.admin;
  bool get isPassenger => userRole.value == UserRole.passenger;

  @override
  void onInit() {
    super.onInit();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final phone = prefs.getString(_keyPhone);
    if (phone == null || phone.isEmpty) return;

    final roleName = prefs.getString(_keyRole) ?? 'passenger';
    final name = prefs.getString(_keyName) ?? '';

    userPhone.value = phone;
    phoneNumber.value = phone;
    userName.value = name;
    userRole.value = UserRole.values.firstWhere(
      (r) => r.name == roleName,
      orElse: () => UserRole.passenger,
    );
    isLoggedIn.value = true;

    if (userRole.value == UserRole.admin && _client.auth.currentSession != null) {
      try {
        final admin = await _adminAuth.findByPhone(phone);
        if (admin != null) {
          currentAdmin.value = admin;
          if (Get.isRegistered<UserController>()) {
            // ignore: unawaited_futures
            Get.find<UserController>().ensureLoadedForCurrentAdmin();
          }
        }
      } catch (_) {
        // Offline or transient — admin will hydrate on next online action.
      }
    }
  }

  Future<void> _persistSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPhone, userPhone.value);
    await prefs.setString(_keyRole, userRole.value.name);
    await prefs.setString(_keyName, userName.value);
  }

  String get maskedPhone {
    final phone = phoneController.text;
    if (phone.length >= 10) {
      return '+91 ${phone.substring(0, 5)} ${phone.substring(5)}';
    }
    return '+91 $phone';
  }

  String get initials {
    final name = userName.value;
    if (name.isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }

  /// Step 1 — phone lookup. Falls through to passenger session on no match.
  Future<void> submitPhone() async {
    final phone = phoneController.text.trim();
    if (phone.length < 10) {
      AppSnackBar.error('Please enter a valid 10-digit phone number');
      return;
    }

    isLoading.value = true;
    try {
      final admin = await _adminAuth.findByPhone(phone);
      if (admin != null) {
        pendingAdmin.value = admin;
        awaitingAdminPassword.value = true;
        passwordController.clear();
      } else {
        await _loginAsPassenger(phone);
      }
    } catch (e) {
      AppSnackBar.error(
        'Could not verify the phone number with Supabase.\n$e',
        title: 'Connection error',
      );
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> sendOtp() => submitPhone();

  /// Step 2 — Supabase Auth sign-in.
  Future<void> verifyAdminPassword() async {
    final pending = pendingAdmin.value;
    if (pending == null) {
      awaitingAdminPassword.value = false;
      return;
    }
    final password = passwordController.text;
    if (password.isEmpty) {
      AppSnackBar.error('Enter your admin password to continue');
      return;
    }

    isLoading.value = true;
    try {
      final admin = await _adminAuth.signIn(
        phone: pending.phone,
        password: password,
      );
      await _loginAsAdmin(admin);
    } on AuthException catch (e) {
      AppSnackBar.error(e.message, title: 'Sign in failed');
    } catch (e) {
      AppSnackBar.error('Could not sign in.\n$e', title: 'Connection error');
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> verifyOtp() async {
    if (awaitingAdminPassword.value) {
      await verifyAdminPassword();
    } else {
      Get.offAllNamed('/');
    }
  }

  void cancelAdminPassword() {
    pendingAdmin.value = null;
    awaitingAdminPassword.value = false;
    passwordController.clear();
  }

  Future<void> _loginAsAdmin(Admin admin) async {
    isLoggedIn.value = true;
    currentAdmin.value = admin;
    userPhone.value = admin.phone;
    phoneNumber.value = admin.phone;
    userRole.value = UserRole.admin;
    userName.value = admin.name;
    awaitingAdminPassword.value = false;
    pendingAdmin.value = null;
    passwordController.clear();
    await _persistSession();
    if (Get.isRegistered<UserController>()) {
      // ignore: unawaited_futures
      Get.find<UserController>().ensureLoadedForCurrentAdmin();
    }
    Get.offAllNamed('/');
  }

  Future<void> _loginAsPassenger(String phone) async {
    isLoggedIn.value = true;
    userPhone.value = phone;
    phoneNumber.value = phone;
    userRole.value = UserRole.passenger;
    userName.value = '';
    await _persistSession();
    Get.offAllNamed('/');
  }

  Future<void> updateUserName(String name) async {
    userName.value = name;
    await _persistSession();
  }

  Future<void> logout() async {
    await _adminAuth.signOut();

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPhone);
    await prefs.remove(_keyRole);
    await prefs.remove(_keyName);

    isLoggedIn.value = false;
    currentProfile.value = null;
    currentAdmin.value = null;
    userRole.value = UserRole.passenger;
    userName.value = '';
    userPhone.value = '';
    phoneController.clear();
    passwordController.clear();
    awaitingAdminPassword.value = false;
    pendingAdmin.value = null;
    if (Get.isRegistered<UserController>()) {
      Get.find<UserController>().reset();
    }
    Get.offAllNamed('/splash');
  }

  @override
  void onClose() {
    phoneController.dispose();
    passwordController.dispose();
    super.onClose();
  }
}
```

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/controllers/auth_controller.dart`
Expected: no errors. (Other files may still error.)

- [ ] **Step 3: Commit**

```bash
git add lib/controllers/auth_controller.dart
git commit -m "Wire AuthController to Supabase Auth"
```

---

## Phase 3 — Models with snake_case serialisation

### Task 9: Update `Tour` model

**Files:**
- Modify: `lib/models/tour.dart`

The model needs `fromMap`/`toMap` reading/writing snake_case Postgres columns, and a single `bus_id` FK instead of a `tourId`-back-reference.

- [ ] **Step 1: Read the current `tour.dart`**

Run: `cat lib/models/tour.dart`
Expected: shows existing fields (id, name, source, destination, startDate, endDate, status, etc.) and `fromAppwrite`/`toAppwrite` factories.

- [ ] **Step 2: Replace the (de)serialisers**

In `lib/models/tour.dart`, replace the two `fromAppwrite` and `toAppwrite` methods with `fromMap` and `toMap` using snake_case keys:

```dart
factory Tour.fromMap(Map<String, dynamic> map) {
  // The `buses` key, if present, is populated by SyncService when fetching
  // tours-with-relations. Inline buses arrive as a List with at most one
  // element under the new schema (one bus_id per tour).
  List<Bus> buses = const [];
  if (map['buses'] is List) {
    buses = (map['buses'] as List)
        .whereType<Map>()
        .map((b) => Bus.fromMap(Map<String, dynamic>.from(b)))
        .toList();
  }
  // The `passengers` key is populated similarly for tours-with-relations.
  List<Passenger> passengers = const [];
  if (map['passengers'] is List) {
    passengers = (map['passengers'] as List)
        .whereType<Map>()
        .map((p) => Passenger.fromMap(Map<String, dynamic>.from(p)))
        .toList();
  }
  return Tour(
    id: (map['id'] ?? '').toString(),
    ownerId: map['owner_id']?.toString(),
    name: (map['name'] ?? '').toString(),
    source: map['source']?.toString() ?? '',
    destination: map['destination']?.toString() ?? '',
    startDate: map['start_date'] != null
        ? DateTime.tryParse(map['start_date'].toString())
        : null,
    endDate: map['end_date'] != null
        ? DateTime.tryParse(map['end_date'].toString())
        : null,
    busId: map['bus_id']?.toString(),
    status: TourStatus.values.firstWhere(
      (s) => s.name == (map['status'] ?? 'draft'),
      orElse: () => TourStatus.draft,
    ),
    buses: buses,
    passengers: passengers,
  );
}

Map<String, dynamic> toMap() => {
      'id': id,
      if (ownerId != null) 'owner_id': ownerId,
      'name': name,
      'source': source,
      'destination': destination,
      'start_date': startDate?.toIso8601String().split('T').first,
      'end_date': endDate?.toIso8601String().split('T').first,
      if (busId != null) 'bus_id': busId,
      'status': status.name,
    };
```

Add two new fields to the `Tour` class declaration:

```dart
final String? ownerId;
final String? busId;
```

Add them to the constructor's named parameter list with sensible defaults (`this.ownerId, this.busId`). Add them to `copyWith`.

> **Why `ownerId` is nullable:** when a controller constructs a fresh `Tour` before insert, it doesn't know `auth.uid()`. The insert path in Task 12 stamps `owner_id` from the current session at write time.

- [ ] **Step 3: Build to verify the model compiles**

Run: `flutter analyze lib/models/tour.dart`
Expected: no errors specific to `tour.dart`. References to `Tour.fromAppwrite`/`toAppwrite` from other files will error — they get fixed in Tasks 12-15.

- [ ] **Step 4: Commit**

```bash
git add lib/models/tour.dart
git commit -m "Tour: snake_case fromMap/toMap, owner_id and bus_id"
```

---

### Task 10: Update `Passenger`, `Bus`, `AppUser` models

**Files:**
- Modify: `lib/models/passenger.dart`
- Modify: `lib/models/bus_details.dart`
- Modify: `lib/models/app_user.dart`

Apply the same `fromAppwrite`/`toAppwrite` → `fromMap`/`toMap` pattern with snake_case keys.

- [ ] **Step 1: Update `Passenger`**

Map old → new keys in `fromMap`:
- `tourId` → `tour_id`
- `seatNo` → `seat_no`
- `requestSource` → `request_source`
- preserve `name`, `phone`, `gender`, `age`, `status`

Drop any reference to `\$id` / `\$createdAt` Appwrite system fields. Use plain `id` and `created_at`.

- [ ] **Step 2: Update `Bus` (in `bus_details.dart`)**

Drop the `tourId` field entirely (buses are per-admin now). Add `ownerId` (nullable). `fromMap`/`toMap` use snake_case:
- `registrationNo` → `registration_no`
- `totalSeats` → `total_seats`
- `ownerId` → `owner_id`
- `layout` → `layout` (already snake_case-compatible since it's one word)

Before saving, run `grep -n "\.tourId\|tourId:" lib/ -r --include="*.dart"` to find every caller of `Bus.tourId`. Drop those assignments — wherever code currently sets `bus.tourId = tour.id`, instead set `tour.busId = bus.id` (the FK now lives on the tour side). This typically affects `tour_controller.dart` (a couple of lines around bus creation/update); fix every match before moving to Step 4.

- [ ] **Step 3: Update `AppUser`**

`addedByAdminId` → `owner_id`. Otherwise straight rename of (de)serialiser methods to `fromMap`/`toMap`. The `AppUser.source` enum is unchanged.

- [ ] **Step 4: Analyze**

Run: `flutter analyze lib/models/`
Expected: no errors inside the models folder.

- [ ] **Step 5: Commit**

```bash
git add lib/models/passenger.dart lib/models/bus_details.dart lib/models/app_user.dart
git commit -m "Models: snake_case fromMap/toMap, drop bus.tourId"
```

---

## Phase 4 — Data services rewrite

### Task 11: Rewrite `SyncService` internals

**Files:**
- Modify: `lib/services/sync_service.dart`

Public API (`smartFetch`, `smartInsert`, `smartUpdate`, `smartDelete`, `syncPendingOps`, `forceFullSync`, `invalidateCache`) stays. Replace the Appwrite calls with Supabase queries.

Key shape changes:
- `table` arg to `smartFetch` becomes a literal Supabase table name (`'tours'`, `'passengers'`, `'buses'`, `'admin_contacts'`, `'booking_requests'`).
- `_fetchToursWithRelations` no longer queries `buses` by `tourId` — instead it loads buses by `id IN (collected bus_ids)`.
- Pending-op sync uses `client.from(table).insert/update/delete` — handle conflicts by treating them as success (PostgREST returns `409` style errors via `PostgrestException.code = '23505'` for unique violation).
- `entityId` continues to be the row's `id` (uuid string). Inserts pass `id` in the body so client-generated UUIDs survive.

- [ ] **Step 1: Replace the file**

Replace `lib/services/sync_service.dart` with the following. Read it carefully — it's long but mechanical:

```dart
import 'dart:async';
import 'dart:developer' as dev;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_snackbar.dart';
import 'offline_database.dart';
import 'supabase_service.dart';

/// Manages offline-first sync between local SQLite cache and Supabase.
///
/// Strategy:
/// - READ: Local cache first → fetch from Supabase in background → update cache
/// - WRITE: Write to cache immediately → queue for Supabase → sync when online
/// - SYNC: On connectivity change, flush pending operations
///
/// The `tours` fetch is special-cased to assemble tours with their nested
/// passengers and (single) bus in memory, since PostgREST doesn't return
/// nested rows by default in our query shape.
class SyncService extends GetxService {
  final OfflineDatabase _cache = OfflineDatabase();
  final isOnline = true.obs;
  final isSyncing = false.obs;
  final pendingCount = 0.obs;

  StreamSubscription? _connectivitySub;
  Timer? _syncTimer;

  SupabaseClient get _client => SupabaseService.instance.client;

  @override
  void onInit() {
    super.onInit();
    _monitorConnectivity();
    _syncTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (isOnline.value) syncPendingOps();
    });
  }

  @override
  void onClose() {
    _connectivitySub?.cancel();
    _syncTimer?.cancel();
    super.onClose();
  }

  void _monitorConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final connected = results.any((r) => r != ConnectivityResult.none);
      isOnline.value = connected;
      if (connected) syncPendingOps();
    });
    Connectivity().checkConnectivity().then((results) {
      isOnline.value = results.any((r) => r != ConnectivityResult.none);
    });
  }

  // ── Smart Fetch (cache-first) ─────────────────────────────

  Future<List<Map<String, dynamic>>> smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async {
    final cached = await _cache.getCachedData(cacheKey);
    final cacheAge = await _cache.getCacheAge(cacheKey);

    if (cached != null && cacheAge != null && cacheAge < maxAge) {
      if (isOnline.value) {
        _backgroundFetch(table, cacheKey, filters, orderBy);
      }
      return _asListOfMap(cached);
    }

    if (isOnline.value) {
      try {
        final data = await _fetchFromSupabase(table, filters, orderBy);
        await _cache.cacheData(cacheKey, data);
        return data;
      } catch (e, st) {
        dev.log('FETCH FAILED $table — $e\n$st', name: 'SyncService');
        if (cached != null) return _asListOfMap(cached);
        return [];
      }
    }

    if (cached != null) return _asListOfMap(cached);
    return [];
  }

  List<Map<String, dynamic>> _asListOfMap(dynamic cached) {
    return List<Map<String, dynamic>>.from(
      (cached as List).map((e) => Map<String, dynamic>.from(e)),
    );
  }

  Future<void> _backgroundFetch(
    String table,
    String cacheKey,
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    try {
      final data = await _fetchFromSupabase(table, filters, orderBy);
      await _cache.cacheData(cacheKey, data);
    } catch (_) {
      // Silent fail for background refresh
    }
  }

  Future<List<Map<String, dynamic>>> _fetchFromSupabase(
    String table,
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    if (table == 'tours') return _fetchToursWithRelations(filters, orderBy);

    var query = _client.from(table).select();
    if (filters != null) {
      filters.forEach((k, v) {
        query = query.eq(k, v);
      });
    }
    final transform = orderBy != null
        ? query.order(orderBy, ascending: false).limit(500)
        : query.limit(500);
    final rows = await transform;
    return List<Map<String, dynamic>>.from(
      (rows as List).map((r) => Map<String, dynamic>.from(r)),
    );
  }

  Future<List<Map<String, dynamic>>> _fetchToursWithRelations(
    Map<String, String>? filters,
    String? orderBy,
  ) async {
    var tourQuery = _client.from('tours').select();
    if (filters != null) {
      filters.forEach((k, v) {
        tourQuery = tourQuery.eq(k, v);
      });
    }
    final transform = orderBy != null
        ? tourQuery.order(orderBy, ascending: false).limit(500)
        : tourQuery.limit(500);
    final tours = List<Map<String, dynamic>>.from(
      (await transform as List).map((r) => Map<String, dynamic>.from(r)),
    );
    if (tours.isEmpty) return [];

    final tourIds = tours.map((t) => t['id'] as String).toList();
    final busIds = tours
        .map((t) => t['bus_id'])
        .whereType<String>()
        .toSet()
        .toList();

    // Passengers: filter by tour_id IN (...)
    final passengersRaw = await _client
        .from('passengers')
        .select()
        .inFilter('tour_id', tourIds)
        .limit(2000);
    final passengersByTour = <String, List<Map<String, dynamic>>>{};
    for (final p in passengersRaw as List) {
      final m = Map<String, dynamic>.from(p as Map);
      final tId = m['tour_id'] as String?;
      if (tId != null) passengersByTour.putIfAbsent(tId, () => []).add(m);
    }

    // Buses: filter by id IN (...)
    final busesByTour = <String, List<Map<String, dynamic>>>{};
    if (busIds.isNotEmpty) {
      final busesRaw = await _client
          .from('buses')
          .select()
          .inFilter('id', busIds)
          .limit(500);
      final busesById = <String, Map<String, dynamic>>{
        for (final b in busesRaw as List)
          (b as Map)['id'] as String: Map<String, dynamic>.from(b),
      };
      for (final t in tours) {
        final bId = t['bus_id'] as String?;
        if (bId != null && busesById.containsKey(bId)) {
          busesByTour[t['id'] as String] = [busesById[bId]!];
        }
      }
    }

    return tours.map((t) {
      final tId = t['id'] as String;
      return {
        ...t,
        'passengers': passengersByTour[tId] ?? const [],
        'buses': busesByTour[tId] ?? const [],
      };
    }).toList();
  }

  // ── Smart Write (queue + sync) ────────────────────────────

  Future<void> smartInsert({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
    String? cacheKey,
  }) async {
    await _cache.addPendingOp(
      tableName: table,
      operation: 'insert',
      entityId: entityId,
      data: data,
    );
    _updatePendingCount();
    if (isOnline.value) await syncPendingOps();
  }

  Future<void> smartUpdate({
    required String table,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    await _cache.addPendingOp(
      tableName: table,
      operation: 'update',
      entityId: entityId,
      data: data,
    );
    _updatePendingCount();
    if (isOnline.value) await syncPendingOps();
  }

  Future<void> smartDelete({
    required String table,
    required String entityId,
  }) async {
    await _cache.addPendingOp(
      tableName: table,
      operation: 'delete',
      entityId: entityId,
      data: {'id': entityId},
    );
    _updatePendingCount();
    if (isOnline.value) await syncPendingOps();
  }

  // ── Sync Engine ───────────────────────────────────────────

  Future<void> syncPendingOps() async {
    if (isSyncing.value || !isOnline.value) return;
    isSyncing.value = true;
    try {
      final ops = await _cache.getPendingOps();
      if (ops.isEmpty) return;
      dev.log('Syncing ${ops.length} pending ops...', name: 'SyncService');

      for (final op in ops) {
        final id = op['id'] as int;
        final table = op['table_name'] as String;
        final operation = op['operation'] as String;
        final entityId = op['entity_id'] as String;
        final data = Map<String, dynamic>.from(op['data'] as Map);
        final retries = op['retries'] as int;

        if (retries >= 5) {
          await _cache.removePendingOp(id);
          AppSnackBar.error(
            'A $operation on $table could not be saved after 5 retries. '
            'Please re-enter or check your connection.',
            title: 'Sync abandoned',
          );
          continue;
        }

        try {
          // Strip any internal id-only fields the cache may have stored.
          data.remove(r'$id');
          data.remove(r'$createdAt');
          data.remove(r'$updatedAt');
          // Ensure the row carries `id` matching entityId for inserts.
          data['id'] = entityId;

          switch (operation) {
            case 'insert':
              try {
                await _client.from(table).insert(data);
              } on PostgrestException catch (e) {
                // 23505 = unique_violation (already exists) → upsert
                if (e.code == '23505') {
                  await _client
                      .from(table)
                      .update(data..remove('id'))
                      .eq('id', entityId);
                } else {
                  rethrow;
                }
              }
              break;
            case 'update':
              final updateData = Map<String, dynamic>.from(data)..remove('id');
              final res = await _client
                  .from(table)
                  .update(updateData)
                  .eq('id', entityId)
                  .select();
              if ((res as List).isEmpty) {
                // Row missing — fall back to insert
                await _client.from(table).insert(data);
              }
              break;
            case 'delete':
              await _client.from(table).delete().eq('id', entityId);
              break;
          }
          await _cache.removePendingOp(id);
        } catch (e) {
          dev.log(
            'SYNC FAILED: $operation on $table/$entityId — $e',
            name: 'SyncService',
          );
          await _cache.incrementRetry(id);
        }
      }
    } finally {
      isSyncing.value = false;
      _updatePendingCount();
    }
  }

  Future<void> _updatePendingCount() async {
    pendingCount.value = await _cache.pendingOpsCount();
  }

  Future<void> invalidateCache(String key) async {
    await _cache.invalidateCache(key);
  }

  Future<void> forceFullSync() async {
    if (!isOnline.value) return;
    await _cache.clearCache();
    await syncPendingOps();
  }
}
```

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/services/sync_service.dart`
Expected: no errors. Other files (controllers) still reference `AppwriteConfig.toursCollection` etc. — those break here and we fix them in the next tasks.

- [ ] **Step 3: Commit**

```bash
git add lib/services/sync_service.dart
git commit -m "Rewrite SyncService internals against Supabase"
```

---

### Task 12: Rewrite `UserService`

**Files:**
- Modify: `lib/services/user_service.dart`

Public API (`listForAdmin`, `findByAdminAndPhone`, `create`, `createIfMissing`) stays. Swap internals to operate on the `admin_contacts` table.

- [ ] **Step 1: Replace `lib/services/user_service.dart`**

```dart
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/app_user.dart';
import '../utils/phone_normalize.dart';
import 'supabase_service.dart';

/// CRUD for the per-admin contacts directory (`public.admin_contacts`).
///
/// All reads are scoped to the current admin's `auth.uid()` via RLS — no
/// app-side `owner_id` filter is necessary, but we pass `adminId` explicitly
/// for clarity and to allow future server-side admin-impersonation tooling.
class UserService {
  static final UserService _instance = UserService._internal();
  factory UserService() => _instance;
  UserService._internal();

  SupabaseClient get _client => SupabaseService.instance.client;
  static const _table = 'admin_contacts';

  Future<List<AppUser>> listForAdmin(String adminId) async {
    final rows = await _client
        .from(_table)
        .select()
        .eq('owner_id', adminId)
        .limit(5000);
    return (rows as List)
        .map((r) => AppUser.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  Future<AppUser?> findByAdminAndPhone(String adminId, String phone) async {
    final last10 = normalisePhone(phone);
    final rows = await _client
        .from(_table)
        .select()
        .eq('owner_id', adminId)
        .eq('phone', last10)
        .limit(1);
    if ((rows as List).isEmpty) return null;
    return AppUser.fromMap(Map<String, dynamic>.from(rows.first as Map));
  }

  /// Inserts a new contact. Throws PostgrestException with code '23505'
  /// (unique_violation) when this `(owner_id, phone)` already exists.
  Future<AppUser> create({
    required String adminId,
    required String phone,
    required String name,
    required UserSource source,
    String? note,
  }) async {
    final last10 = normalisePhone(phone);
    final draft = AppUser(
      id: const Uuid().v4(),
      phone: last10,
      name: name.trim(),
      source: source,
      addedByAdminId: adminId,
      note: note,
    );
    final row = await _client
        .from(_table)
        .insert(draft.toMap())
        .select()
        .single();
    return AppUser.fromMap(Map<String, dynamic>.from(row));
  }

  /// Best-effort insert. Returns null on `(owner_id, phone)` conflict.
  Future<AppUser?> createIfMissing({
    required String adminId,
    required String phone,
    required String name,
    required UserSource source,
    String? note,
  }) async {
    try {
      return await create(
        adminId: adminId,
        phone: phone,
        name: name,
        source: source,
        note: note,
      );
    } on PostgrestException catch (e) {
      if (e.code == '23505') return null;
      rethrow;
    }
  }
}

class UserServiceBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<UserService>(() => UserService(), fenix: true);
  }
}
```

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/services/user_service.dart`
Expected: errors will appear in `app_user.dart` consumers if `toMap`/`fromMap` aren't yet in place — Task 10 should already have fixed those.

- [ ] **Step 3: Commit**

```bash
git add lib/services/user_service.dart
git commit -m "Rewrite UserService against admin_contacts table"
```

---

### Task 13: Update `ContactSyncService` import

**Files:**
- Modify: `lib/services/contact_sync_service.dart`

- [ ] **Step 1: Edit the file**

Replace this line:

```dart
import '../config/appwrite_config.dart';
```

with:

```dart
import '../utils/phone_normalize.dart';
```

And replace the call `AppwriteConfig.normalisePhone(p.number)` with `normalisePhone(p.number)`.

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/services/contact_sync_service.dart`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/services/contact_sync_service.dart
git commit -m "ContactSyncService: use new phone_normalize util"
```

---

## Phase 5 — Controller wiring

### Task 14: Update `tour_controller.dart`

**Files:**
- Modify: `lib/controllers/tour_controller.dart`

Mechanical replacements throughout the file:

- [ ] **Step 1: Apply replacements**

In `lib/controllers/tour_controller.dart`:

- Replace import `'../config/appwrite_config.dart';` → delete the line.
- `AppwriteConfig.toursCollection` → `'tours'` (string literal)
- `AppwriteConfig.passengersCollection` → `'passengers'`
- `AppwriteConfig.busesCollection` → `'buses'`
- `Tour.fromAppwrite(item)` → `Tour.fromMap(item)`
- `tour.toAppwrite()` → `tour.toMap()`
- `passenger.toAppwrite()` → `passenger.toMap()`
- `bus.toAppwrite()` → `bus.toMap()`
- `updated.toAppwrite()` → `updated.toMap()`
- `updated!.toAppwrite()` → `updated!.toMap()`
- `p.toAppwrite()` → `p.toMap()`

Add `owner_id` stamping at insert sites: when constructing the `data:` map for `smartInsert` of a new `Tour`, `Bus`, or `Passenger` (only `Tour` and `Bus` actually need `owner_id` — passengers inherit through tour_id), include the current admin's id from the auth controller. Example for tour insert:

```dart
final auth = Get.find<AuthController>();
final ownerId = auth.currentAdmin.value?.id;
final data = {
  ...tour.toMap(),
  if (ownerId != null) 'owner_id': ownerId,
};
await _sync.smartInsert(table: 'tours', entityId: tour.id, data: data);
```

Apply the same pattern to bus inserts. The new `Bus` model no longer has a `tourId` field — wherever the controller used to set or pass `tourId` on a bus, drop it (and instead set `tours.bus_id` to the new bus's id when associating).

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/controllers/tour_controller.dart`
Expected: no errors (or only errors that surface in linked models/services already fixed).

- [ ] **Step 3: Commit**

```bash
git add lib/controllers/tour_controller.dart
git commit -m "TourController: switch to Supabase table names + toMap"
```

---

### Task 15: Update `user_controller.dart`

**Files:**
- Modify: `lib/controllers/user_controller.dart`

- [ ] **Step 1: Apply replacements**

- Replace `import 'package:appwrite/appwrite.dart';` → `import 'package:supabase_flutter/supabase_flutter.dart';`
- Replace `import '../config/appwrite_config.dart';` → `import '../utils/phone_normalize.dart';`
- Replace `AppwriteConfig.normalisePhone(phone)` → `normalisePhone(phone)`
- Replace `} on AppwriteException catch (err) {` → `} on PostgrestException catch (err) {`
- Inside that catch block, replace `if (err.code == 409)` → `if (err.code == '23505')` (Postgres unique violation)

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/controllers/user_controller.dart`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/controllers/user_controller.dart
git commit -m "UserController: switch to PostgrestException + new normalise"
```

---

### Task 16: Update `customer_booking_request_screen.dart`

**Files:**
- Modify: `lib/screens/customer_booking_request_screen.dart`

The customer flow writes a passenger row directly today. With the new design, customers (anon) write into `booking_requests` instead. The form already collects everything we need.

- [ ] **Step 1: Read the relevant section**

Run: `grep -n "smartInsert\|toAppwrite\|passengersCollection" lib/screens/customer_booking_request_screen.dart`
Expected: shows the existing call ~line 124 inserting into `passengersCollection`.

- [ ] **Step 2: Replace the insert with a `booking_requests` insert**

Where the file currently does:

```dart
await sync.smartInsert(
  table: AppwriteConfig.passengersCollection,
  entityId: passenger.id,
  data: passenger.toAppwrite(),
);
```

Replace with a direct (no-queue) Supabase insert into `booking_requests`. Customers are anon, so the queue mechanism isn't useful — just write online or surface an error:

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
// ... in the submit handler:
final requestId = const Uuid().v4();
await Supabase.instance.client.from('booking_requests').insert({
  'id': requestId,
  'tour_id': tour.id,
  'customer_phone': normalisePhone(phoneController.text),
  'customer_name': nameController.text.trim(),
  'party_size': partySize,
  'raw_form': {
    // Mirror whatever fields `passenger.toAppwrite()` previously wrote, so
    // admins see the same data they would have seen on the old passenger
    // row. Open the file before this task and copy the keys/values that
    // were on the passenger object — common ones include 'gender', 'age',
    // 'pickup_point', 'notes'. Anything not in the schema columns goes
    // into raw_form as-is.
    'phone_input': phoneController.text,
  },
});
```

Remove the `import '../config/appwrite_config.dart';` line; add `import '../utils/phone_normalize.dart';` if it isn't already there. Drop any `appwrite` package imports.

- [ ] **Step 3: Analyze**

Run: `flutter analyze lib/screens/customer_booking_request_screen.dart`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add lib/screens/customer_booking_request_screen.dart
git commit -m "Customer flow: write to booking_requests instead of passengers"
```

---

### Task 17: Update `login_screen.dart` ping

**Files:**
- Modify: `lib/screens/login_screen.dart`

- [ ] **Step 1: Apply replacement**

Find the line `final result = await AppwriteService().ping();` (around line 399) and replace it with:

```dart
final result = await SupabaseService.instance.ping();
```

Replace the import `import '../services/appwrite_service.dart';` with `import '../services/supabase_service.dart';`.

- [ ] **Step 2: Analyze**

Run: `flutter analyze lib/screens/login_screen.dart`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/screens/login_screen.dart
git commit -m "Login screen: use SupabaseService.ping"
```

---

## Phase 6 — Cleanup

### Task 18: Delete the Appwrite files

**Files:**
- Delete: `lib/services/appwrite_service.dart`
- Delete: `lib/config/appwrite_config.dart`

- [ ] **Step 1: Confirm nothing imports them**

Run: `grep -rn "appwrite_service\|appwrite_config" lib/`
Expected: zero matches. If any matches remain, fix them before proceeding.

- [ ] **Step 2: Delete the files**

```bash
rm lib/services/appwrite_service.dart lib/config/appwrite_config.dart
```

- [ ] **Step 3: Run full analyzer**

Run: `flutter analyze`
Expected: zero errors. Warnings are acceptable.

- [ ] **Step 4: Commit**

```bash
git add -u lib/services/appwrite_service.dart lib/config/appwrite_config.dart
git commit -m "Remove Appwrite service and config"
```

---

### Task 19: Build the app

**Files:** none (verification only)

- [ ] **Step 1: Run the build**

Run: `flutter build apk --debug`
Expected: build completes successfully. If any compile error survives, return to the relevant task to fix it.

- [ ] **Step 2: Run the test suite**

Run: `flutter test`
Expected: every test passes (the three test files we wrote: phone_normalize, supabase_config, admin model).

- [ ] **Step 3: Commit if anything had to change**

(Likely nothing — but if you made a fix, commit it now.)

---

## Phase 7 — Live smoke test

### Task 20: End-to-end smoke

**Files:** none (verification only)

Pre-requisites:
- The 2 admin auth users are created in the Supabase dashboard with `phone`/`name`/`whatsapp_number` in user metadata (see spec §"After running the SQL").
- Auto Confirm User is on for both.

- [ ] **Step 1: Install and launch on a real device**

Run: `flutter run -d <your-device>`

- [ ] **Step 2: Login as Admin 1**

- Enter the admin's phone → tap continue → password screen appears.
- Enter the password → expect the dashboard to load.
- Verify in the Supabase dashboard's `auth.users` table that the user's `last_sign_in_at` updated.

- [ ] **Step 3: Create a tour**

- From the dashboard create a new tour with a name + dates.
- In the Supabase SQL Editor: `select id, owner_id, name from public.tours;` — confirm the row exists with `owner_id = <Admin 1 auth uid>`.

- [ ] **Step 4: Add a bus and a passenger**

- Add a bus to the tour, add a passenger.
- SQL: `select id, tour_id, name from public.passengers;` — confirm the row.
- SQL: `select id, owner_id, registration_no from public.buses;` — confirm the bus.

- [ ] **Step 5: Login as Admin 2 — confirm RLS**

- Log out, log in as Admin 2.
- Confirm the dashboard does NOT show Admin 1's tours/passengers/buses.

- [ ] **Step 6: Customer booking form**

- Log out → enter a non-admin phone → land on the customer side.
- Submit a booking request for one of Admin 1's tours.
- SQL (run as service role or via the dashboard, which bypasses RLS):
  `select id, tour_id, customer_name, status from public.booking_requests;` — confirm the row.

- [ ] **Step 7: Sign back in as Admin 1 — confirm the request appears**

- Log in as Admin 1. The pending booking request should be visible in whatever screen consumes it (e.g. requests list).

- [ ] **Step 8: Set up the keep-alive ping**

Sign up at https://cron-job.org (free) and create a job:
- URL: `https://rhyqjzulpvaeslbaymex.supabase.co/rest/v1/booking_requests?select=id&limit=1`
- Header: `apikey: sb_publishable_aEvruC4m4U4OXCHOnGIMHw_sv1btxwP`
- Schedule: every 24 hours
- Save and verify it gets a 200 response on the first run.

- [ ] **Step 9: Final commit and tag**

If anything else changed during smoke testing, commit it. Then tag the milestone:

```bash
git tag -a supabase-cutover-v1 -m "Supabase cutover complete"
```

(Don't push the tag unless instructed — local-only.)

---

## Coverage map (spec → tasks)

| Spec section | Implemented in |
|---|---|
| §Architecture (Flutter direct → Supabase) | Tasks 1, 4, 5 |
| §Data model (snake_case columns, RLS) | already deployed via SQL; Tasks 9-10 update Dart serialisers to match |
| §Auth strategy (synthetic email, signin) | Tasks 3, 7, 8 |
| §Flutter-side changes (deps, services, controllers) | Tasks 1, 11, 12, 13, 14, 15, 16, 17 |
| §Sync model (pull, dirty queue, retries) | Task 11 |
| §Cutover plan (flip the switch) | Tasks 1-19 (rewrite); Task 20 (smoke) |
| §Risks & trade-offs (idle pause keep-alive) | Task 20 step 8 |
