import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/auth_controller.dart';
import '../models/profile.dart';
import 'dashboard_screen.dart';
import 'tours_screen.dart';
import 'requests_screen.dart';
import 'assign_screen.dart';
import 'notify_screen.dart';
import 'passenger_home_screen.dart';

/// Lightweight controller so any descendant can switch tabs.
class ShellController extends GetxController {
  final currentIndex = 0.obs;
  void switchTab(int i) => currentIndex.value = i;
}

class MainShell extends StatelessWidget {
  const MainShell({super.key});

  static const _adminPages = <Widget>[
    DashboardScreen(),
    ToursScreen(),
    RequestsScreen(),
    AssignScreen(),
    NotifyScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthController>();
    final shell = Get.find<ShellController>();

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
    );

    return Obx(() {
      // Passenger view — no bottom nav, just their bookings
      if (auth.userRole.value == UserRole.passenger) {
        return const PassengerHomeScreen();
      }

      // Admin view — full dashboard with bottom nav
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        extendBody: true,
        body: IndexedStack(
          index: shell.currentIndex.value,
          children: _adminPages,
        ),
        bottomNavigationBar: _PillBottomNav(
          currentIndex: shell.currentIndex.value,
          onTap: shell.switchTab,
        ),
      );
    });
  }
}

// ── Pill-style Bottom Navigation ────────────────────────────────────

class _PillBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _PillBottomNav({required this.currentIndex, required this.onTap});

  static const _tabs = <_TabData>[
    _TabData(icon: Icons.home_rounded, label: 'HOME'),
    _TabData(icon: Icons.location_on_rounded, label: 'TOUR'),
    _TabData(icon: Icons.chat_bubble_rounded, label: 'REQUESTS'),
    _TabData(icon: Icons.grid_view_rounded, label: 'ASSIGN'),
    _TabData(icon: Icons.notifications_rounded, label: 'NOTIFY'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 21, 12, 21),
      child: Container(
        height: 62,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppTheme.cardDark
              : Colors.white,
          borderRadius: BorderRadius.circular(36),
          border: Border.all(
            color: Theme.of(context).brightness == Brightness.dark
                ? AppTheme.borderDark
                : AppTheme.borderLight,
            width: 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x08000000),
              offset: Offset(0, 1),
              blurRadius: 3,
            ),
            BoxShadow(
              color: Color(0x0A000000),
              offset: Offset(0, 8),
              blurRadius: 24,
            ),
          ],
        ),
        child: Row(
          children: List.generate(_tabs.length, (index) {
            final tab = _tabs[index];
            final isActive = index == currentIndex;
            return Expanded(
              child: GestureDetector(
                onTap: () => onTap(index),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  decoration: BoxDecoration(
                    color: isActive ? AppTheme.brand : Colors.transparent,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        tab.icon,
                        size: 18,
                        color: isActive ? Colors.white : AppTheme.textMuted,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        tab.label,
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                          color:
                              isActive ? Colors.white : AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _TabData {
  final IconData icon;
  final String label;
  const _TabData({required this.icon, required this.label});
}
