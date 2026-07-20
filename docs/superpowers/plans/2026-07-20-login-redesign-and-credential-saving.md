# Login Redesign + Credential Saving Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Level up the admin login screen and add native credential conveniences — OS save/autofill (Google Password Manager / iCloud Keychain), biometric quick-unlock, show/hide password, and remembered phone number.

**Architecture:** Keep the existing phone→password two-step flow and Charcoal-Copper design system. Add `autofillHints` + a single `AutofillGroup` around the login fields and fire `TextInput.finishAutofillContext()` on success. Introduce a testable `BiometricCredentialStore` (thin, injectable wrapper over `local_auth` + `flutter_secure_storage`) and wire it through `AuthController`. All new UI strings go through `easy_localization` in all three languages.

**Tech Stack:** Flutter, GetX, Supabase Auth (via `AdminAuthService`), `local_auth`, `flutter_secure_storage`, `easy_localization`, `shared_preferences`.

## Global Constraints

- **Admin-only auth, unchanged:** login is phone + password for admins; do NOT alter the passenger flow, the synthetic-email sign-in, or `AdminAuthService` public behaviour.
- **App package id:** `com.occubitsolution.ugambooking` (used for the Kotlin file path).
- **Test harness pattern:** subclass the controller and override `onInit()` to skip network wiring; pump inside `GetMaterialApp`/`MaterialApp` with `theme: ThemeData(brightness: Brightness.dark)`; `easy_localization` is NOT initialised in tests, so `tr('x.y')` returns the raw key `'x.y'` — assert on raw keys. (See [test/screens/seats_screen_test.dart](../../../test/screens/seats_screen_test.dart).)
- **No `plural()` in tests** (throws `LateInitializationError`); only `tr()` is used here, which is safe.
- **i18n:** every user-visible string added to all three files — [assets/translations/en.json](../../../assets/translations/en.json), [gu.json](../../../assets/translations/gu.json), [hi.json](../../../assets/translations/hi.json).
- **Design tokens only:** spacing via `UgamSpacing`, radius via `UgamRadius`, colours via `UgamColors.of(context)`, motion via `UgamMotion`, text via `UgamText`. Do not hardcode.
- **local_auth requires Android minSdk ≥ 24 and `FlutterFragmentActivity`.**
- **iOS scope:** Android-first. iOS gets show/hide + biometric + the keyboard Passwords bar; full iCloud Keychain association (Associated Domains + AASA hosting) is OUT of scope.
- **Commit after every task.** Run `flutter analyze` before each commit; it must report no new issues.

---

### Task 1: Show / hide password toggle in `UgamInput`

Convert `UgamInput` to a `StatefulWidget` so it can own an eye toggle. Existing callers are unaffected (`obscureToggle` defaults `false`).

**Files:**
- Modify: `lib/design/components/ugam_input.dart` (the `UgamInput` class, lines 11-94)
- Modify: `assets/translations/en.json`, `assets/translations/gu.json`, `assets/translations/hi.json` (the `"login"` object)
- Test: `test/design/ugam_input_test.dart` (create)

**Interfaces:**
- Produces: `UgamInput({..., bool obscureToggle = false, List<String>? autofillHints})` — the `autofillHints` param is ADDED here too (used by Task 2) so the field is touched once.

- [ ] **Step 1: Add the i18n keys**

In each of the three translation files, inside the existing `"login"` object, add:

en.json:
```json
    "show_password": "Show password",
    "hide_password": "Hide password",
```
gu.json:
```json
    "show_password": "પાસવર્ડ બતાવો",
    "hide_password": "પાસવર્ડ છુપાવો",
```
hi.json:
```json
    "show_password": "पासवर्ड दिखाएं",
    "hide_password": "पासवर्ड छुपाएं",
```

- [ ] **Step 2: Write the failing test**

Create `test/design/ugam_input_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_input.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(body: child),
      );

  testWidgets('obscureToggle starts obscured and reveals on tap', (tester) async {
    await tester.pumpWidget(host(
      const UgamInput(obscure: true, obscureToggle: true),
    ));

    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isFalse);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
  });

  testWidgets('no toggle icon when obscureToggle is false', (tester) async {
    await tester.pumpWidget(host(const UgamInput(obscure: true)));
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
  });

  testWidgets('autofillHints pass through to the field', (tester) async {
    await tester.pumpWidget(host(
      const UgamInput(autofillHints: [AutofillHints.password]),
    ));
    expect(
      tester.widget<TextField>(find.byType(TextField)).autofillHints,
      contains(AutofillHints.password),
    );
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/design/ugam_input_test.dart`
Expected: FAIL — `obscureToggle`/`autofillHints` are not named params of `UgamInput`.

- [ ] **Step 4: Implement**

In `lib/design/components/ugam_input.dart`, replace the `UgamInput` class (lines 11-94) with a `StatefulWidget`. Add `obscureToggle` and `autofillHints` fields; keep all existing fields/params. Add `import 'package:easy_localization/easy_localization.dart';` at the top.

```dart
class UgamInput extends StatefulWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final bool obscure;
  final bool obscureToggle;
  final List<String>? autofillHints;
  final bool autofocus;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;
  final Widget? prefix;
  final Widget? suffix;
  final bool readOnly;
  final bool enabled;
  final int maxLines;
  final int? minLines;

  const UgamInput({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.focusNode,
    this.keyboardType,
    this.inputFormatters = const [],
    this.obscure = false,
    this.obscureToggle = false,
    this.autofillHints,
    this.autofocus = false,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.prefix,
    this.suffix,
    this.readOnly = false,
    this.enabled = true,
    this.maxLines = 1,
    this.minLines,
  });

  @override
  State<UgamInput> createState() => _UgamInputState();
}

class _UgamInputState extends State<UgamInput> {
  late bool _obscured = widget.obscure;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // When obscureToggle is on, the eye icon becomes the field's suffix. An
    // explicitly-passed suffix takes precedence (no caller passes both today).
    Widget? suffix = widget.suffix;
    if (widget.obscureToggle && suffix == null) {
      suffix = GestureDetector(
        onTap: () => setState(() => _obscured = !_obscured),
        behavior: HitTestBehavior.opaque,
        child: Semantics(
          button: true,
          label: tr(_obscured ? 'login.show_password' : 'login.hide_password'),
          child: Icon(
            _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            size: 20,
            color: c.ink3,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Text(widget.label!.toUpperCase(),
              style: UgamText.micro.copyWith(color: c.ink2)),
          const SizedBox(height: UgamSpacing.sm),
        ],
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          keyboardType: widget.keyboardType,
          inputFormatters: widget.inputFormatters,
          obscureText: _obscured,
          autofillHints: widget.autofillHints,
          autofocus: widget.autofocus,
          maxLength: widget.maxLength,
          maxLines: _obscured ? 1 : widget.maxLines,
          minLines: widget.minLines,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          readOnly: widget.readOnly,
          enabled: widget.enabled,
          style: UgamText.body.copyWith(
            color: widget.enabled ? c.ink : c.ink3,
            fontSize: 15,
          ),
          decoration: InputDecoration(
            hintText: widget.hint,
            errorText: widget.errorText,
            counterText: '',
            prefixIcon: widget.prefix,
            suffixIcon: suffix,
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/design/ugam_input_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 6: Analyze + commit**

Run: `flutter analyze lib/design/components/ugam_input.dart`
Expected: No issues.
```bash
git add lib/design/components/ugam_input.dart test/design/ugam_input_test.dart assets/translations/
git commit -m "feat(login): show/hide password toggle + autofillHints on UgamInput"
```

---

### Task 2: Autofill wiring on the login form

Add `autofillHints` to `UgamPhoneInput`, wrap the login fields in a single `AutofillGroup`, and commit the autofill context on a successful sign-in.

**Files:**
- Modify: `lib/design/components/ugam_input.dart` (the `UgamPhoneInput` class, lines 117-191)
- Modify: `lib/screens/login_screen.dart` (wrap form body in `AutofillGroup`; add hints to fields)
- Modify: `lib/controllers/auth_controller.dart` (call `TextInput.finishAutofillContext()` — added in Task 4's `_completeLogin`; here we only add the phone/password hints in the UI)
- Test: `test/screens/login_screen_test.dart` (create)

**Interfaces:**
- Consumes: `UgamInput.autofillHints` (Task 1).
- Produces: `UgamPhoneInput({..., List<String>? autofillHints})`.

- [ ] **Step 1: Write the failing test**

Create `test/screens/login_screen_test.dart` with a fake controller that skips `onInit`, then assert the phone field carries the username hint and both fields sit under one `AutofillGroup`. (The password field is revealed by flipping `awaitingAdminPassword`.)

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/screens/login_screen.dart';

class _FakeAuthController extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {} // skip _restore (SharedPreferences + Supabase)

  @override
  Future<void> prepareLoginScreen() async {} // skip prefs read in these tests
}

Widget _harness() => GetMaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: const LoginScreen(),
    );

void main() {
  tearDown(Get.reset);

  testWidgets('phone field has username autofill hint inside an AutofillGroup',
      (tester) async {
    Get.put<AuthController>(_FakeAuthController());
    await tester.pumpWidget(_harness());
    await tester.pump();

    expect(find.byType(AutofillGroup), findsWidgets);

    final phone = tester.widgetList<TextField>(find.byType(TextField)).firstWhere(
          (f) => f.keyboardType == TextInputType.phone,
        );
    expect(phone.autofillHints, contains(AutofillHints.username));
  });

  testWidgets('revealed password field carries the password hint',
      (tester) async {
    final c = _FakeAuthController();
    Get.put<AuthController>(c);
    await tester.pumpWidget(_harness());
    c.awaitingAdminPassword.value = true;
    await tester.pump(const Duration(milliseconds: 400));

    final obscured = tester
        .widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.obscureText == true);
    expect(obscured.autofillHints, contains(AutofillHints.password));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/screens/login_screen_test.dart`
Expected: FAIL — no `AutofillGroup` in the tree / phone field has no hints. (It may also fail to compile until `prepareLoginScreen` exists; that method is added in Task 3. For now, delete the `prepareLoginScreen` override from the fake if compilation fails, and re-add it in Task 3.)

- [ ] **Step 3: Add `autofillHints` to `UgamPhoneInput`**

In `lib/design/components/ugam_input.dart`, add the field + param to `UgamPhoneInput` and pass it to its inner `TextField`:
```dart
  final List<String>? autofillHints;
```
Add to the constructor: `this.autofillHints,`. In the inner phone `TextField` (currently line ~169), add:
```dart
                  autofillHints: autofillHints,
```

- [ ] **Step 4: Wrap the login form in an `AutofillGroup` and set hints**

In `lib/screens/login_screen.dart`:
- Add `import 'package:flutter/services.dart';` (for `AutofillHints`).
- Wrap the inner `Column` (the one at line 42, child of the `SingleChildScrollView`) in an `AutofillGroup`:
```dart
                      child: AutofillGroup(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ... existing children ...
                          ],
                        ),
                      ),
```
- On the `UgamPhoneInput` (line 106) add: `autofillHints: const [AutofillHints.username],`
- On the password `UgamInput` inside `_PasswordStep` (line 252) add: `autofillHints: const [AutofillHints.password],` and `obscureToggle: true,` (keep `obscure: true`).

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/screens/login_screen_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Analyze + commit**

Run: `flutter analyze lib/screens/login_screen.dart lib/design/components/ugam_input.dart`
Expected: No new issues.
```bash
git add lib/design/components/ugam_input.dart lib/screens/login_screen.dart test/screens/login_screen_test.dart
git commit -m "feat(login): AutofillGroup + username/password hints for OS autofill"
```

---

### Task 3: Remember phone, inline password error, remove debug leak

Make `AdminAuthService` injectable into `AuthController` (for testing the error path), add an inline password error, remove the synthetic-email debug string, and persist + prefill the last phone number.

**Files:**
- Modify: `lib/controllers/auth_controller.dart`
- Modify: `lib/screens/login_screen.dart` (convert to `StatefulWidget`; call `prepareLoginScreen`; render inline error; clear error on change)
- Modify: `assets/translations/{en,gu,hi}.json` (the `"login"` object)
- Test: `test/controllers/auth_controller_test.dart` (create)
- Test: `test/screens/login_screen_test.dart` (extend)

**Interfaces:**
- Produces on `AuthController`:
  - field `AdminAuthService adminAuth = AdminAuthService();` (replaces the `_adminAuth` getter; overridable in tests)
  - `final RxnString passwordError = RxnString();`
  - `static const _keyLastPhone = 'auth_last_phone';`
  - `Future<void> prepareLoginScreen()` — reads `last_phone` into `phoneController`, updates biometric availability (biometric part lands in Task 6; here it only does the phone prefill).
  - `Future<void> persistLastPhone(String phone)` (called from `_completeLogin` in Task 4).

- [ ] **Step 1: Add the i18n key**

In each translation file, inside `"login"`, add:
- en: `"password_incorrect": "Incorrect password",`
- gu: `"password_incorrect": "ખોટો પાસવર્ડ",`
- hi: `"password_incorrect": "गलत पासवर्ड",`

- [ ] **Step 2: Write the failing controller test**

Create `test/controllers/auth_controller_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/models/admin.dart';
import 'package:occubusbooking/services/admin_auth_service.dart';

class _ThrowingAuth extends AdminAuthService {
  @override
  Future<Admin> signIn({required String phone, required String password}) async {
    throw const AuthException('Invalid login credentials');
  }
}

class _TestAuthController extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('wrong password sets inline passwordError, no throw', () async {
    final ctrl = _TestAuthController()..adminAuth = _ThrowingAuth();
    ctrl.pendingAdmin.value =
        Admin(id: 'a1', phone: '9876543210', name: 'Test');
    ctrl.awaitingAdminPassword.value = true;
    ctrl.passwordController.text = 'wrong';

    await ctrl.verifyAdminPassword();

    expect(ctrl.passwordError.value, 'login.password_incorrect');
    expect(ctrl.isLoading.value, isFalse);
  });

  test('prepareLoginScreen prefills last phone', () async {
    SharedPreferences.setMockInitialValues({'auth_last_phone': '9876543210'});
    final ctrl = _TestAuthController();
    await ctrl.prepareLoginScreen();
    expect(ctrl.phoneController.text, '9876543210');
  });
}
```
(Confirm the `Admin` constructor signature in [lib/models/admin.dart](../../../lib/models/admin.dart) and adjust the named args if they differ — use the real required fields.)

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/controllers/auth_controller_test.dart`
Expected: FAIL — `adminAuth` setter, `passwordError`, and `prepareLoginScreen` don't exist.

- [ ] **Step 4: Implement in `auth_controller.dart`**

- Replace the getter `AdminAuthService get _adminAuth => AdminAuthService();` with a field:
```dart
  /// Injectable so tests can supply a throwing/fake service.
  AdminAuthService adminAuth = AdminAuthService();
```
  Then replace every `_adminAuth` usage in the file with `adminAuth`.
- Add near the other keys: `static const _keyLastPhone = 'auth_last_phone';`
- Add near the other Rx fields: `final RxnString passwordError = RxnString();`
- At the top of `verifyAdminPassword()`, clear the error: `passwordError.value = null;`
- Replace the `on AuthException catch (e)` block (the one with the `[debug]` string) with:
```dart
    } on AuthException catch (_) {
      // Wrong password (or unknown synthetic email) — surface inline on the
      // field, not as a toast, and never echo the synthetic email.
      passwordError.value = tr('login.password_incorrect');
```
  (Keep the generic `catch (e)` connection-error branch as-is.)
- Add the prefill + persist helpers:
```dart
  Future<void> persistLastPhone(String phone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastPhone, phone);
  }

  /// Prep the login screen after a logout / cold anonymous start: prefill the
  /// last-used number so a returning admin only types the password. Biometric
  /// availability is layered on in a later change.
  Future<void> prepareLoginScreen() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_keyLastPhone);
    if (last != null && last.isNotEmpty && phoneController.text.isEmpty) {
      phoneController.text = last;
      phoneNumber.value = last;
    }
  }
```
  Ensure `easy_localization` is imported (it already is, line 3).

- [ ] **Step 5: Wire the login screen — convert to `StatefulWidget`, render inline error, clear on change**

In `lib/screens/login_screen.dart`:
- Change `class LoginScreen extends GetView<AuthController>` to a `StatefulWidget` that reads the controller via `Get.find<AuthController>()`. Call `controller.prepareLoginScreen()` in `initState` (post-frame). Keep the whole existing `build` body, referencing `final controller = Get.find<AuthController>();` at the top of `build`.
```dart
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  AuthController get controller => Get.find<AuthController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.prepareLoginScreen();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // ... existing build body unchanged ...
  }
}
```
- In `_PasswordStep`, wrap the `UgamInput` in an `Obx` and pass the error, clearing it on change:
```dart
        Obx(() => UgamInput(
              key: _fieldKey,
              label: tr('login.password_label'),
              hint: tr('login.password_hint'),
              controller: widget.controller.passwordController,
              obscure: true,
              obscureToggle: true,
              autofillHints: const [AutofillHints.password],
              autofocus: true,
              errorText: widget.controller.passwordError.value,
              inputFormatters: const [],
              onChanged: (_) => widget.controller.passwordError.value = null,
              onSubmitted: (_) => widget.controller.verifyAdminPassword(),
            )),
```

- [ ] **Step 6: Extend the login widget test — inline error renders**

Append to `test/screens/login_screen_test.dart` a test that sets `passwordError` and asserts the raw key text appears. Update `_FakeAuthController` to keep the `prepareLoginScreen` override (now that the method exists).
```dart
  testWidgets('inline password error shows on the field', (tester) async {
    final c = _FakeAuthController();
    Get.put<AuthController>(c);
    await tester.pumpWidget(_harness());
    c.awaitingAdminPassword.value = true;
    await tester.pump(const Duration(milliseconds: 400));
    c.passwordError.value = 'login.password_incorrect';
    await tester.pump();
    expect(find.text('login.password_incorrect'), findsOneWidget);
  });
```

- [ ] **Step 7: Run tests**

Run: `flutter test test/controllers/auth_controller_test.dart test/screens/login_screen_test.dart`
Expected: PASS.

- [ ] **Step 8: Analyze + commit**

Run: `flutter analyze lib/controllers/auth_controller.dart lib/screens/login_screen.dart`
Expected: No new issues.
```bash
git add lib/controllers/auth_controller.dart lib/screens/login_screen.dart test/ assets/translations/
git commit -m "feat(login): inline password error, remember number, drop debug email leak"
```

---

### Task 4: `BiometricCredentialStore` service (+ finishAutofillContext hook)

A small, fully unit-testable store over `local_auth` + `flutter_secure_storage`, using injectable seams so tests need no platform channels. Also fold in the `local_auth` dependency (needed for the real impl to compile) and the `finishAutofillContext()` call in `_completeLogin`.

**Files:**
- Modify: `pubspec.yaml` (add `local_auth`)
- Create: `lib/services/biometric_credential_store.dart`
- Modify: `lib/controllers/auth_controller.dart` (rename `_loginAsAdmin` → `_completeLogin`, add autofill commit + last-phone persist)
- Test: `test/services/biometric_credential_store_test.dart` (create)

**Interfaces:**
- Produces:
```dart
abstract class BiometricAuthenticator {
  Future<bool> isAvailable();
  Future<bool> authenticate(String localizedReason);
}
abstract class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}
class BiometricCredentialStore {
  BiometricCredentialStore({BiometricAuthenticator? authenticator, SecureKeyValueStore? storage});
  Future<bool> isAvailable();
  Future<bool> hasCredential(String phone);
  Future<void> enroll({required String phone, required String password});
  Future<({String phone, String password})?> unlock(String phone);
  Future<void> clear();
}
```

- [ ] **Step 1: Add `local_auth` to pubspec + fetch**

In `pubspec.yaml`, under `dependencies:` (near `flutter_secure_storage`), add:
```yaml
  # On-device biometric unlock (fingerprint / Face ID) for admin quick sign-in.
  local_auth: ^2.3.0
```
Run: `flutter pub get`
Expected: resolves successfully.

- [ ] **Step 2: Write the failing test**

Create `test/services/biometric_credential_store_test.dart`:
```dart
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

  test('clear removes the credential', () async {
    final store = BiometricCredentialStore(
        authenticator: _FakeAuth(), storage: _MemStore());
    await store.enroll(phone: '9876543210', password: 'pw');
    await store.clear();
    expect(await store.hasCredential('9876543210'), isFalse);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/services/biometric_credential_store_test.dart`
Expected: FAIL — `biometric_credential_store.dart` does not exist.

- [ ] **Step 4: Implement the store**

Create `lib/services/biometric_credential_store.dart`:
```dart
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
      return await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
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

  Future<bool> hasCredential(String phone) async {
    final stored = await _store.read(_kPhone);
    final pw = await _store.read(_kPassword);
    return stored != null && pw != null && stored == normalisePhone(phone);
  }

  Future<void> enroll({required String phone, required String password}) async {
    await _store.write(_kPhone, normalisePhone(phone));
    await _store.write(_kPassword, password);
  }

  /// Runs the biometric prompt; returns the stored credential on success,
  /// null on failure / cancel / no-enrollment.
  Future<({String phone, String password})?> unlock(String phone) async {
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
```

- [ ] **Step 5: Add the autofill commit + last-phone persist to `_completeLogin`**

In `lib/controllers/auth_controller.dart`:
- Add `import 'package:flutter/services.dart';` (for `TextInput`).
- Rename `Future<void> _loginAsAdmin(Admin admin)` to `Future<void> _completeLogin(Admin admin, {required String password})` and update its call site in `verifyAdminPassword` to `await _completeLogin(admin, password: passwordController.text);` (capture BEFORE `_completeLogin` clears the field).
- Inside `_completeLogin`, immediately after `await _persistSession();`, add:
```dart
    await persistLastPhone(admin.phone);
    // Commit the autofill context so the OS offers to save the number+password.
    // Must run while the login screen's AutofillGroup is still mounted, i.e.
    // BEFORE navigating away.
    TextInput.finishAutofillContext();
```
  (The biometric enroll offer is added in Task 6, also inside `_completeLogin`, before `Get.offAllNamed('/')`.)

- [ ] **Step 6: Run tests**

Run: `flutter test test/services/biometric_credential_store_test.dart test/controllers/auth_controller_test.dart`
Expected: PASS.

- [ ] **Step 7: Analyze + commit**

Run: `flutter analyze lib/services/biometric_credential_store.dart lib/controllers/auth_controller.dart`
Expected: No new issues.
```bash
git add pubspec.yaml pubspec.lock lib/services/biometric_credential_store.dart lib/controllers/auth_controller.dart test/services/
git commit -m "feat(auth): BiometricCredentialStore + commit autofill context on login"
```

---

### Task 5: Native platform setup for biometrics

Runtime-only changes so `local_auth` works on device. No unit test — verified by `flutter analyze` and a debug build.

**Files:**
- Modify: `android/app/src/main/kotlin/com/occubitsolution/ugambooking/MainActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/build.gradle.kts` (ensure `minSdk >= 24`)
- Modify: `ios/Runner/Info.plist`

- [ ] **Step 1: MainActivity → FlutterFragmentActivity**

Replace the contents of `MainActivity.kt` with:
```kotlin
package com.occubitsolution.ugambooking

import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity()
```

- [ ] **Step 2: Add the biometric permission**

In `android/app/src/main/AndroidManifest.xml`, add alongside the other `uses-permission` lines (after `POST_NOTIFICATIONS`):
```xml
    <uses-permission android:name="android.permission.USE_BIOMETRIC"/>
```

- [ ] **Step 3: Ensure minSdk ≥ 24**

Open `android/app/build.gradle.kts`. The line reads `minSdk = flutter.minSdkVersion`. Replace with:
```kotlin
        minSdk = maxOf(24, flutter.minSdkVersion)
```

- [ ] **Step 4: iOS Face ID usage string**

In `ios/Runner/Info.plist`, add inside the top-level `<dict>` (e.g. after the `NSContactsUsageDescription` block):
```xml
	<key>NSFaceIDUsageDescription</key>
	<string>Ugam Booking uses Face ID to sign you in quickly and securely.</string>
```

- [ ] **Step 5: Verify the build compiles**

Run: `flutter analyze`
Expected: No new issues.
Run: `flutter build apk --debug` (or `flutter run` on a device/emulator and confirm it launches).
Expected: Build succeeds — confirms the `FlutterFragmentActivity` swap and minSdk bump are consistent with the other plugins (push, image_picker).

- [ ] **Step 6: Commit**
```bash
git add android/ ios/Runner/Info.plist
git commit -m "chore(android,ios): FlutterFragmentActivity + biometric permissions for local_auth"
```

---

### Task 6: Wire biometric into AuthController + login unlock button

Add the biometric store to `AuthController`, offer enrollment once after a successful login, expose an unlock path, and surface an "Unlock with fingerprint" button on the login screen.

**Files:**
- Modify: `lib/controllers/auth_controller.dart`
- Modify: `lib/screens/login_screen.dart`
- Modify: `assets/translations/{en,gu,hi}.json` (`"login"` object)
- Test: `test/controllers/auth_controller_test.dart` (extend)
- Test: `test/screens/login_screen_test.dart` (extend)

**Interfaces:**
- Consumes: `BiometricCredentialStore` (Task 4).
- Produces on `AuthController`:
  - field `BiometricCredentialStore biometric = BiometricCredentialStore();`
  - `final RxBool canBiometricUnlock = false.obs;`
  - `static const _keyBiometricOffered = 'auth_biometric_offered';`
  - `Future<void> unlockWithBiometric()`
  - extends `prepareLoginScreen()` to set `canBiometricUnlock`.

- [ ] **Step 1: Add i18n keys**

In each translation file, inside `"login"`, add:
- en:
```json
    "unlock_biometric": "Unlock with fingerprint",
    "biometric_enroll_title": "Enable fingerprint login?",
    "biometric_enroll_message": "Next time, sign in with your fingerprint or face — no password typing.",
    "biometric_enroll_confirm": "Enable",
```
- gu:
```json
    "unlock_biometric": "ફિંગરપ્રિન્ટથી અનલૉક કરો",
    "biometric_enroll_title": "ફિંગરપ્રિન્ટ લૉગિન ચાલુ કરવું?",
    "biometric_enroll_message": "આગલી વખતે પાસવર્ડ ટાઇપ કર્યા વગર ફિંગરપ્રિન્ટ કે ફેસથી સાઇન ઇન કરો.",
    "biometric_enroll_confirm": "ચાલુ કરો",
```
- hi:
```json
    "unlock_biometric": "फ़िंगरप्रिंट से अनलॉक करें",
    "biometric_enroll_title": "फ़िंगरप्रिंट लॉगिन चालू करें?",
    "biometric_enroll_message": "अगली बार पासवर्ड टाइप किए बिना फ़िंगरप्रिंट या फ़ेस से साइन इन करें।",
    "biometric_enroll_confirm": "चालू करें",
```

- [ ] **Step 2: Write the failing controller tests**

Append to `test/controllers/auth_controller_test.dart` a fake store + tests for unlock and offered-flag. Add these fakes at the top:
```dart
import 'package:occubusbooking/services/biometric_credential_store.dart';

class _FakeStore extends BiometricCredentialStore {
  _FakeStore({this.available = true, this.pass = true, this.enrolled});
  bool available;
  bool pass;
  ({String phone, String password})? enrolled;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> hasCredential(String phone) async => enrolled != null;
  @override
  Future<void> enroll({required String phone, required String password}) async =>
      enrolled = (phone: phone, password: password);
  @override
  Future<({String phone, String password})?> unlock(String phone) async =>
      pass ? enrolled : null;
  @override
  Future<void> clear() async => enrolled = null;
}
```
Note `BiometricCredentialStore` has no default-arg-free super issue — the subclass calls the default constructor implicitly. Then:
```dart
  test('prepareLoginScreen enables biometric when a credential exists', () async {
    SharedPreferences.setMockInitialValues({'auth_last_phone': '9876543210'});
    final ctrl = _TestAuthController()
      ..biometric = _FakeStore(enrolled: (phone: '9876543210', password: 'pw'));
    await ctrl.prepareLoginScreen();
    expect(ctrl.canBiometricUnlock.value, isTrue);
  });

  test('unlockWithBiometric replays signIn on success', () async {
    final store = _FakeStore(enrolled: (phone: '9876543210', password: 'pw'), pass: true);
    final signedIn = <String>[];
    final ctrl = _TestAuthController()
      ..biometric = store
      ..adminAuth = _RecordingAuth(signedIn);
    ctrl.phoneController.text = '9876543210';
    await ctrl.unlockWithBiometric();
    expect(signedIn, contains('9876543210'));
  });
```
Add a recording auth service near the top:
```dart
class _RecordingAuth extends AdminAuthService {
  _RecordingAuth(this.log);
  final List<String> log;
  @override
  Future<Admin> signIn({required String phone, required String password}) async {
    log.add(phone);
    return Admin(id: 'a1', phone: phone, name: 'Test');
  }
}
```
`unlockWithBiometric` will call `_completeLogin`, which calls `Get.offAllNamed('/')` and `TextInput.finishAutofillContext()`. In a pure controller test there's no `GetMaterialApp`; guard by wrapping the navigation so the test asserts `signIn` was reached before nav. If `Get.offAllNamed` throws without a router, wrap the test body in `try`/`catch` around the nav OR assert on `signedIn` which is recorded before navigation. Since `signIn` runs before `_completeLogin`, the `expect(signedIn, contains(...))` holds even if nav no-ops. If `finishAutofillContext` errors in the test VM, guard it (see Step 3).

- [ ] **Step 3: Implement in `auth_controller.dart`**

- Add field near the other services: `BiometricCredentialStore biometric = BiometricCredentialStore();`
- Add `final RxBool canBiometricUnlock = false.obs;`
- Add key: `static const _keyBiometricOffered = 'auth_biometric_offered';`
- Extend `prepareLoginScreen()` — after the phone prefill, add:
```dart
    final phone = phoneController.text;
    if (phone.isNotEmpty && await biometric.isAvailable()) {
      canBiometricUnlock.value = await biometric.hasCredential(phone);
    } else {
      canBiometricUnlock.value = false;
    }
```
- Add the unlock method:
```dart
  /// Replays the stored admin credential after a passing biometric prompt.
  Future<void> unlockWithBiometric() async {
    final phone = phoneController.text.trim();
    if (phone.isEmpty) return;
    final cred = await biometric.unlock(phone);
    if (cred == null) return; // cancelled / failed — stay on the manual path

    isLoading.value = true;
    try {
      final admin = await adminAuth.signIn(
        phone: cred.phone,
        password: cred.password,
      );
      await _completeLogin(admin, password: cred.password);
    } on AuthException catch (_) {
      // Stored password is stale (admin changed it server-side). Drop the
      // credential and fall back to manual entry.
      await biometric.clear();
      canBiometricUnlock.value = false;
      passwordError.value = tr('login.password_incorrect');
    } catch (e) {
      AppSnackBar.error(
        tr('errors.sign_in', namedArgs: {'e': '$e'}),
        title: tr('errors.connection_error'),
      );
    } finally {
      isLoading.value = false;
    }
  }
```
- In `_completeLogin`, just before `Get.offAllNamed('/')`, add the one-time enroll offer:
```dart
    await _maybeOfferBiometricEnroll(admin.phone, password);
```
  and add the helper:
```dart
  Future<void> _maybeOfferBiometricEnroll(String phone, String password) async {
    if (!await biometric.isAvailable()) return;
    if (await biometric.hasCredential(phone)) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_keyBiometricOffered) ?? false) return;
    await prefs.setBool(_keyBiometricOffered, true);

    final enable = await Get.dialog<bool>(
      // Reuse the app's confirm dialog for a consistent look.
      // UgamDialog.confirm needs a context; Get.dialog provides an overlay.
      // Use a lightweight AlertDialog to avoid a context dependency here.
      AlertDialog(
        title: Text(tr('login.biometric_enroll_title')),
        content: Text(tr('login.biometric_enroll_message')),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: Text(tr('app.action.cancel')),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: Text(tr('login.biometric_enroll_confirm')),
          ),
        ],
      ),
    );
    if (enable == true) {
      await biometric.enroll(phone: phone, password: password);
    }
  }
```
  (Confirm `app.action.cancel` exists in the translation files; if not, add `"cancel"` under `app.action` in all three, e.g. en `"Cancel"`, gu `"રદ કરો"`, hi `"रद्द करें"`.)
- Guard `TextInput.finishAutofillContext()` so a headless test VM doesn't crash: wrap it in `try { ... } catch (_) {}` in `_completeLogin`.

- [ ] **Step 4: Add the unlock button to the login screen**

In `lib/screens/login_screen.dart`, inside the sticky footer `Column` (the one in `UgamStickyCTA`, around line 146), add an `Obx` ABOVE the primary CTA that renders a ghost unlock button when `canBiometricUnlock` is true:
```dart
                        Obx(() {
                          if (!controller.canBiometricUnlock.value) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: UgamSpacing.md),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: controller.unlockWithBiometric,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.fingerprint_rounded,
                                      size: 20, color: c.accent),
                                  const SizedBox(width: UgamSpacing.sm),
                                  Text(
                                    tr('login.unlock_biometric'),
                                    style: UgamText.bodyStrong
                                        .copyWith(color: c.accent),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
```

- [ ] **Step 5: Extend the login widget test — button visibility**

Append to `test/screens/login_screen_test.dart`:
```dart
  testWidgets('biometric unlock button shows only when canBiometricUnlock',
      (tester) async {
    final c = _FakeAuthController();
    Get.put<AuthController>(c);
    await tester.pumpWidget(_harness());
    await tester.pump();
    expect(find.text('login.unlock_biometric'), findsNothing);

    c.canBiometricUnlock.value = true;
    await tester.pump();
    expect(find.text('login.unlock_biometric'), findsOneWidget);
  });
```

- [ ] **Step 6: Run tests**

Run: `flutter test test/controllers/auth_controller_test.dart test/screens/login_screen_test.dart`
Expected: PASS.

- [ ] **Step 7: Analyze + commit**

Run: `flutter analyze lib/controllers/auth_controller.dart lib/screens/login_screen.dart`
Expected: No new issues.
```bash
git add lib/controllers/auth_controller.dart lib/screens/login_screen.dart test/ assets/translations/
git commit -m "feat(login): biometric quick-unlock + one-time enroll offer"
```

---

### Task 7: Settings toggle for biometric login

A "Security" section in Settings with a toggle: ON when enrolled; toggling OFF clears the credential; toggling ON (when not enrolled) re-authenticates with the password, then enrolls.

**Files:**
- Modify: `lib/screens/settings_screen.dart`
- Modify: `assets/translations/{en,gu,hi}.json` (`"settings"` object)
- Test: `test/screens/settings_screen_test.dart` (create OR extend if present)

**Interfaces:**
- Consumes: `AuthController.biometric`, `AuthController.adminAuth`, `AuthController.userPhone`.

- [ ] **Step 1: Add i18n keys**

In each file, inside `"settings"`, add:
- en:
```json
    "security_section": "SECURITY",
    "biometric_title": "Fingerprint / Face unlock",
    "biometric_subtitle": "Sign in with your fingerprint or face",
    "biometric_unavailable": "Not available on this device",
    "biometric_enable_password_prompt": "Enter your password to enable fingerprint login",
```
- gu:
```json
    "security_section": "સુરક્ષા",
    "biometric_title": "ફિંગરપ્રિન્ટ / ફેસ અનલૉક",
    "biometric_subtitle": "તમારી ફિંગરપ્રિન્ટ કે ફેસથી સાઇન ઇન કરો",
    "biometric_unavailable": "આ ડિવાઇસ પર ઉપલબ્ધ નથી",
    "biometric_enable_password_prompt": "ફિંગરપ્રિન્ટ લૉગિન ચાલુ કરવા પાસવર્ડ દાખલ કરો",
```
- hi:
```json
    "security_section": "सुरक्षा",
    "biometric_title": "फ़िंगरप्रिंट / फ़ेस अनलॉक",
    "biometric_subtitle": "अपनी फ़िंगरप्रिंट या फ़ेस से साइन इन करें",
    "biometric_unavailable": "इस डिवाइस पर उपलब्ध नहीं है",
    "biometric_enable_password_prompt": "फ़िंगरप्रिंट लॉगिन चालू करने के लिए पासवर्ड डालें",
```

- [ ] **Step 2: Write the failing test**

Create `test/screens/settings_screen_test.dart` (or extend). Because the full Settings screen depends on several controllers (`ThemeController`, `FinanceController`), test the new toggle widget in isolation. Implement the toggle as a public-in-file `StatefulWidget` `_BiometricToggle`; to test it, extract its enrollment-state logic into a small pumpable widget. Minimal test:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/auth_controller.dart';
import 'package:occubusbooking/services/biometric_credential_store.dart';
import 'package:occubusbooking/screens/settings_screen.dart';

class _FakeStore extends BiometricCredentialStore {
  _FakeStore({this.available = true, this.enrolled = false});
  bool available;
  bool enrolled;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<bool> hasCredential(String phone) async => enrolled;
  @override
  Future<void> clear() async => enrolled = false;
}

class _FakeAuth extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  tearDown(Get.reset);

  testWidgets('shows enrolled state as on', (tester) async {
    final ctrl = _FakeAuth()..biometric = _FakeStore(enrolled: true);
    ctrl.userPhone.value = '9876543210';
    Get.put<AuthController>(ctrl);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: BiometricToggle(authCtrl: ctrl)),
    ));
    await tester.pump();
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });
}
```
(Expose the toggle as a public `BiometricToggle` widget in `settings_screen.dart` so it is directly testable.)

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/screens/settings_screen_test.dart`
Expected: FAIL — `BiometricToggle` does not exist.

- [ ] **Step 4: Implement the toggle + Security section**

In `lib/screens/settings_screen.dart`:
- Add a `BiometricToggle` widget (public) that on init calls `isAvailable()` + `hasCredential(userPhone)` to seed its switch, and:
  - toggle OFF → `biometric.clear()` then `setState(off)`.
  - toggle ON when not enrolled → show a password `AlertDialog` (`tr('settings.biometric_enable_password_prompt')`) with a `UgamInput(obscure: true, obscureToggle: true)`; on submit `adminAuth.signIn(phone: userPhone, password: entered)` to verify, then `biometric.enroll(...)`; on `AuthException` show `AppSnackBar.error(tr('login.password_incorrect'))` and keep off.
  - if `!isAvailable()` → render the row disabled with `tr('settings.biometric_unavailable')` subtitle.
```dart
class BiometricToggle extends StatefulWidget {
  const BiometricToggle({super.key, required this.authCtrl});
  final AuthController authCtrl;
  @override
  State<BiometricToggle> createState() => _BiometricToggleState();
}

class _BiometricToggleState extends State<BiometricToggle> {
  bool _available = false;
  bool _on = false;
  final _pw = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final b = widget.authCtrl.biometric;
    final avail = await b.isAvailable();
    final on = avail && await b.hasCredential(widget.authCtrl.userPhone.value);
    if (mounted) setState(() { _available = avail; _on = on; });
  }

  Future<void> _toggle(bool want) async {
    final b = widget.authCtrl.biometric;
    if (!want) {
      await b.clear();
      if (mounted) setState(() => _on = false);
      return;
    }
    final ok = await _promptPasswordAndEnroll();
    if (mounted && ok) setState(() => _on = true);
  }

  Future<bool> _promptPasswordAndEnroll() async {
    _pw.clear();
    final entered = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: UgamInput(
          label: tr('login.password_label'),
          hint: tr('settings.biometric_enable_password_prompt'),
          controller: _pw,
          obscure: true,
          obscureToggle: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr('app.action.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(_pw.text),
            child: Text(tr('login.biometric_enroll_confirm')),
          ),
        ],
      ),
    );
    if (entered == null || entered.isEmpty) return false;
    try {
      final phone = widget.authCtrl.userPhone.value;
      await widget.authCtrl.adminAuth.signIn(phone: phone, password: entered);
      await widget.authCtrl.biometric.enroll(phone: phone, password: entered);
      return true;
    } on AuthException catch (_) {
      AppSnackBar.error(tr('login.password_incorrect'));
      return false;
    }
  }

  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return _SecurityToggleRow(
      c: c,
      title: tr('settings.biometric_title'),
      subtitle: _available
          ? tr('settings.biometric_subtitle')
          : tr('settings.biometric_unavailable'),
      value: _on,
      enabled: _available,
      onChanged: _toggle,
    );
  }
}
```
  Add a private `_SecurityToggleRow` styled like the notifications-screen `_ToggleRow` (icon tile `Icons.fingerprint_rounded`, title/subtitle, trailing `Switch` with `activeTrackColor: c.accent`). Reference [notifications_settings_screen.dart:136-216](../../../lib/screens/notifications_settings_screen.dart#L136-L216) for the exact styling, but keep this copy local.
  Add imports to `settings_screen.dart`: `import 'package:supabase_flutter/supabase_flutter.dart';` (for `AuthException`) and `import '../utils/app_snackbar.dart';`.
- Insert the Security section into the settings list — after the Appearance block (after line 76's `SizedBox`), before the general settings section:
```dart
                    Text(
                      tr('settings.security_section').toUpperCase(),
                      style: UgamText.micro.copyWith(color: c.ink3),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    Container(
                      decoration: BoxDecoration(
                        color: c.cardElev,
                        borderRadius: BorderRadius.circular(UgamRadius.card),
                      ),
                      child: BiometricToggle(authCtrl: authCtrl),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
```

- [ ] **Step 5: Run tests**

Run: `flutter test test/screens/settings_screen_test.dart`
Expected: PASS.

- [ ] **Step 6: Analyze + commit**

Run: `flutter analyze lib/screens/settings_screen.dart`
Expected: No new issues.
```bash
git add lib/screens/settings_screen.dart test/screens/settings_screen_test.dart assets/translations/
git commit -m "feat(settings): biometric login toggle with password re-auth to enable"
```

---

### Task 8: Visual polish pass + full verification

Tighten the login composition and confirm the whole feature end-to-end. Visual refinement is verified by running the app; the regression net is the full test suite.

**Files:**
- Modify: `lib/screens/login_screen.dart` (spacing/hierarchy only)

- [ ] **Step 1: Refine the login composition (tokens only)**

Adjust ONLY spacing/typography constants in `lib/screens/login_screen.dart` for a tighter, cockpit-density read:
  - Reduce the top `SizedBox(height: UgamSpacing.huge)` (line 56) and the `huge2` gap (line 105) by one step each (`huge`→`xl`, `huge2`→`huge`) so the brand block sits higher and the form is reachable one-handed.
  - Ensure the biometric button (Task 6) has clear separation from the CTA (the `bottom: UgamSpacing.md` padding already added).
  - Confirm the wordmark `fontSize: 52` and tagline hierarchy still balance after the spacing change; nudge only if it reads cramped.
Do not change structure, colours, or the two-step logic.

- [ ] **Step 2: Run the full test suite**

Run: `flutter test`
Expected: All tests pass (the ~640 existing + the new login/input/store/settings tests). Investigate any regression before proceeding.

- [ ] **Step 3: Analyze the whole project**

Run: `flutter analyze`
Expected: No new issues.

- [ ] **Step 4: Manual end-to-end verification (device / emulator)**

Run: `flutter run` and verify:
  1. Login screen prefills the last number after a logout.
  2. Enter a valid admin number → password step reveals; the eye toggle shows/hides.
  3. Wrong password → inline red error under the field (no toast, no email leak).
  4. Correct password → OS "Save password?" prompt appears (Android/Google Password Manager) → then the one-time "Enable fingerprint login?" dialog.
  5. Log out → login screen shows "Unlock with fingerprint" → tap → biometric prompt → straight into the app.
  6. Settings → Security → toggle reflects state; toggling off then on (password re-auth) works.
Capture a screenshot of the refined login for the record.

- [ ] **Step 5: Commit**
```bash
git add lib/screens/login_screen.dart
git commit -m "polish(login): tighten brand/form spacing to cockpit density"
```

---

## Self-Review

**Spec coverage:**
- Visual polish → Tasks 2/3 (structure), 8 (spacing). ✅
- OS save & autofill → Task 2 (hints + group) + Task 4 (`finishAutofillContext`). ✅
- Biometric quick-unlock → Tasks 4 (store), 5 (native), 6 (wire + button), 7 (settings toggle). ✅
- Show/hide password → Task 1. ✅
- Remember & prefill number → Task 3. ✅
- Remove debug email leak → Task 3. ✅
- Biometric storage model (password, biometric-gated, purgeable) → Task 4 (`BiometricCredentialStore`). ✅
- Android-first iOS scope → Task 5 (no Associated Domains work). ✅
- Inline error handling → Task 3; stale-credential fallback → Task 6. ✅
- i18n in 3 languages → every UI task. ✅

**Type consistency:** `BiometricCredentialStore` method names (`isAvailable`/`hasCredential`/`enroll`/`unlock`/`clear`) are used identically in Tasks 4, 6, 7. `_completeLogin(Admin, {required String password})` defined in Task 4, called in Tasks 4 & 6. `prepareLoginScreen`/`canBiometricUnlock`/`passwordError`/`adminAuth` introduced in Tasks 3/6 and reused consistently.

**Notes for the implementer:**
- Confirmed: `Admin({required this.id, required this.phone, required this.name, ...})` in [lib/models/admin.dart:31-34](../../../lib/models/admin.dart#L31-L34) — the test usage `Admin(id: 'a1', phone: '...', name: 'Test')` is valid.
- Confirmed: `app.action.cancel` exists in all three translation files ("Cancel"/"રદ કરો"/"रद्द करें") — no need to add it.
- `finishAutofillContext()` is guarded with try/catch so headless test VMs don't crash.
