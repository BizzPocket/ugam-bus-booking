import 'package:flutter/material.dart';

import '../tokens.dart';

/// The single screen frame for the whole app.
///
/// Every top-level screen renders inside one of these instead of a raw
/// [Scaffold], so the page ground is defined in exactly ONE place. The
/// background is hard-wired to [UgamColorSet.bg] — there is deliberately no
/// `backgroundColor` parameter, because the whole point is that no screen can
/// quietly drift to a different near-black. Re-skin the ground by editing the
/// `bg` token in `tokens.dart`; it flows to every screen through here.
///
/// This is a thin, faithful pass-through over [Scaffold]: every parameter a
/// screen actually uses is forwarded with Material's own defaults, so swapping
/// `Scaffold(` → `UgamScaffold(` (and dropping the `backgroundColor:` line) is
/// a zero-visual-change edit.
class UgamScaffold extends StatelessWidget {
  final Widget? body;
  final PreferredSizeWidget? appBar;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final FloatingActionButtonLocation? floatingActionButtonLocation;
  final Widget? bottomSheet;
  final bool extendBody;
  final bool extendBodyBehindAppBar;
  final bool? resizeToAvoidBottomInset;
  final bool primary;

  const UgamScaffold({
    super.key,
    this.body,
    this.appBar,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.floatingActionButtonLocation,
    this.bottomSheet,
    this.extendBody = false,
    this.extendBodyBehindAppBar = false,
    this.resizeToAvoidBottomInset,
    this.primary = true,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: UgamColors.of(context).bg,
      appBar: appBar,
      body: body,
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      bottomSheet: bottomSheet,
      extendBody: extendBody,
      extendBodyBehindAppBar: extendBodyBehindAppBar,
      resizeToAvoidBottomInset: resizeToAvoidBottomInset,
      primary: primary,
    );
  }
}
