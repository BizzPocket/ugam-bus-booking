import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/payment_status.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/trip_type.dart';
import '../routes/app_routes.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_dialogs.dart';
import '../utils/formatters.dart';
import '../utils/app_snackbar.dart';
import 'add_bus_screen.dart';
import 'edit_tour_screen.dart';
import 'manage_buses_screen.dart';
import 'notify_screen.dart';
import 'requests_screen.dart';

/// Admin's single-tour workspace.
///
/// Layout:
///   [Hero (320px) — bus backdrop, floating back / status / edit chrome,
///    overlay summary card pulled up to overlap]
///   [Tab pills: Overview · Passengers · Buses · Activity]
///   [Body — switches per tab]
///   [Sticky bottom action — contextual per tab]
///
/// Business logic is unchanged from the previous incarnation:
/// `TourController.getTour`, `ManageBusesScreen`, `TourSeatAssignmentScreen`,
/// `EditTourScreen`, `AddBusScreen` are all reused as before.
class TourDetailScreen extends StatefulWidget {
  final String tourId;
  const TourDetailScreen({super.key, required this.tourId});

  @override
  State<TourDetailScreen> createState() => _TourDetailScreenState();
}

class _TourDetailScreenState extends State<TourDetailScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return Obx(() {
      final tour = tourCtrl.getTour(widget.tourId);
      if (tour == null) {
        return Scaffold(
          backgroundColor: c.bg,
          body: SafeArea(
            child: UgamEmpty(
              icon: Icons.search_off_rounded,
              title: tr('tour_detail.not_found_title'),
              body: tr('tour_detail.not_found_body'),
              cta: UgamCTA(
                label: tr('app.action.back'),
                leadingIcon: Icons.arrow_back_rounded,
                onPressed: () => Get.back(),
              ),
            ),
          ),
        );
      }

      return Scaffold(
        backgroundColor: c.bg,
        extendBody: true,
        body: RefreshIndicator(
          color: c.accent,
          onRefresh: tourCtrl.refreshTours,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(
                child: _HeroSection(
                  tour: tour,
                  onBack: () => Get.back(),
                  onEdit: () => Get.to(
                    () => EditTourScreen(tourId: widget.tourId),
                    transition: Transition.cupertino,
                  ),
                  onDelete: () => _confirmDelete(tourCtrl, tour),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.huge,
                    UgamSpacing.gutter,
                    UgamSpacing.lg,
                  ),
                  child: _TabBar(
                    index: _tabIndex,
                    counts: [
                      null,
                      tour.passengerCount == 0 ? null : tour.passengerCount,
                      tour.buses.isEmpty ? null : tour.buses.length,
                      null,
                    ],
                    onChanged: (i) => setState(() => _tabIndex = i),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  0,
                  UgamSpacing.gutter,
                  140,
                ),
                sliver: _buildTabBody(tour, c),
              ),
            ],
          ),
        ),
        bottomNavigationBar: _StickyAction(
          tour: tour,
          tab: _tabIndex,
          c: c,
          onSwitchTab: (i) => setState(() => _tabIndex = i),
        ),
      );
    });
  }

  Future<void> _confirmDelete(TourController tourCtrl, Tour tour) async {
    final ok = await AppDialogs.confirm(
      title: tr('tour_detail.delete_confirm_title'),
      message: tr('tour_detail.delete_confirm_body',
          namedArgs: {'title': tour.title}),
      confirmText: tr('tour_detail.delete_tour'),
      isDestructive: true,
    );
    if (!ok) return;
    try {
      await tourCtrl.deleteTour(tour.id);
      Get.back();
      AppSnackBar.success(tr('tour_detail.snack_tour_deleted'));
    } catch (_) {
      // deleteTour already surfaces its own error snackbar.
    }
  }

  Widget _buildTabBody(Tour tour, UgamColorSet c) {
    switch (_tabIndex) {
      case 1:
        return _PassengersTab(tour: tour, c: c);
      case 2:
        return _BusesTab(tour: tour, c: c);
      case 3:
        return _ActivityTab(tour: tour, c: c);
      case 0:
      default:
        return _OverviewTab(
          tour: tour,
          c: c,
          onSwitchTab: (i) => setState(() => _tabIndex = i),
        );
    }
  }
}

// ─── HERO ─────────────────────────────────────────────────────────────

class _HeroSection extends StatelessWidget {
  final Tour tour;
  final VoidCallback onBack;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _HeroSection({
    required this.tour,
    required this.onBack,
    required this.onEdit,
    required this.onDelete,
  });

  /// Bottom sheet of tour-level actions (edit / delete), opened from the single
  /// overflow chrome circle so the hero stays uncluttered.
  void _showActions(BuildContext context) {
    final c = UgamColors.of(context);
    UgamSheet.show<void>(
      context,
      title: tr('tour_detail.actions_title'),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HeroActionRow(
            icon: Icons.edit_rounded,
            label: tr('tour_detail.edit_tour'),
            c: c,
            onTap: () {
              Get.back();
              onEdit();
            },
          ),
          const SizedBox(height: UgamSpacing.sm),
          _HeroActionRow(
            icon: Icons.delete_outline_rounded,
            label: tr('tour_detail.delete_tour'),
            c: c,
            danger: true,
            onTap: () {
              Get.back();
              onDelete();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final topInset = MediaQuery.of(context).padding.top;
    final statusTone = _toneFor(tour.status);
    return SizedBox(
      height: 320,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: UgamBusBackdrop(seed: tour.id)),
          // Top chrome row.
          Positioned(
            left: UgamSpacing.gutter,
            right: UgamSpacing.gutter,
            top: topInset + UgamSpacing.sm,
            child: Row(
              children: [
                UgamIconButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: onBack,
                  size: 42,
                  semanticLabel: tr('app.action.back'),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _toneColor(statusTone, c),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        tour.status.displayName.toUpperCase(),
                        style: UgamText.micro
                            .copyWith(color: Colors.white, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // Single overflow entry — edit / delete live in the sheet.
                UgamIconButton(
                  icon: Icons.more_vert_rounded,
                  onTap: () => _showActions(context),
                  size: 42,
                  semanticLabel: tr('tour_detail.actions_title'),
                ),
              ],
            ),
          ),
          // Overlay card pulled past the hero bottom so it overlaps.
          Positioned(
            left: UgamSpacing.gutter,
            right: UgamSpacing.gutter,
            bottom: -28,
            child: UgamCard.plain(
              elev: true,
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.lg,
                UgamSpacing.md,
                UgamSpacing.md,
                UgamSpacing.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tour.title,
                          style:
                              UgamText.titleM.copyWith(color: c.ink, fontSize: 18),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.south_east_rounded,
                                size: 12, color: c.ink2),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${tour.fromCity} → ${tour.toCity}',
                                style: UgamText.caption.copyWith(
                                    color: c.ink2, fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: UgamSpacing.sm),
                            Text(
                              '·',
                              style: UgamText.caption
                                  .copyWith(color: c.ink3, fontSize: 11),
                            ),
                            const SizedBox(width: UgamSpacing.sm),
                            Text(
                              _durationLabel(context, tour),
                              style: UgamText.tabular(
                                UgamText.caption
                                    .copyWith(color: c.ink2, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        UgamStatusDot(
                          label: tour.status.description,
                          tone: statusTone,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.md,
                      vertical: UgamSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          Formatters.formatMoneyInr(tour.pricePerSeat),
                          style: UgamText.tabular(
                            UgamText.titleM
                                .copyWith(color: c.accent, fontSize: 18),
                          ),
                        ),
                        Text(tr('tour_detail.per_seat'),
                            style: UgamText.caption
                                .copyWith(color: c.accent, fontSize: 10)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _durationLabel(BuildContext context, Tour t) {
    final r = t.returnDate;
    final locale = context.locale.toString();
    if (r == null) {
      return Formatters.formatDateShort(t.departureDate, locale: locale);
    }
    final days = r.difference(t.departureDate).inDays + 1;
    return days == 1
        ? tr('tour_detail.duration_day_one')
        : tr('tour_detail.duration_day_other', namedArgs: {'n': '$days'});
  }
}

/// A full-width tappable row inside the hero actions sheet (icon square +
/// label). `danger` tints it with the destructive colour for Delete.
class _HeroActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final UgamColorSet c;
  final VoidCallback onTap;
  final bool danger;

  const _HeroActionRow({
    required this.icon,
    required this.label,
    required this.c,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? c.danger : c.ink;
    final tint = danger ? c.danger : c.accent;
    final fill = danger
        ? c.danger.withValues(alpha: 0.12)
        : c.accentFill;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 19, color: tint),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                label,
                style: UgamText.titleS.copyWith(color: fg, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── TAB BAR ──────────────────────────────────────────────────────────

class _TabBar extends StatelessWidget {
  final int index;
  final List<int?> counts;
  final ValueChanged<int> onChanged;

  const _TabBar({
    required this.index,
    required this.counts,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final labels = [
      tr('tour_detail.tab_overview'),
      tr('tour_detail.tab_passengers'),
      tr('tour_detail.tab_buses'),
      tr('tour_detail.tab_activity'),
    ];
    return UgamTabPills(
      currentIndex: index,
      onChanged: onChanged,
      items: List.generate(labels.length, (i) {
        return UgamTabItem(label: labels[i], count: counts[i]);
      }),
    );
  }
}

// ─── OVERVIEW TAB ─────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _OverviewTab({
    required this.tour,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    final action = _nextActionFor(tour);
    final paid = tour.passengers
        .where((p) => p.paymentStatus == PaymentStatus.paid)
        .length;
    final pending = tour.passengers
        .where((p) => p.paymentStatus == PaymentStatus.notPaid)
        .length;
    final revenue = paid * tour.pricePerSeat;

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _NextActionCard(
          tour: tour,
          action: action,
          c: c,
          onSwitchTab: onSwitchTab,
        ),
        const SizedBox(height: UgamSpacing.lg),
        _SectionEyebrow(label: tr('tour_detail.at_a_glance'), c: c),
        const SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            Expanded(
              child: UgamStatTile(
                icon: Icons.check_circle_rounded,
                value: '$paid',
                label: tr('app.label.booked'),
                variant: UgamStatVariant.good,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.access_time_rounded,
                value: '$pending',
                label: tr('tour_detail.stat_pending_pay'),
                variant: UgamStatVariant.warm,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            Expanded(
              child: UgamStatTile(
                icon: Icons.event_seat_rounded,
                value: tour.totalBusSeats > 0
                    ? '${tour.totalSeatsAssigned}'
                    : '—',
                ofTotal: tour.totalBusSeats > 0
                    ? '/${tour.totalBusSeats}'
                    : null,
                label: tr('tour_detail.stat_assigned'),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.currency_rupee_rounded,
                value: Formatters.formatMoneyInrCompact(revenue),
                label: tr('tour_detail.stat_revenue'),
                variant: UgamStatVariant.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.xl),
        _SectionEyebrow(label: tr('tour_detail.manage'), c: c),
        const SizedBox(height: UgamSpacing.md),
        _TourTools(tour: tour, c: c),
        const SizedBox(height: UgamSpacing.xl),
        _BroadcastCard(tour: tour, c: c),
      ]),
    );
  }

}

class _NextActionCard extends StatelessWidget {
  final Tour tour;
  final _NextAction action;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _NextActionCard({
    required this.tour,
    required this.action,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    final tone = action.tone;
    final fg = _toneColor(tone, c);
    // Tappable: fires the SAME action as the bottom sticky CTA (reuses
    // _runAction) so the card and the sticky button stay in lock-step.
    return UgamCard.plain(
      tone: _cardToneFor(tone),
      onTap: () => _runAction(action, tour, onSwitchTab),
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(action.icon, size: 20, color: fg),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('tour_detail.next_action'),
                      style: UgamText.micro.copyWith(color: fg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      action.title,
                      style:
                          UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.arrow_forward_rounded, size: 18, color: fg),
            ],
          ),
          if (action.subtitle != null) ...[
            const SizedBox(height: UgamSpacing.sm + 2),
            Text(
              action.subtitle!,
              style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

UgamCardTone _cardToneFor(UgamStatusTone t) => switch (t) {
      UgamStatusTone.accent => UgamCardTone.accent,
      UgamStatusTone.good => UgamCardTone.good,
      UgamStatusTone.warm => UgamCardTone.warm,
      UgamStatusTone.neutral => UgamCardTone.none,
    };

/// A single broadcast card: campaign icon + title + hint, a PRIMARY
/// "Send broadcast on WhatsApp" CTA (opens WhatsApp's own broadcast/group
/// picker with the message pre-filled), plus a small secondary copy icon that
/// drops the announcement on the clipboard. Replaces the previous two stacked
/// elements (copy-card + send-CTA).
class _BroadcastCard extends StatefulWidget {
  final Tour tour;
  final UgamColorSet c;
  const _BroadcastCard({required this.tour, required this.c});

  @override
  State<_BroadcastCard> createState() => _BroadcastCardState();
}

class _BroadcastCardState extends State<_BroadcastCard> {
  bool _sending = false;

  Future<void> _send() async {
    if (_sending) return;

    setState(() => _sending = true);
    try {
      // Free broadcast: copy the message + open WhatsApp's own broadcast/group
      // picker with it pre-filled. No Cloud API, no server, no Meta approval —
      // the agent taps their saved Broadcast List or group to actually send.
      final opened = await WhatsAppService().broadcastTour(tour: widget.tour);
      if (!mounted) return;
      if (opened) {
        AppSnackBar.success(tr('tour_detail.snack_broadcast_opened'));
      } else {
        AppSnackBar.warning(
          tr('tour_detail.snack_broadcast_copied_only'),
          title: tr('tour_detail.whatsapp_unavailable_title'),
        );
      }
    } catch (e) {
      if (mounted) {
        AppSnackBar.error(
          tr('tour_detail.snack_broadcast_error', namedArgs: {'error': '$e'}),
          title: tr('tour_detail.send_failed_title'),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _copy() async {
    HapticFeedback.lightImpact();
    await WhatsAppService().copyAnnouncementToClipboard(tour: widget.tour);
    AppSnackBar.success(tr('tour_detail.snack_broadcast_copied'));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg - 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: c.goodFill,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.campaign_rounded, size: 22, color: c.good),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('tour_detail.broadcast_this_tour'),
                      style:
                          UgamText.titleS.copyWith(color: c.ink, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('tour_detail.broadcast_copy_hint'),
                      style: UgamText.caption
                          .copyWith(color: c.ink2, fontSize: 11.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              // Demoted from solid-gold UgamCTA to TONAL — the bottom sticky CTA
              // is the one rationed champagne focal point per screen.
              Expanded(
                child: UgamButton(
                  label: _sending
                      ? tr('tour_detail.sending_broadcast')
                      : tr('tour_detail.send_broadcast_whatsapp'),
                  icon: Icons.send_rounded,
                  kind: UgamButtonKind.tonal,
                  loading: _sending,
                  expand: true,
                  onPressed: _send,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              UgamIconButton(
                icon: Icons.copy_rounded,
                onTap: _copy,
                size: 50,
                iconSize: 18,
                semanticLabel: tr('tour_detail.copy_broadcast_message'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── PASSENGERS TAB ───────────────────────────────────────────────────

class _PassengersTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _PassengersTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final all = tour.passengers;

    if (all.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.huge),
          child: Column(
            children: [
              UgamEmpty(
                icon: Icons.people_outline_rounded,
                title: tr('tour_detail.no_passengers_title'),
                body: tr('tour_detail.no_passengers_body'),
                cta: UgamCTA(
                  label: tr('tour_detail.copy_broadcast_message'),
                  leadingIcon: Icons.copy_rounded,
                  onPressed: () async {
                    HapticFeedback.lightImpact();
                    await WhatsAppService()
                        .copyAnnouncementToClipboard(tour: tour);
                    AppSnackBar.success(tr('tour_detail.snack_broadcast_copied'));
                  },
                ),
              ),
              const SizedBox(height: UgamSpacing.lg),
              // Always-available manual path: add a request on behalf of a
              // customer (with the phone-contacts picker) even before anyone
              // has booked.
              _ManageRequestsButton(
                c: c,
                onTap: () => Get.to(
                  () => RequestsScreen(initialTourId: tour.id),
                  transition: Transition.cupertino,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final newCount =
        all.where((p) => p.assignedSeats.isEmpty && !p.isWaitlisted).length;
    final waitlistCount = all.where((p) => p.isWaitlisted).length;
    final allottedCount = all.where((p) => p.totalSeatsAssigned > 0).length;

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        // First-class entry into the full per-tour requests manager
        // (add / edit / waitlist / search). Tour-first: requests live inside
        // the tour, not on a separate global tab. Management itself lives only
        // on the dedicated RequestsScreen — this tab is read-only.
        _ManageRequestsButton(
          c: c,
          onTap: () => Get.to(
            () => RequestsScreen(initialTourId: tour.id),
            transition: Transition.cupertino,
          ),
        ),
        const SizedBox(height: UgamSpacing.md),
        // Read-only count summary (NOT tabs) — at-a-glance breakdown only.
        Row(
          children: [
            _CountChip(label: tr('tour_detail.filter_new'), count: newCount, c: c),
            const SizedBox(width: UgamSpacing.sm),
            _CountChip(
                label: tr('tour_detail.filter_waitlist'),
                count: waitlistCount,
                c: c),
            const SizedBox(width: UgamSpacing.sm),
            _CountChip(
                label: tr('tour_detail.filter_assigned'),
                count: allottedCount,
                c: c),
          ],
        ),
        const SizedBox(height: UgamSpacing.lg),
        // Full roster, read-only, unfiltered.
        for (var i = 0; i < all.length; i++) ...[
          _PassengerRow(passenger: all[i], c: c),
          if (i != all.length - 1) const SizedBox(height: UgamSpacing.sm + 2),
        ],
      ]),
    );
  }
}

/// A small, non-interactive count label (read-only) used in the Passengers tab
/// summary row — looks like a pill but is NOT a tab.
class _CountChip extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  const _CountChip({required this.label, required this.count, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: UgamText.caption.copyWith(color: c.ink2, fontSize: 11.5),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: UgamText.tabular(
              UgamText.caption.copyWith(
                color: c.ink,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-width entry into the per-tour requests manager. Lives at the top of
/// the Passengers tab so adding/editing/waitlisting a request is one tap from
/// the tour workspace.
class _ManageRequestsButton extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _ManageRequestsButton({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.edit_note_rounded, size: 19, color: c.accent),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('tour_detail.manage_requests'),
                  style: UgamText.titleS.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('tour_detail.manage_requests_hint'),
                  style: UgamText.caption.copyWith(color: c.ink3),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
        ],
      ),
    );
  }
}

class _PassengerRow extends StatelessWidget {
  final Passenger passenger;
  final UgamColorSet c;

  const _PassengerRow({required this.passenger, required this.c});

  @override
  Widget build(BuildContext context) {
    final tone = _passengerTone(passenger);
    final dotColor = _toneColor(tone, c);
    return UgamCard.plain(
      elev: true,
      radius: UgamRadius.row,
      padding: const EdgeInsets.all(UgamSpacing.md - 2),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.card,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initials(passenger.name),
              style:
                  UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12),
            ),
          ),
          const SizedBox(width: UgamSpacing.md - 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        passenger.name,
                        style: UgamText.bodyStrong
                            .copyWith(color: c.ink, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _ago(passenger.createdAt),
                      style: UgamText.tabular(
                        UgamText.caption
                            .copyWith(color: c.ink3, fontSize: 10.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        passenger.requestSummary,
                        style: UgamText.caption
                            .copyWith(color: c.ink2, fontSize: 11.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      passenger.progressLabel,
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(
                          color: dotColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  UgamStatusTone _passengerTone(Passenger p) {
    if (p.isFullyAssigned) return UgamStatusTone.good;
    if (p.isPartiallyAssigned) return UgamStatusTone.accent;
    if (p.isWaitlisted) return UgamStatusTone.warm;
    return UgamStatusTone.neutral;
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays > 0) return '${d.inDays}d';
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return tr('tour_detail.ago_now');
  }
}

// ─── BUSES TAB ────────────────────────────────────────────────────────

class _BusesTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _BusesTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    if (tour.buses.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.huge),
          child: UgamEmpty(
            icon: Icons.directions_bus_outlined,
            title: tr('tour_detail.no_buses_title'),
            body: tr('tour_detail.no_buses_body'),
            cta: UgamCTA(
              label: tr('tour_detail.add_bus'),
              leadingIcon: Icons.add_rounded,
              onPressed: () => Get.to(
                () => AddBusScreen(tourId: tour.id),
                transition: Transition.cupertino,
              ),
            ),
          ),
        ),
      );
    }

    // ONE add-bus affordance per screen: the sticky bottom CTA owns "Add
    // another bus" (see _StickyAction case 2). The previously-duplicated inline
    // _AddBusTile is intentionally omitted here so the entry isn't doubled.
    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        for (var i = 0; i < tour.buses.length; i++) ...[
          _BusListItem(bus: tour.buses[i], c: c),
          if (i != tour.buses.length - 1)
            const SizedBox(height: UgamSpacing.md),
        ],
      ]),
    );
  }
}

class _BusListItem extends StatelessWidget {
  final Bus bus;
  final UgamColorSet c;
  const _BusListItem({required this.bus, required this.c});

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.sm),
      onTap: () {
        HapticFeedback.selectionClick();
        Get.to(
          () => ManageBusesScreen(tourId: bus.tourId ?? ''),
          transition: Transition.cupertino,
        );
      },
      child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 84,
                height: 84,
                child: UgamBusBackdrop(seed: '${bus.id}-bus'),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bus.busNumber.isNotEmpty ? bus.busNumber : bus.name,
                    style:
                        UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    bus.driverName.isNotEmpty
                        ? bus.driverName
                        : tr('tour_detail.driver_not_set'),
                    style: UgamText.caption.copyWith(
                      color: bus.driverName.isNotEmpty ? c.ink2 : c.ink3,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  Row(
                    children: [
                      if (bus.isAC) ...[
                        const UgamReqChip(label: 'AC'),
                        const SizedBox(width: 5),
                      ],
                      UgamReqChip(
                        label: tr('tour_detail.seats_count',
                            namedArgs: {'n': '${bus.totalSeats}'}),
                        variant: UgamChipVariant.neutral,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.accentFill,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_forward_rounded,
                  size: 16, color: c.accent),
            ),
          ],
        ),
      );
  }
}

// ─── ACTIVITY TAB ─────────────────────────────────────────────────────

class _ActivityTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _ActivityTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final events = _buildEvents(tour);
    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _SectionEyebrow(label: tr('tour_detail.timeline'), c: c),
        const SizedBox(height: UgamSpacing.md),
        for (var i = 0; i < events.length; i++)
          _TimelineRow(
            event: events[i],
            isFirst: i == 0,
            isLast: i == events.length - 1,
            c: c,
          ),
      ]),
    );
  }

  List<_TimelineEvent> _buildEvents(Tour t) {
    final events = <_TimelineEvent>[];

    events.add(_TimelineEvent(
      icon: Icons.add_circle_rounded,
      title: tr('tour_detail.event_tour_created'),
      time: t.createdAt,
      tone: UgamStatusTone.neutral,
    ));

    if (t.passengers.isNotEmpty) {
      final earliest = t.passengers
          .map((p) => p.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final first = t.passengers.firstWhere(
        (p) => p.createdAt == earliest,
        orElse: () => t.passengers.first,
      );
      events.add(_TimelineEvent(
        icon: Icons.person_add_alt_1_rounded,
        title: tr('tour_detail.event_first_request',
            namedArgs: {'name': first.name}),
        time: earliest,
        tone: UgamStatusTone.accent,
      ));

      if (t.passengers.length > 1) {
        final latestReq = t.passengers
            .map((p) => p.createdAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);
        if (latestReq != earliest) {
          events.add(_TimelineEvent(
            icon: Icons.groups_rounded,
            title: tr('tour_detail.event_requests_total',
                namedArgs: {'n': '${t.passengers.length}'}),
            time: latestReq,
            tone: UgamStatusTone.accent,
          ));
        }
      }
    }

    if (t.buses.isNotEmpty) {
      final earliestBus = t.buses
          .map((b) => b.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      events.add(_TimelineEvent(
        icon: Icons.directions_bus_rounded,
        title: t.buses.length == 1
            ? tr('tour_detail.event_bus_added')
            : tr('tour_detail.event_buses_added',
                namedArgs: {'n': '${t.buses.length}'}),
        time: earliestBus,
        tone: UgamStatusTone.accent,
      ));
    }

    if (t.totalSeatsAssigned > 0) {
      events.add(_TimelineEvent(
        icon: Icons.event_seat_rounded,
        title: t.totalSeatsAssigned == 1
            ? tr('tour_detail.event_seats_assigned_one')
            : tr('tour_detail.event_seats_assigned_other',
                namedArgs: {'n': '${t.totalSeatsAssigned}'}),
        time: t.updatedAt,
        tone: UgamStatusTone.accent,
      ));
    }

    if (t.allSeatsAssigned) {
      events.add(_TimelineEvent(
        icon: Icons.check_circle_rounded,
        title: tr('tour_detail.event_all_seats_assigned'),
        time: t.updatedAt,
        tone: UgamStatusTone.good,
      ));
    }

    if (t.status == TourStatus.locked || t.status == TourStatus.completed) {
      events.add(_TimelineEvent(
        icon: Icons.lock_rounded,
        title: tr('tour_detail.event_tour_locked'),
        time: t.updatedAt,
        tone: UgamStatusTone.good,
      ));
    }

    if (t.status == TourStatus.completed) {
      events.add(_TimelineEvent(
        icon: Icons.flag_rounded,
        title: tr('tour_detail.event_trip_completed'),
        time: t.updatedAt,
        tone: UgamStatusTone.neutral,
      ));
    }

    events.sort((a, b) => a.time.compareTo(b.time));
    return events;
  }
}

class _TimelineEvent {
  final IconData icon;
  final String title;
  final DateTime time;
  final UgamStatusTone tone;
  const _TimelineEvent({
    required this.icon,
    required this.title,
    required this.time,
    required this.tone,
  });
}

class _TimelineRow extends StatelessWidget {
  final _TimelineEvent event;
  final bool isFirst;
  final bool isLast;
  final UgamColorSet c;

  const _TimelineRow({
    required this.event,
    required this.isFirst,
    required this.isLast,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final tone = _toneColor(event.tone, c);
    final fill = _toneFill(event.tone, c);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 36,
            child: Column(
              children: [
                if (isFirst)
                  const SizedBox(height: 8)
                else
                  Expanded(
                    child: Container(
                      width: 2,
                      color: c.border,
                    ),
                  ),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    border: Border.all(color: tone, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Icon(event.icon, size: 13, color: tone),
                ),
                if (isLast)
                  const SizedBox(height: 8)
                else
                  Expanded(
                    child: Container(
                      width: 2,
                      color: c.border,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
              child: UgamCard.plain(
                elev: true,
                radius: 14,
                padding: const EdgeInsets.all(UgamSpacing.md - 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      event.title,
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _agoLine(event.time),
                      style: UgamText.tabular(
                        UgamText.caption
                            .copyWith(color: c.ink3, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _agoLine(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays > 6) return DateFormat('MMM d · h:mm a').format(t);
    if (d.inDays > 0) {
      return d.inDays == 1
          ? tr('tour_detail.ago_day_one')
          : tr('tour_detail.ago_day_other', namedArgs: {'n': '${d.inDays}'});
    }
    if (d.inHours > 0) {
      return tr('tour_detail.ago_hours', namedArgs: {'n': '${d.inHours}'});
    }
    if (d.inMinutes > 0) {
      return tr('tour_detail.ago_minutes', namedArgs: {'n': '${d.inMinutes}'});
    }
    return tr('tour_detail.ago_just_now');
  }
}

// ─── STICKY ACTION BAR ────────────────────────────────────────────────

class _StickyAction extends StatelessWidget {
  final Tour tour;
  final int tab;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _StickyAction({
    required this.tour,
    required this.tab,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    if (tab == 3) {
      // Activity tab → no sticky action (back button is enough).
      return const SizedBox.shrink();
    }

    final cta = _buildCta(context);
    if (cta == null) return const SizedBox.shrink();

    return UgamStickyCTA(child: cta);
  }

  Widget? _buildCta(BuildContext context) {
    switch (tab) {
      case 1:
        // Standardized seating entry: single "Seats" label that opens the
        // SeatsScreen SUMMARY (AppRoutes.tourOverview -> SeatsMode.summary).
        return UgamCTA(
          label: tr('seats.title'),
          leadingIcon: Icons.event_seat_rounded,
          trailingValue: tour.totalBusSeats > 0
              ? '${tour.totalSeatsAssigned}/${tour.totalBusSeats}'
              : null,
          onPressed: tour.buses.isEmpty
              ? null
              : () => Get.toNamed(
                    AppRoutes.tourOverview,
                    arguments: {'tourId': tour.id},
                  ),
        );
      case 2:
        return UgamCTA(
          label: tour.buses.isEmpty
              ? tr('tour_detail.add_bus')
              : tr('tour_detail.add_another_bus'),
          leadingIcon: Icons.add_rounded,
          onPressed: () => Get.to(
            () => AddBusScreen(tourId: tour.id),
            transition: Transition.cupertino,
          ),
        );
      case 0:
      default:
        final action = _nextActionFor(tour);
        return UgamCTA(
          label: action.ctaLabel,
          leadingIcon: action.icon,
          onPressed: () => _runAction(action, tour, onSwitchTab),
        );
    }
  }
}

void _runAction(
  _NextAction action,
  Tour tour,
  ValueChanged<int> onSwitchTab,
) {
  switch (action.kind) {
    case _NextActionKind.addBus:
      Get.to(
        () => ManageBusesScreen(tourId: tour.id),
        transition: Transition.cupertino,
      );
      break;
    case _NextActionKind.assignSeats:
      // "Seats" entry -> SeatsScreen SUMMARY (tourOverview), never the bare grid.
      Get.toNamed(
        AppRoutes.tourOverview,
        arguments: {'tourId': tour.id},
      );
      break;
    case _NextActionKind.pickHandler:
      // Handler picking lives in ManageBusesScreen (per-bus handler picker),
      // not the seat screen — route the agent there.
      Get.to(
        () => ManageBusesScreen(tourId: tour.id),
        transition: Transition.cupertino,
      );
      break;
    case _NextActionKind.lockAndNotify:
      // Push the tour-scoped Notify screen for THIS tour.
      Get.to(
        () => NotifyScreen(tourId: tour.id),
        transition: Transition.cupertino,
      );
      break;
    case _NextActionKind.completeGoLeg:
      () async {
        final ctrl = Get.find<TourController>();
        final n = ctrl.outboundOnlyActiveCount(tour.id);
        final ok = await AppDialogs.confirm(
          title: tr('tour_detail.complete_go_confirm_title'),
          message: tr('tour_detail.complete_go_confirm_body',
              namedArgs: {'count': '$n'}),
          confirmText: tr('tour_detail.complete_go_cta'),
        );
        if (ok) {
          final cleared = await ctrl.completeOutboundLeg(tour.id);
          AppSnackBar.success(tr('tour_detail.complete_go_done',
              namedArgs: {'count': '$cleared'}));
        }
      }();
      break;
    case _NextActionKind.markCompleted:
      () async {
        final ok = await AppDialogs.confirm(
          title: tr('tour_detail.complete_confirm_title'),
          message: tr('tour_detail.complete_confirm_body',
              namedArgs: {'title': tour.title}),
          confirmText: tr('tour_detail.mark_completed'),
        );
        if (ok) {
          await Get.find<TourController>().completeTour(tour.id);
        }
      }();
      break;
    case _NextActionKind.allSet:
      onSwitchTab(3); // jump to activity
      break;
  }
}

// ─── HELPERS / SHARED MODELS ──────────────────────────────────────────

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: UgamText.micro.copyWith(color: c.ink3));
  }
}

/// Always-visible tour-action tiles. The tour-first nav removed the global
/// Notify/Money tabs, so every tour function must be reachable here from the
/// tour home: Seats, Lock & notify, Money, Groups. The Lock tile is highlighted
/// once the tour is ready to lock (all seats assigned + handler set) and flips
/// to "Send" after it's locked.
class _TourTools extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _TourTools({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final locked = tour.status == TourStatus.locked;
    final readyToLock = !locked &&
        tour.passengers.isNotEmpty &&
        tour.allSeatsAssigned &&
        tour.handlerId != null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _TourToolTile(
            icon: Icons.event_seat_rounded,
            label: tr('tour_detail.tool_seats'),
            c: c,
            onTap: () => Get.toNamed(
              AppRoutes.tourOverview,
              arguments: {'tourId': tour.id},
            ),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm + 2),
        Expanded(
          child: _TourToolTile(
            icon: locked ? Icons.send_rounded : Icons.lock_rounded,
            label: locked ? tr('tour_detail.tool_send') : tr('tour_detail.tool_lock'),
            c: c,
            highlight: readyToLock || locked,
            onTap: () => Get.to(
              () => NotifyScreen(tourId: tour.id),
              transition: Transition.cupertino,
            ),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm + 2),
        Expanded(
          child: _TourToolTile(
            icon: Icons.account_balance_wallet_rounded,
            label: tr('tour_detail.tool_money'),
            c: c,
            onTap: () => Get.toNamed(
              AppRoutes.tourMoney,
              arguments: {'tourId': tour.id},
            ),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm + 2),
        Expanded(
          child: _TourToolTile(
            icon: Icons.groups_rounded,
            label: tr('tour_detail.tool_groups'),
            c: c,
            onTap: () => Get.toNamed(
              AppRoutes.tourGroups,
              arguments: {'tourId': tour.id},
            ),
          ),
        ),
      ],
    );
  }
}

class _TourToolTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final UgamColorSet c;

  /// Draws the tile in the "good" accent — used for Lock/Send when the tour is
  /// ready to lock or already locked, so the next step stands out.
  final bool highlight;

  const _TourToolTile({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.c,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final accent = highlight ? c.good : c.accent;
    final fill = highlight ? c.goodFill : c.accentFill;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.card),
          border: Border.all(color: highlight ? c.good : c.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 20, color: accent),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: UgamText.caption.copyWith(color: c.ink2),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

enum _NextActionKind {
  addBus,
  assignSeats,
  pickHandler,
  lockAndNotify,
  completeGoLeg,
  markCompleted,
  allSet,
}

class _NextAction {
  final _NextActionKind kind;
  final String title;
  final String? subtitle;
  final String ctaLabel;
  final IconData icon;
  final UgamStatusTone tone;
  const _NextAction({
    required this.kind,
    required this.title,
    this.subtitle,
    required this.ctaLabel,
    required this.icon,
    required this.tone,
  });
}

_NextAction _nextActionFor(Tour tour) {
  if (tour.passengers.isNotEmpty && tour.buses.isEmpty) {
    return _NextAction(
      kind: _NextActionKind.addBus,
      title: tr('tour_detail.action_add_bus_title'),
      subtitle: tour.passengers.length == 1
          ? tr('tour_detail.action_add_bus_subtitle_one')
          : tr('tour_detail.action_add_bus_subtitle_other',
              namedArgs: {'n': '${tour.passengers.length}'}),
      ctaLabel: tr('tour_detail.add_bus'),
      icon: Icons.directions_bus_rounded,
      tone: UgamStatusTone.warm,
    );
  }
  if (tour.buses.isNotEmpty &&
      tour.totalSeatsAssigned < tour.totalSeatsRequested) {
    final remaining = tour.totalSeatsRequested - tour.totalSeatsAssigned;
    return _NextAction(
      kind: _NextActionKind.assignSeats,
      title: remaining == 1
          ? tr('tour_detail.action_assign_title_one')
          : tr('tour_detail.action_assign_title_other',
              namedArgs: {'n': '$remaining'}),
      subtitle: tr('tour_detail.action_assign_subtitle', namedArgs: {
        'assigned': '${tour.totalSeatsAssigned}',
        'requested': '${tour.totalSeatsRequested}',
      }),
      ctaLabel: tr('seats.title'),
      icon: Icons.event_seat_rounded,
      tone: UgamStatusTone.accent,
    );
  }
  if (tour.allSeatsAssigned && tour.handlerId == null) {
    return _NextAction(
      kind: _NextActionKind.pickHandler,
      title: tr('tour_detail.action_pick_handler_title'),
      subtitle: tr('tour_detail.action_pick_handler_subtitle'),
      ctaLabel: tr('tour_detail.pick_handler'),
      icon: Icons.person_pin_rounded,
      tone: UgamStatusTone.good,
    );
  }
  if (tour.allSeatsAssigned &&
      tour.handlerId != null &&
      tour.status != TourStatus.locked &&
      tour.status != TourStatus.completed) {
    return _NextAction(
      kind: _NextActionKind.lockAndNotify,
      title: tr('tour_detail.action_lock_title'),
      subtitle: tr('tour_detail.action_lock_subtitle'),
      ctaLabel: tr('tour_detail.action_lock_cta'),
      icon: Icons.lock_rounded,
      tone: UgamStatusTone.good,
    );
  }
  if (tour.status == TourStatus.locked &&
      tour.passengers.any(
        (p) => p.tripType == TripType.outboundOnly && !p.journeyDone,
      )) {
    return _NextAction(
      kind: _NextActionKind.completeGoLeg,
      title: tr('tour_detail.action_complete_go_title'),
      subtitle: tr('tour_detail.action_complete_go_subtitle'),
      ctaLabel: tr('tour_detail.complete_go_cta'),
      icon: Icons.logout_rounded,
      tone: UgamStatusTone.good,
    );
  }
  if (tour.status == TourStatus.locked) {
    return _NextAction(
      kind: _NextActionKind.markCompleted,
      title: tr('tour_detail.action_complete_title'),
      subtitle: tr('tour_detail.action_complete_subtitle'),
      ctaLabel: tr('tour_detail.mark_completed'),
      icon: Icons.check_circle_rounded,
      tone: UgamStatusTone.good,
    );
  }
  return _NextAction(
    kind: _NextActionKind.allSet,
    title: tour.status == TourStatus.completed
        ? tr('tour_detail.action_done_title_completed')
        : tr('tour_detail.action_done_title_ready'),
    subtitle: tour.status == TourStatus.completed
        ? tr('tour_detail.action_done_subtitle_completed')
        : tr('tour_detail.action_done_subtitle_ready'),
    ctaLabel: tr('tour_detail.view_timeline'),
    icon: Icons.check_circle_rounded,
    tone: UgamStatusTone.good,
  );
}

UgamStatusTone _toneFor(TourStatus s) => switch (s) {
      TourStatus.planning => UgamStatusTone.accent,
      TourStatus.collecting => UgamStatusTone.warm,
      TourStatus.busBooked => UgamStatusTone.accent,
      TourStatus.assigning => UgamStatusTone.accent,
      TourStatus.locked => UgamStatusTone.good,
      TourStatus.completed => UgamStatusTone.neutral,
    };

Color _toneColor(UgamStatusTone t, UgamColorSet c) => switch (t) {
      UgamStatusTone.accent => c.accent,
      UgamStatusTone.good => c.good,
      UgamStatusTone.warm => c.warm,
      UgamStatusTone.neutral => c.ink2,
    };

Color _toneFill(UgamStatusTone t, UgamColorSet c) => switch (t) {
      UgamStatusTone.accent => c.accentFill,
      UgamStatusTone.good => c.goodFill,
      UgamStatusTone.warm => c.warmFill,
      UgamStatusTone.neutral => c.cardElev,
    };
