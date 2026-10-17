import 'dart:async';

import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../services/crowd_location_share.dart';

/// Runs [CrowdLocationShare.ensurePermission] once the app's root route is
/// mounted, then shows [child].
///
/// The gate must NOT run on the splash screen: a sheet opened there is tied to
/// a route that `Get.offAllNamed` removes, which leaves a black bottom-sheet
/// shell (handle only) on the dashboard.
class LaunchLocationGate extends StatefulWidget {
  const LaunchLocationGate({
    super.key,
    required this.child,
    this.afterGate,
  });

  final Widget child;

  /// Optional work after permission resolves (e.g. start crowd sharing).
  final Future<void> Function(BuildContext context)? afterGate;

  @override
  State<LaunchLocationGate> createState() => _LaunchLocationGateState();
}

class _LaunchLocationGateState extends State<LaunchLocationGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    if (CrowdLocationShare.permissionGateDone) {
      _ready = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _afterGate());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _runGate());
  }

  Future<void> _runGate() async {
    if (!mounted) return;
    await CrowdLocationShare.ensurePermission(context);
    if (!mounted) return;
    setState(() => _ready = true);
    await _afterGate();
  }

  Future<void> _afterGate() async {
    if (!mounted) return;
    final hook = widget.afterGate;
    if (hook != null) await hook(context);
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: c.ink2,
          ),
        ),
      ),
    );
  }
}
