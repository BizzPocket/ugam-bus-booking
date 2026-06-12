import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';
import 'charts_screen.dart';
import 'dashboard_screen.dart';
import 'requests_screen.dart';
import 'tours_screen.dart';
import 'settings_screen.dart';

class ShellController extends GetxController {
  final currentIndex = 0.obs;
  void switchTab(int i) => currentIndex.value = i;
}

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

  @override
  void initState() {
    super.initState();
    // Set the status bar style once, not on every rebuild. The previous
    // implementation called this from build(), so every Obx fire (which
    // happens on every tour write) bounced through a platform channel
    // for no reason — pure waste on the hot path.
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shell = Get.find<ShellController>();

    return Obx(() {
      final currentIndex = shell.currentIndex.value;
      _visitedTabs.add(currentIndex);
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
                      ? _adminPages[i]
                      : const SizedBox.expand(),
              ],
            ),
          ),
        ),
        bottomNavigationBar: Align(
          alignment: Alignment.center,
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kAdminMaxWidth),
            child: UgamDockNav(
              currentIndex: shell.currentIndex.value,
              onTap: shell.switchTab,
              items: [
                UgamDockItem(
                  icon: Icons.home_rounded,
                  tooltip: tr('main_shell.tab_home'),
                ),
                UgamDockItem(
                  icon: Icons.location_on_rounded,
                  tooltip: tr('main_shell.tab_tour'),
                ),
                UgamDockItem(
                  icon: Icons.table_chart_rounded,
                  tooltip: tr('main_shell.tab_charts'),
                ),
                UgamDockItem(
                  icon: Icons.chat_bubble_rounded,
                  tooltip: tr('main_shell.tab_requests'),
                ),
                UgamDockItem(
                  icon: Icons.settings_rounded,
                  tooltip: tr('main_shell.tab_settings'),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
