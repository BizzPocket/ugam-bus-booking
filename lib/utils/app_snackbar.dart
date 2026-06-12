import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';

/// Imperative toast API. Static methods (`success`, `error`, `info`,
/// `warning`) preserve every existing call site across the app; the
/// actual rendering is delegated to the [UgamSnackbar] widget so the
/// visual treatment stays inside the design system.
///
/// `warning` is intentionally aliased to `error` — the design system
/// merged the two tones under a single attention treatment, since the
/// two were visually indistinguishable to users in practice.
class AppSnackBar {
  AppSnackBar._();

  static void _show({
    required String message,
    String? title,
    required UgamSnackTone tone,
    Duration duration = const Duration(seconds: 3),
  }) {
    final context = Get.context;
    if (context == null) return;

    HapticFeedback.lightImpact();
    if (tone == UgamSnackTone.error) HapticFeedback.mediumImpact();

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    // Sit just above whatever bottom chrome the active screen actually
    // has — dock nav, sticky CTA, or nothing — instead of a fixed guess.
    // [UgamChrome.bottomInset] is fed by the chrome widgets + the nav
    // observer; on a plain screen it's 0 and we fall back to the safe
    // area so the toast still clears the home indicator.
    final mq = MediaQuery.maybeOf(context);
    final chrome = UgamChrome.bottomInset.value;
    final safe = mq?.padding.bottom ?? 0;
    // Safety clamp: the tab shell keeps every visited screen mounted in one
    // IndexedStack (one route), so a TALL bottom dock from another still-
    // mounted tab can report a stale, oversized chrome height. Unclamped, that
    // lifts this floating toast into the MIDDLE of the screen. Cap the lift to
    // the lower fifth of the viewport so a toast always reads as a bottom toast,
    // whatever the registry reports.
    final maxLift = (mq?.size.height ?? 800) * 0.20;
    final lift = (chrome > 0 ? chrome : safe).clamp(0.0, maxLift);
    final bottomMargin = lift + UgamSpacing.md;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          padding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          elevation: 0,
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            left: UgamSpacing.gutter,
            right: UgamSpacing.gutter,
            bottom: bottomMargin,
          ),
          duration: duration,
          dismissDirection: DismissDirection.horizontal,
          content: UgamSnackbar(message: message, title: title, tone: tone),
        ),
      );
  }

  static void success(String message, {String? title}) =>
      _show(title: title, message: message, tone: UgamSnackTone.success);

  static void error(String message, {String? title}) => _show(
    title: title,
    message: message,
    tone: UgamSnackTone.error,
    duration: const Duration(seconds: 4),
  );

  /// Aliased to error — same visual treatment in the new design system.
  static void warning(String message, {String? title}) =>
      error(message, title: title);

  static void info(String message, {String? title}) =>
      _show(title: title, message: message, tone: UgamSnackTone.info);
}
