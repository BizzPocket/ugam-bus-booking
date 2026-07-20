import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/ugam_logo.dart';
import '../controllers/auth_controller.dart';
import '../design/ugam.dart';

class LoginScreen extends GetView<AuthController> {
  const LoginScreen({super.key});

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
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UgamSpacing.xxl,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (canPop) ...[
                            const SizedBox(height: UgamSpacing.sm),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: UgamIconButton(
                                icon: Icons.close_rounded,
                                onTap: Get.back,
                                semanticLabel: tr('app.action.back'),
                              ),
                            ),
                          ],
                          const SizedBox(height: UgamSpacing.huge),
                          // Brand block — centred logo (on a soft copper halo),
                          // Sora wordmark, and tagline. The radial glow is the
                          // signature futuristic flourish, echoing the dashboard
                          // passenger hero.
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              SizedBox(
                                height: 132,
                                child: Stack(
                                  alignment: Alignment.center,
                                  clipBehavior: Clip.none,
                                  children: [
                                    Container(
                                      width: 188,
                                      height: 188,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        gradient: RadialGradient(
                                          colors: [
                                            c.glow,
                                            c.glow.withValues(alpha: 0),
                                          ],
                                          stops: const [0.0, 0.7],
                                        ),
                                      ),
                                    ),
                                    const UgamLogo(size: 64),
                                  ],
                                ),
                              ),
                              const SizedBox(height: UgamSpacing.lg),
                              Text(
                                'UGAM',
                                style: UgamText.hero.copyWith(
                                  color: c.ink,
                                  fontSize: 52,
                                  letterSpacing: 2.0,
                                ),
                              ),
                              const SizedBox(height: UgamSpacing.sm),
                              Text(
                                tr('login.tagline'),
                                textAlign: TextAlign.center,
                                style: UgamText.body.copyWith(color: c.ink2),
                              ),
                            ],
                          ),
                          const SizedBox(height: UgamSpacing.huge2),
                          UgamPhoneInput(
                            controller: controller.phoneController,
                            label: tr('login.phone_label'),
                            // Editing the number after the password step has
                            // opened backs out of it — this replaces the old
                            // "use another number" link, so switching numbers
                            // stays possible without a dedicated button.
                            onChanged: (_) {
                              if (controller.awaitingAdminPassword.value) {
                                controller.cancelAdminPassword();
                              }
                            },
                            onSubmitted: (_) {
                              if (!controller.awaitingAdminPassword.value) {
                                controller.submitPhone();
                              }
                            },
                          ),
                          // Password step slides open smoothly instead of
                          // popping in, so the two-step flow reads as one form.
                          Obx(() {
                            final showStep =
                                controller.awaitingAdminPassword.value;
                            return AnimatedSize(
                              duration: UgamMotion.sheet,
                              curve: UgamMotion.easeOut,
                              alignment: Alignment.topCenter,
                              child: showStep
                                  ? _PasswordStep(c: c, controller: controller)
                                  : const SizedBox(width: double.infinity),
                            );
                          }),
                          const SizedBox(height: UgamSpacing.xl),
                        ],
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
                                : controller.submitPhone,
                          );
                        }),
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
        UgamInput(
          key: _fieldKey,
          label: tr('login.password_label'),
          hint: tr('login.password_hint'),
          controller: widget.controller.passwordController,
          obscure: true,
          autofocus: true,
          inputFormatters: const [],
          onSubmitted: (_) => widget.controller.verifyAdminPassword(),
        ),
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
