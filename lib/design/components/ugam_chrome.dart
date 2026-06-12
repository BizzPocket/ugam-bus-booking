import 'package:flutter/material.dart';

/// Tracks the height of the *current screen's* bottom chrome (dock nav,
/// sticky CTA, bottom action bar) so the floating toast can sit just
/// above it.
///
/// Why this exists: [AppSnackBar] renders on the root `ScaffoldMessenger`
/// (there is only one, provided by `GetMaterialApp`). A root-level toast
/// has no idea what the visible screen looks like, so the old code hard-
/// coded `bottom: 90` — which grazed the dock nav on home-indicator
/// phones, collided with sticky CTAs, and left an awkward gap on plain
/// screens. This registry feeds the toast the real number instead.
///
/// Correctness comes from keying each chrome widget's height by its own
/// [ChromeMeasure] instance (not by route) and listening to navigation via
/// [UgamChromeObserver]: [bottomInset] is the TALLEST contribution that lives
/// on the top-most route. Keying per instance (rather than one height per
/// route) matters because the tab shell keeps several screens mounted under a
/// SINGLE route — a per-route scalar there is last-writer-wins and thrashes.
/// A contribution is dropped when its widget is disposed or its route leaves
/// the stack, so a popped screen never lingers in the number.
class UgamChrome {
  UgamChrome._();

  /// Height of the active route's bottom chrome, in logical pixels.
  /// 0 means "no chrome" — the toast should clear the safe area instead.
  static final ValueNotifier<double> bottomInset = ValueNotifier<double>(0);

  /// Per-measurer contribution: which route it lives on + its measured height.
  static final Map<Object, ({Route<dynamic>? route, double height})> _contrib =
      <Object, ({Route<dynamic>? route, double height})>{};
  static Route<dynamic>? _top;

  static void _pushRoute(Route<dynamic> route) {
    _top = route;
    _recompute();
  }

  static void _removeRoute(Route<dynamic> route, Route<dynamic>? fallback) {
    _contrib.removeWhere((_, v) => v.route == route);
    if (_top == route) _top = fallback;
    _recompute();
  }

  static void _replaceRoute(
    Route<dynamic>? oldRoute,
    Route<dynamic>? newRoute,
  ) {
    if (oldRoute != null) {
      _contrib.removeWhere((_, v) => v.route == oldRoute);
    }
    if (newRoute != null) _top = newRoute;
    _recompute();
  }

  /// Called by a [ChromeMeasure] (identified by [id]) when it measures [height]
  /// for [route]. Offstage/zero reports retract that measurer's contribution.
  static void report(Object id, Route<dynamic>? route, double height) {
    final existing = _contrib[id];
    if (existing != null &&
        existing.route == route &&
        existing.height == height) {
      return;
    }
    _contrib[id] = (route: route, height: height);
    _recompute();
  }

  /// Drops [id]'s contribution (its widget was disposed).
  static void withdraw(Object id) {
    if (_contrib.remove(id) != null) _recompute();
  }

  static void _recompute() {
    var v = 0.0;
    for (final c in _contrib.values) {
      if (c.route == _top && c.height > v) v = c.height;
    }
    if (bottomInset.value != v) bottomInset.value = v;
  }
}

/// Wire into `GetMaterialApp(navigatorObservers: [UgamChromeObserver()])`
/// so chrome heights track the live navigation stack.
class UgamChromeObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    UgamChrome._pushRoute(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    UgamChrome._removeRoute(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    UgamChrome._removeRoute(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    UgamChrome._replaceRoute(oldRoute, newRoute);
  }
}

/// Wraps a screen's bottom chrome, measures its rendered height after
/// each layout, and reports it to [UgamChrome] under the screen's route.
/// Drop-in: chrome components ([UgamStickyCTA], [UgamDockNav], custom
/// bottom bars) wrap their output in this so positioning is automatic.
class ChromeMeasure extends StatefulWidget {
  final Widget child;
  const ChromeMeasure({super.key, required this.child});

  @override
  State<ChromeMeasure> createState() => _ChromeMeasureState();
}

class _ChromeMeasureState extends State<ChromeMeasure> {
  final GlobalKey _key = GlobalKey();
  Route<dynamic>? _route;

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _key.currentContext;
      // A chrome widget on a hidden tab still lays out (so its size is real),
      // but it must NOT lift the toast — retract its contribution when hidden.
      final h = (ctx != null && !_isHidden(ctx)) ? ctx.size?.height : null;
      UgamChrome.report(this, _route, h ?? 0);
    });
  }

  /// True when an ancestor [Offstage]/[Visibility] is hiding this subtree.
  /// (IndexedStack hides at the render layer with no such ancestor, so the
  /// AppSnackBar lift is also hard-clamped as the real safety net.)
  bool _isHidden(BuildContext ctx) {
    var hidden = false;
    ctx.visitAncestorElements((el) {
      final w = el.widget;
      if (w is Offstage && w.offstage) {
        hidden = true;
        return false;
      }
      if (w is Visibility && !w.visible) {
        hidden = true;
        return false;
      }
      return true;
    });
    return hidden;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    UgamChrome.withdraw(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-measure on every rebuild: CTA height changes with loading
    // spinners, multi-line labels, and keyboard-driven relayout.
    _scheduleMeasure();
    return KeyedSubtree(key: _key, child: widget.child);
  }
}
