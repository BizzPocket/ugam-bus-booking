import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import 'dashboard_screen.dart';
import 'tours_screen.dart';
import 'requests_screen.dart';
import 'seat_assignment_screen.dart';
import 'notify_screen.dart';

class ShellController extends GetxController {
  final currentIndex = 0.obs;
  void switchTab(int i) => currentIndex.value = i;
}

/// Max body width for the admin shell. The app is designed phone-first, so
/// on wide screens (tablet, desktop, web) we cap and center the content
/// rather than letting it sprawl. Keeps the FAB and pill nav within reach
/// of the touch target.
const double _kAdminMaxWidth = 540;

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  static const _adminPages = <Widget>[
    DashboardScreen(),
    ToursScreen(),
    RequestsScreen(),
    SeatAssignmentScreen(),
    NotifyScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final shell = Get.find<ShellController>();

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
    );

    return Obx(() {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        extendBody: true,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kAdminMaxWidth),
            child: IndexedStack(
              index: shell.currentIndex.value,
              children: _adminPages,
            ),
          ),
        ),
        // Align with heightFactor: 1.0 sizes the slot to the pill's
        // natural height (Center would expand to fill the Scaffold), while
        // passing parent width constraints through to the child (Row would
        // hand it unbounded width and overflow on phones < 540px wide).
        bottomNavigationBar: Align(
          alignment: Alignment.center,
          heightFactor: 1.0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kAdminMaxWidth),
            child: _PillBottomNav(
              currentIndex: shell.currentIndex.value,
              onTap: shell.switchTab,
            ),
          ),
        ),
      );
    });
  }
}

class _PillBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _PillBottomNav({required this.currentIndex, required this.onTap});

  static const _tabs = <_TabData>[
    _TabData(icon: Icons.home_rounded, labelKey: 'main_shell.tab_home'),
    _TabData(icon: Icons.location_on_rounded, labelKey: 'main_shell.tab_tour'),
    _TabData(icon: Icons.chat_bubble_rounded, labelKey: 'main_shell.tab_requests'),
    _TabData(icon: Icons.grid_view_rounded, labelKey: 'main_shell.tab_assign'),
    _TabData(icon: Icons.notifications_rounded, labelKey: 'main_shell.tab_notify'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final scheme = theme.colorScheme;

    final surface = isDark ? AppTheme.cardDark : scheme.surface;
    final border = isDark ? AppTheme.borderDark : AppTheme.borderLight;
    final inactiveFg = scheme.onSurfaceVariant;

    // SafeArea wraps the pill so it sits above the OS gesture inset on
    // modern phones without us padding for it manually. Tighter outer
    // padding (8/10) replaces the old 21px slab that was wasting ~30%
    // of the bottom area on every screen.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Container(
          height: 58,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: surface,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: border, width: 1),
            boxShadow: [
              BoxShadow(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.35)
                    : Colors.black.withValues(alpha: 0.05),
                offset: const Offset(0, 4),
                blurRadius: 16,
              ),
            ],
          ),
          child: Row(
            children: List.generate(_tabs.length, (index) {
              final tab = _tabs[index];
              final isActive = index == currentIndex;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onTap(index);
                  },
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color: isActive ? AppTheme.brand : Colors.transparent,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          tab.icon,
                          size: 18,
                          color: isActive ? Colors.white : inactiveFg,
                        ),
                        // Labels appear only on the active tab so the
                        // inactive ones don't pull visual weight. Compact
                        // labels are the iOS-style pattern most users
                        // already expect from mobile chrome.
                        AnimatedSize(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOut,
                          child: isActive
                              ? Padding(
                                  padding:
                                      const EdgeInsets.only(top: 2),
                                  child: Text(
                                    tr(tab.labelKey),
                                    style: GoogleFonts.inter(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.6,
                                      color: Colors.white,
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _TabData {
  final IconData icon;
  final String labelKey;
  const _TabData({required this.icon, required this.labelKey});
}
