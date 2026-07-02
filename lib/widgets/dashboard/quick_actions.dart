import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/tour_controller.dart';
import '../../design/ugam.dart';
import '../../models/tour_status.dart';
import '../../screens/create_tour_screen.dart';
import '../../screens/main_shell.dart';
import '../../screens/tour_money_board_screen.dart';

/// The dashboard quick-action row: Create · Requests · Money · Charts. Tiles
/// that aren't a dock tab (Create, Money) push a screen; the rest switch tabs.
class DashboardQuickActions extends StatelessWidget {
  final UgamColorSet c;
  final ShellController shell;
  const DashboardQuickActions({super.key, required this.c, required this.shell});

  /// Money has no dock tab, so the tile opens the money board of the nearest
  /// active tour (falling back to the Tours tab when nothing's running yet).
  void _openMoney(BuildContext context) {
    final active = Get.find<TourController>()
        .tours
        .where((t) => t.status != TourStatus.completed)
        .toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
    if (active.isEmpty) {
      shell.switchTab(1);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TourMoneyBoardScreen(tourId: active.first.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _QA(
            label: tr('dashboard.qa_create'),
            icon: Icons.add_rounded,
            c: c,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CreateTourScreen()),
            ),
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: _QA(
            label: tr('dashboard.qa_requests'),
            icon: Icons.inbox_rounded,
            c: c,
            onTap: () => shell.switchTab(3),
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: _QA(
            label: tr('dashboard.qa_money'),
            icon: Icons.account_balance_wallet_rounded,
            c: c,
            onTap: () => _openMoney(context),
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: _QA(
            label: tr('main_shell.tab_charts'),
            icon: Icons.table_chart_rounded,
            c: c,
            onTap: () => shell.switchTab(2),
          ),
        ),
      ],
    );
  }
}

class _QA extends StatelessWidget {
  final String label;
  final IconData icon;
  final UgamColorSet c;
  final VoidCallback onTap;
  const _QA({
    required this.label,
    required this.icon,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
      child: Column(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 20, color: c.ink),
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(
            label,
            style: UgamText.caption.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
