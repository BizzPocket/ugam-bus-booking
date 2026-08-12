import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/ugam_logo.dart';
import '../controllers/auth_controller.dart';
import '../design/ugam.dart';
import '../routes/app_routes.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  AuthController get controller => Get.find<AuthController>();

  /// True once a phone lookup has come back without a matching admin. Gates
  /// the "need admin access?" link to [AdminSetupScreen], which had no entry
  /// point anywhere in the app before this.
  bool _lookupFailed = false;

  /// Inline validation on the phone field. The controller reports a short
  /// number as a TOAST, which floats at the far end of the screen from the
  /// field that is actually wrong — so the length check is made here and the
  /// message is rendered by [UgamPhoneInput]'s own error slot, next to the
  /// input the user has to fix.
  String? _phoneError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.prepareLoginScreen();
    });
  }

  /// Clears whatever the last attempt left on screen. Called from `onChanged`
  /// so an error never outlives the value that caused it.
  void _clearPhoneFeedback() {
    if (_phoneError == null && !_lookupFailed) return;
    setState(() {
      _phoneError = null;
      _lookupFailed = false;
    });
  }

  /// Wraps [AuthController.submitPhone] to notice a failed lookup without
  /// reaching into the controller: `submitPhone` only sets
  /// `awaitingAdminPassword` when it actually found an admin, so if the flag
  /// is still down after it returns, this number cannot sign in.
  Future<void> _submitPhone() async {
    // Re-entrancy guard. The CTA disables itself while `isLoading`, but the
    // keyboard's submit key does not — without this, holding the return key
    // fires a second (and third) admin lookup over the first.
    if (controller.isLoading.value) return;

    final phone = controller.phoneController.text.trim();
    if (phone.length < 10) {
      setState(() {
        _phoneError = tr('errors.phone_invalid');
        _lookupFailed = false;
      });
      return;
    }
    if (_phoneError != null) setState(() => _phoneError = null);

    await controller.submitPhone();
    if (!mounted) return;
    final failed = !controller.awaitingAdminPassword.value;
    if (failed != _lookupFailed) setState(() => _lookupFailed = failed);
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // LoginScreen is usually the root, but it can be pushed (e.g. via the
    // hidden long-press on customer-home). When it sits on the stack, give
    // the user a visible way back so they are never stranded.
    final canPop = Navigator.canPop(context);

    return UgamScaffold(
      // Tapping anywhere outside a field dismisses the keyboard. On iOS the
      // numeric/phone keyboard has no "Done" key, so this is the user's way to
      // close it — and the CTA below sits ABOVE the keyboard (it lives in the
      // resizing body, not in a bottomNavigationBar that the keyboard hides).
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          // Centred, width-capped column so the form stays comfortable on
          // tablets / large phones instead of stretching edge to edge.
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                children: [
                  // Pinned OUTSIDE the scroll body. It used to be the first
                  // child of the centred form column, which dragged it into
                  // the middle of the screen and let it scroll away under the
                  // keyboard — a dismiss control has to stay where the user
                  // left it.
                  if (canPop)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.xxl,
                        UgamSpacing.sm,
                        UgamSpacing.xxl,
                        0,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: UgamIconButton(
                          icon: Icons.close_rounded,
                          onTap: Get.back,
                          semanticLabel: tr('app.action.back'),
                        ),
                      ),
                    ),
                  Expanded(
                    // The form is CENTRED in whatever height is left rather
                    // than stacked against the top: at 812pt the brand + one
                    // phone field left ~330pt of undesigned void between the
                    // field and the sticky CTA. `minHeight` makes the column
                    // fill the viewport so `center` has something to centre
                    // in, and the moment the content (password step) or the
                    // keyboard makes it taller, it simply scrolls as before.
                    child: LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UgamSpacing.xxl,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: constraints.maxHeight,
                          ),
                          child: AutofillGroup(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(height: UgamSpacing.xl),
                                // Brand block — centred logo (on a soft copper
                                // halo), Sora wordmark, and tagline. The radial
                                // glow is the signature futuristic flourish,
                                // echoing the dashboard passenger hero.
                                //
                                // The `double.infinity` width is load-bearing:
                                // this column's intrinsic width is the 188pt
                                // halo, and under the parent's
                                // CrossAxisAlignment.start that pinned the
                                // whole brand block to the left edge while the
                                // full-width phone field sat beneath it. It
                                // has to claim the row before its own
                                // `center` can mean anything.
                                SizedBox(
                                  width: double.infinity,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      // Decorative brand block -> px(), never
                                      // tap(). All four numbers scale together
                                      // so the halo keeps its proportion to the
                                      // mark instead of towering over text
                                      // textScaler already shrank.
                                      SizedBox(
                                        height: UgamScale.px(context, 132),
                                        child: Stack(
                                          alignment: Alignment.center,
                                          clipBehavior: Clip.none,
                                          children: [
                                            Container(
                                              width:
                                                  UgamScale.px(context, 188),
                                              height:
                                                  UgamScale.px(context, 188),
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                gradient: RadialGradient(
                                                  colors: [
                                                    c.glow,
                                                    c.glow
                                                        .withValues(alpha: 0),
                                                  ],
                                                  stops: const [0.0, 0.7],
                                                ),
                                              ),
                                            ),
                                            UgamLogo(
                                              size: UgamScale.px(context, 64),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: UgamSpacing.lg),
                                      // Wraps rather than ellipsising: the
                                      // wordmark is Latin in every locale
                                      // today, but at the 1.3x text scale
                                      // app.dart permits a hero step is one
                                      // long word away from clipping.
                                      Text(
                                        tr('login.brand_name'),
                                        textAlign: TextAlign.center,
                                        style: UgamText.hero.copyWith(
                                          color: c.ink,
                                          letterSpacing: 2.0,
                                        ),
                                      ),
                                      const SizedBox(height: UgamSpacing.sm),
                                      Text(
                                        tr('login.tagline'),
                                        textAlign: TextAlign.center,
                                        style: UgamText.body
                                            .copyWith(color: c.ink2),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: UgamSpacing.huge),
                                UgamPhoneInput(
                                  controller: controller.phoneController,
                                  label: tr('login.phone_label'),
                                  autofillHints: const [
                                    AutofillHints.username,
                                  ],
                                  errorText: _phoneError,
                                  // Editing the number after the password step
                                  // has opened backs out of it — this replaces
                                  // the old "use another number" link, so
                                  // switching numbers stays possible without a
                                  // dedicated button.
                                  onChanged: (_) {
                                    if (controller
                                        .awaitingAdminPassword.value) {
                                      controller.cancelAdminPassword();
                                    }
                                    _clearPhoneFeedback();
                                  },
                                  onSubmitted: (_) {
                                    if (!controller
                                        .awaitingAdminPassword.value) {
                                      _submitPhone();
                                    }
                                  },
                                ),
                                // Password step slides open smoothly instead of
                                // popping in, so the two-step flow reads as one
                                // form.
                                Obx(() {
                                  final showStep =
                                      controller.awaitingAdminPassword.value;
                                  return AnimatedSize(
                                    duration: UgamMotion.sheet,
                                    curve: UgamMotion.easeOut,
                                    alignment: Alignment.topCenter,
                                    child: showStep
                                        ? _PasswordStep(
                                            c: c,
                                            controller: controller,
                                          )
                                        : const SizedBox(
                                            width: double.infinity,
                                          ),
                                  );
                                }),
                                const SizedBox(height: UgamSpacing.xl),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Sticky footer: terms sit right above the primary action,
                  // and the whole block rides above the keyboard.
                  UgamStickyCTA(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr('login.terms'),
                          textAlign: TextAlign.center,
                          style: UgamText.caption.copyWith(
                            color: c.ink3,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: UgamSpacing.md),
                        Obx(() {
                          if (!controller.canBiometricUnlock.value) {
                            return const SizedBox.shrink();
                          }
                          // Was a bare Row in a GestureDetector — copper text
                          // with no button surface and a ~20pt hit box. TONAL,
                          // not ghost: tonal gives it a real surface (the amber
                          // wash + hairline) where ghost is transparent, so the
                          // affordance still reads as a button. It also costs no
                          // solid-accent budget, so the UgamCTA below stays this
                          // screen's one solid fill.
                          //
                          // NOTE: tonal's INK is `c.ink`, not the accent — the
                          // accent was retired from every control because it
                          // means "this is yours" (a selection or ownership
                          // state), and biometric unlock is a verb. Only the
                          // wash and hairline are still amber.
                          //
                          // Goes disabled with the CTA. The controller already
                          // refuses a re-entrant unlock, but a button that
                          // still LOOKS live during a sign-in invites the
                          // second tap that the guard then silently eats.
                          final loading = controller.isLoading.value;
                          return Padding(
                            padding:
                                const EdgeInsets.only(bottom: UgamSpacing.md),
                            child: UgamButton(
                              kind: UgamButtonKind.tonal,
                              label: tr('login.unlock_biometric'),
                              icon: Icons.fingerprint_rounded,
                              expand: true,
                              onPressed: loading
                                  ? null
                                  : controller.unlockWithBiometric,
                            ),
                          );
                        }),
                        Obx(() {
                          final showPasswordStep =
                              controller.awaitingAdminPassword.value;
                          final loading = controller.isLoading.value;
                          return UgamCTA(
                            label: showPasswordStep
                                ? tr('login.btn_sign_in')
                                : tr('app.action.continue_'),
                            loading: loading,
                            onPressed: showPasswordStep
                                ? controller.verifyAdminPassword
                                : _submitPhone,
                          );
                        }),
                        // AdminSetupScreen was unreachable: a number that is
                        // not a provisioned admin dead-ended at this form with
                        // no path to the fully-built support screen. Surfaced
                        // only AFTER a lookup comes back empty, so the default
                        // login render is unchanged.
                        if (_lookupFailed)
                          Padding(
                            padding:
                                const EdgeInsets.only(top: UgamSpacing.sm),
                            child: UgamButton(
                              kind: UgamButtonKind.ghost,
                              label: tr('login.btn_admin_access'),
                              onPressed: () =>
                                  Get.toNamed(AppRoutes.adminSetup),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The admin password sub-form, revealed once a registered number is entered.
///
/// The field lives at the bottom of a [SingleChildScrollView] whose viewport is
/// capped above by the sticky CTA and shrinks further when the keyboard opens.
/// `autofocus` alone can't land it in view: focus (and Flutter's built-in
/// scroll-into-view) fires on the first frame, while the reveal [AnimatedSize]
/// is still collapsed and the keyboard is still sliding up — both of which then
/// push the field back below the fold. So we explicitly scroll it into view
/// once the reveal has expanded, and re-pin it as the keyboard settles.
class _PasswordStep extends StatefulWidget {
  const _PasswordStep({required this.c, required this.controller});

  final UgamColorSet c;
  final AuthController controller;

  @override
  State<_PasswordStep> createState() => _PasswordStepState();
}

class _PasswordStepState extends State<_PasswordStep>
    with WidgetsBindingObserver {
  final GlobalKey _fieldKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Bring the field into view once the reveal animation has grown it to its
    // final height (the keyboard, on its own animation, then re-pins it via
    // didChangeMetrics as its height settles).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(UgamMotion.sheet);
      _ensureFieldVisible();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Fires repeatedly while the keyboard slides up; each tick re-scrolls so the
  // field tracks the shrinking viewport instead of ending up behind the keyboard.
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureFieldVisible());
  }

  void _ensureFieldVisible() {
    final ctx = _fieldKey.currentContext;
    if (!mounted || ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 1.0, // pin the field's bottom just above the sticky CTA
      duration: UgamMotion.route,
      curve: UgamMotion.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final adminName = widget.controller.pendingAdmin.value?.name ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: UgamSpacing.xl),
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
              // Re-entrancy guard. The CTA disables itself while `isLoading`
              // but the keyboard's submit key does not, so a held return key
              // could queue a second sign-in behind the first. Deliberately
              // NOT `enabled: !isLoading` — disabling a focused field drops
              // the keyboard, and on a wrong password the user would have to
              // tap back in before they could correct it.
              onSubmitted: (_) {
                if (widget.controller.isLoading.value) return;
                widget.controller.verifyAdminPassword();
              },
            )),
        if (adminName.isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.sm),
          Text(
            tr('login.signing_in_as', namedArgs: {'name': adminName}),
            style: UgamText.caption.copyWith(color: widget.c.ink2),
          ),
        ],
      ],
    );
  }
}
