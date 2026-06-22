import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

/// Navigation helpers that pop the RIGHT navigator.
///
/// The app shell gives each bottom-tab its own nested [Navigator]
/// (see `main_shell.dart`). A screen pushed with
/// `Navigator.of(context).push(...)` lands on that NESTED navigator, while
/// GetX's [Get.back] operates on the ROOT navigator. So a screen that was
/// pushed onto a nested navigator but closes itself with `Get.back()` pops the
/// wrong navigator and appears to do nothing.
///
/// [AppNav.pop] resolves this once: it pops the navigator the screen actually
/// lives on (`Navigator.of(context)`) when that navigator can pop, and only
/// falls back to [Get.back] when it can't (e.g. a `Get.to`-pushed route sitting
/// on the root navigator). This mirrors the safe default already used by
/// `UgamAppBar` when no `onBack` override is supplied, so it works regardless of
/// how the screen was pushed.
class AppNav {
  AppNav._();

  /// Close the current screen, popping whichever navigator it was pushed onto.
  ///
  /// Optionally returns [result] to the route that awaited the push.
  static void pop<T>(BuildContext context, [T? result]) {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop<T>(result);
    } else {
      Get.back<T>(result: result);
    }
  }
}
