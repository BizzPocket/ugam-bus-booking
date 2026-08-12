import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import 'charts_screen.dart';
import 'dashboard_screen.dart';
import 'requests_screen.dart';
import 'tours_screen.dart';
import 'settings_screen.dart';

class ShellController extends GetxController {
  final currentIndex = 0.obs;
  void switchTab(int i) => currentIndex.value = i;

  /// Handle a bottom-dock tap. Switching to a different tab just changes the
  /// index; re-tapping the tab you're already on pops that tab's nested
  /// navigator back to its root. This is what makes tapping Home from a pushed
  /// sub-page (e.g. Buses opened off the dashboard) return to the dashboard —
  /// previously [switchTab] set `0 = 0`, a no-op, so nothing happened.
  void onTabTapped(int i) {
    if (i == currentIndex.value) {
      final navState = navigatorKeys[i].currentState;
      if (navState != null && navState.canPop()) {
        navState.popUntil((route) => route.isFirst);
      }
    } else {
      currentIndex.value = i;
    }
  }

  final List<GlobalKey<NavigatorState>> navigatorKeys = List.generate(
    5,
    (index) => GlobalKey<NavigatorState>(),
  );
}

/// The five admin dock tabs, built once so the shell's bottom dock and the
/// [UgamWorkspaceDock] (shown over pushed tour screens) can never drift apart.
/// Read inside an Obx — the requests badge observes [TourController].
List<UgamDockItem> buildAdminDockItems() => [
      UgamDockItem(
        icon: Icons.home_rounded,
        label: tr('main_shell.tab_home'),
        tooltip: tr('main_shell.tab_home'),
      ),
      UgamDockItem(
        icon: Icons.location_on_rounded,
        label: tr('main_shell.tab_tour'),
        tooltip: tr('main_shell.tab_tour'),
      ),
      UgamDockItem(
        icon: Icons.table_chart_rounded,
        label: tr('main_shell.tab_charts'),
        tooltip: tr('main_shell.tab_charts'),
      ),
      UgamDockItem(
        icon: Icons.chat_bubble_rounded,
        label: tr('main_shell.tab_requests'),
        tooltip: tr('main_shell.tab_requests'),
        // Live count of NEW (un-actioned) booking requests across active
        // tours. Read inside an Obx so the badge updates reactively.
        badgeCount: Get.find<TourController>().pendingRequestCount,
      ),
      UgamDockItem(
        icon: Icons.settings_rounded,
        label: tr('main_shell.tab_settings'),
        tooltip: tr('main_shell.tab_settings'),
      ),
    ];

// UgamWorkspaceDock removed in favor of true nested navigation.

/// Max body width for the admin shell. The app is designed phone-first, so
/// on wide screens (tablet, desktop, web) we cap and center the content
/// rather than letting it sprawl. Keeps the FAB and pill nav within reach
/// of the touch target.
const double _kAdminMaxWidth = 540;

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  // Tour-first navigation: the shell holds only the cross-tour surfaces
  // (Home, the tour list, Settings). Everything tour-specific — requests,
  // seat fill/assign, buses, money, notify — now lives inside a tour's
  // workspace (Tour Detail) and is reached by opening that tour.
  static const _adminPages = <Widget>[
    DashboardScreen(),
    ToursScreen(),
    ChartsScreen(),
    RequestsScreen(),
    SettingsScreen(),
  ];

  /// Indices of tabs that have ever been visited. We lazy-mount the
  /// IndexedStack children: the dashboard ([0]) is always mounted on
  /// boot, the other 4 tabs only get built (and start observing tour
  /// state) the first time the agent taps them.
  ///
  /// Previously all 5 tabs mounted up-front. Each one ran its own Obx
  /// over `tourCtrl.tours`, so every realtime event fired 5 Obx
  /// callbacks even though only one tab was on screen. With this set,
  /// a freshly-launched session that stays on the dashboard pays for 1
  /// Obx not 5, and tabs the agent never visits cost nothing.
  ///
  /// Once mounted, tabs stay mounted to preserve their local state
  /// (scroll position, filter selections, picked passenger, etc.).
  final Set<int> _visitedTabs = {0};

  // Status-bar / system-nav styling is set app-wide and theme-aware in
  // `app.dart`'s `GetMaterialApp.builder` (a single AnnotatedRegion). It used
  // to be hardcoded here to `SystemUiOverlayStyle.dark` (dark icons), which
  // rendered the glyphs invisible on the dark theme — removed.

  @override
  Widget build(BuildContext context) {
    final shell = Get.find<ShellController>();

    // The Scaffold resizes to avoid the IME, and `bottomNavigationBar` is
    // inside that resized area — so with the keyboard up the floating dock
    // rode ON TOP of it, eating ~90 px of the little viewport that is left
    // exactly when a form is being filled (Requests search, the booking
    // capture fields, the money numpad). Nothing navigates while typing, so
    // the dock stands down and gives the field its space back. Read OUTSIDE
    // the Obx so the inset is a dependency of this element, not of the
    // reactive closure.
    final imeUp = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Obx(() {
      final currentIndex = shell.currentIndex.value;
      _visitedTabs.add(currentIndex);

      // Android back. `canPop` MUST stay false: this Obx only re-runs when
      // `currentIndex` changes, so any value derived from a nested navigator's
      // `canPop()` at BUILD time goes stale the moment a tab pushes a route
      // (pushing does not change the index, so the shell never rebuilds).
      // Previously a stale-false `canTabPop` let the root route pop first —
      // back from a pushed sub-page on Home exited the app, and on tabs 1-4 it
      // jumped to Home instead of popping one level.
      //
      // With `canPop: false` the shell route can never be popped out from
      // under us, and we resolve the target navigator at POP time instead:
      // pop the active tab's nested stack, else fall back to tab 0, else let
      // the root navigator / system take it.
      //
      // Accepted side effect: predictive-back preview is off for the shell
      // route (it was already off on tabs 1-4, where `canRootPop` was false).
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop || !mounted) return;
          final index = shell.currentIndex.value;
          final nav = shell.navigatorKeys[index].currentState;
          if (nav != null && nav.canPop()) {
            nav.pop();
          } else if (index != 0) {
            shell.switchTab(0);
          } else {
            // Home, nothing left to pop. Preserve the old `canRootPop`
            // behaviour: hand back to the root navigator if anything sits
            // beneath the shell, otherwise leave the app.
            final rootNav = Navigator.of(context);
            if (rootNav.canPop()) {
              rootNav.pop();
            } else {
              SystemNavigator.pop();
            }
          }
        },
        child: UgamScaffold(
          extendBody: true,
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kAdminMaxWidth),
              child: IndexedStack(
                index: currentIndex,
                children: [
                  for (int i = 0; i < _adminPages.length; i++)
                    // Unvisited tabs render a placeholder of the same
                    // dimensions as the real screen so the IndexedStack
                    // sizes correctly — but the placeholder doesn't
                    // observe any reactive state, so no rebuild churn.
                    _visitedTabs.contains(i)
                        ? Navigator(
                            key: shell.navigatorKeys[i],
                            onGenerateRoute: (settings) {
                              return MaterialPageRoute(
                                settings: settings,
                                builder: (context) => _adminPages[i],
                              );
                            },
                          )
                        : const SizedBox.expand(),
                ],
              ),
            ),
          ),
          bottomNavigationBar: imeUp
              ? null
              : Align(
                  alignment: Alignment.center,
                  heightFactor: 1.0,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: _kAdminMaxWidth,
                    ),
                    child: UgamDockNav(
                      currentIndex: shell.currentIndex.value,
                      onTap: shell.onTabTapped,
                      items: buildAdminDockItems(),
                    ),
                  ),
                ),
        ),
      );
    });
  }
}
