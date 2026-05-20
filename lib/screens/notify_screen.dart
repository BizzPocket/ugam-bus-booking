import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';

/// Notify tab — lock gate + post-lock notification tracker.
///
/// Two distinct modes, switched by `tour.status`:
///   * NOT LOCKED → lock gate (checklist + sticky "Lock tour" CTA)
///   * LOCKED → tracker (hero summary card, progress bar, filter pills,
///     collapsible search, flat passenger list, bulk send CTA)
class NotifyScreen extends StatefulWidget {
  const NotifyScreen({super.key});

  @override
  State<NotifyScreen> createState() => _NotifyScreenState();
}

enum _NotifyFilter { all, pending, notified }

class _NotifyScreenState extends State<NotifyScreen> {
  /// Passenger ids already sent in this session. Reset on app restart.
  final Set<String> _sentIds = <String>{};

  final TextEditingController _searchCtrl = TextEditingController();
  bool _searchVisible = false;
  String _query = '';

  String? _selectedTourId;
  _NotifyFilter _filter = _NotifyFilter.all;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    HapticFeedback.selectionClick();
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchCtrl.clear();
        _query = '';
      }
    });
  }

  void _onSent(String id) => setState(() => _sentIds.add(id));
  void _resetSent() => setState(_sentIds.clear);

  Future<void> _sendOne(
    Passenger p, {
    required Tour tour,
    required String busNo,
    required String driverName,
    required String? driverPhone,
  }) async {
    final ok = await WhatsAppService().sendToPassenger(
      passenger: p,
      tour: tour,
      busNumber: busNo,
      driverName: driverName,
      driverPhone: driverPhone,
      handlerPhone: tour.handler?.phone,
    );
    if (!mounted) return;
    if (ok) {
      _onSent(p.id);
      AppSnackBar.success(
        tr('notify.send_now_help'),
        title: tr('notify.send_now_opened_title',
            namedArgs: {'name': p.displayName}),
      );
    } else {
      AppSnackBar.error(tr('notify.whatsapp_unavailable'));
    }
  }

  Future<void> _sendAllPending({
    required Tour tour,
    required List<Passenger> assigned,
    required String busNo,
    required String driverName,
    required String? driverPhone,
  }) async {
    final pending =
        assigned.where((p) => !_sentIds.contains(p.id)).toList();
    if (pending.isEmpty) return;
    HapticFeedback.lightImpact();
    for (final p in pending) {
      await _sendOne(
        p,
        tour: tour,
        busNo: busNo,
        driverName: driverName,
        driverPhone: driverPhone,
      );
      if (!mounted) return;
    }
  }

  // ── Build ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tourCtrl = Get.find<TourController>();

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final activeTours = tourCtrl.tours
              .where((t) => t.status != TourStatus.completed)
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          final selected = _selectedTourId != null
              ? activeTours.firstWhereOrNull((t) => t.id == _selectedTourId)
              : null;
          final Tour? tour = selected ??
              (activeTours.isEmpty ? null : activeTours.first);

          if (tour == null) {
            return Column(
              children: [
                _TopBar(
                  c: c,
                  searchActive: false,
                  onToggleSearch: () {},
                  showSearch: false,
                  onReset: null,
                  showReset: false,
                ),
                Expanded(
                  child: UgamEmpty(
                    icon: Icons.notifications_off_rounded,
                    title: tr('notify.no_active_tours_title'),
                    body: tr('notify.no_active_tours_body'),
                  ),
                ),
              ],
            );
          }

          final isLocked = tour.status == TourStatus.locked;
          final assigned = tour.passengers
              .where((p) => p.assignedSeats.isNotEmpty)
              .toList();
          final sentCount =
              assigned.where((p) => _sentIds.contains(p.id)).length;
          final pendingCount = assigned.length - sentCount;

          final busInfo = _resolveBusInfo(tour);

          return Stack(
            children: [
              Column(
                children: [
                  _TopBar(
                    c: c,
                    searchActive: _searchVisible,
                    onToggleSearch: _toggleSearch,
                    showSearch: isLocked,
                    onReset: _resetSent,
                    showReset: isLocked && _sentIds.isNotEmpty,
                  ),
                  if (isLocked)
                    AnimatedSize(
                      duration: UgamMotion.tab,
                      curve: UgamMotion.easeOut,
                      child: _searchVisible
                          ? _SearchField(
                              c: c,
                              controller: _searchCtrl,
                              onChanged: (v) =>
                                  setState(() => _query = v.trim()),
                            )
                          : const SizedBox.shrink(),
                    ),
                  if (activeTours.length > 1)
                    _TourSelector(
                      c: c,
                      tours: activeTours,
                      selectedId: tour.id,
                      onSelect: (id) => setState(() {
                        _selectedTourId = id;
                        _sentIds.clear();
                        _filter = _NotifyFilter.all;
                      }),
                    ),
                  const SizedBox(height: UgamSpacing.md),
                  Expanded(
                    child: isLocked
                        ? _buildTracker(
                            tour: tour,
                            assigned: assigned,
                            sentCount: sentCount,
                            pendingCount: pendingCount,
                            busInfo: busInfo,
                            c: c,
                          )
                        : _buildLockGate(tour: tour, c: c),
                  ),
                ],
              ),
              if (isLocked && pendingCount > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: UgamStickyCTA(
                    child: UgamCTA(
                      label: 'Send to all pending',
                      leadingIcon: Icons.chat_rounded,
                      trailingValue: '$pendingCount',
                      onPressed: () => _sendAllPending(
                        tour: tour,
                        assigned: assigned,
                        busNo: busInfo.busNo,
                        driverName: busInfo.driverName,
                        driverPhone: busInfo.driverPhone,
                      ),
                    ),
                  ),
                ),
              if (!isLocked)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _LockStickyCTA(tour: tour, c: c, onLock: _lockTour),
                ),
            ],
          );
        }),
      ),
    );
  }

  // ── Tracker (post-lock) ────────────────────────────────────────
  Widget _buildTracker({
    required Tour tour,
    required List<Passenger> assigned,
    required int sentCount,
    required int pendingCount,
    required _BusInfo busInfo,
    required UgamColorSet c,
  }) {
    if (assigned.isEmpty) {
      return UgamEmpty(
        icon: Icons.event_seat_outlined,
        title: tr('notify.empty_no_seats'),
        body: tr('notify.assign_first'),
      );
    }

    final q = _query.toLowerCase();
    final baseByFilter = switch (_filter) {
      _NotifyFilter.all => assigned,
      _NotifyFilter.pending =>
        assigned.where((p) => !_sentIds.contains(p.id)).toList(),
      _NotifyFilter.notified =>
        assigned.where((p) => _sentIds.contains(p.id)).toList(),
    };
    final filtered = q.isEmpty
        ? baseByFilter
        : baseByFilter
            .where((p) =>
                p.displayName.toLowerCase().contains(q) ||
                p.phone.toLowerCase().contains(q))
            .toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        pendingCount > 0 ? 140 : 24,
      ),
      children: [
        _HeroSummaryCard(tour: tour, busInfo: busInfo, c: c),
        const SizedBox(height: UgamSpacing.md),
        _ProgressCard(
          c: c,
          sent: sentCount,
          total: assigned.length,
        ),
        const SizedBox(height: UgamSpacing.md),
        UgamTabPills(
          currentIndex: _filter.index,
          onChanged: (i) =>
              setState(() => _filter = _NotifyFilter.values[i]),
          items: [
            UgamTabItem(label: 'All', count: assigned.length),
            UgamTabItem(label: 'Pending', count: pendingCount),
            UgamTabItem(label: 'Notified', count: sentCount),
          ],
        ),
        const SizedBox(height: UgamSpacing.md),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xxl),
            child: Center(
              child: Text(
                _query.isNotEmpty
                    ? tr('notify.no_matches', namedArgs: {'query': _query})
                    : 'Nothing here',
                style: UgamText.body.copyWith(color: c.ink2),
              ),
            ),
          )
        else
          for (var i = 0; i < filtered.length; i++) ...[
            _NotifyRow(
              passenger: filtered[i],
              busInfo: busInfo,
              isSent: _sentIds.contains(filtered[i].id),
              c: c,
              onSend: () => _sendOne(
                filtered[i],
                tour: tour,
                busNo: busInfo.busNo,
                driverName: busInfo.driverName,
                driverPhone: busInfo.driverPhone,
              ),
            ),
            if (i != filtered.length - 1)
              const SizedBox(height: UgamSpacing.sm + 2),
          ],
      ],
    );
  }

  // ── Lock gate (pre-lock) ───────────────────────────────────────
  Widget _buildLockGate({required Tour tour, required UgamColorSet c}) {
    final allAssigned = tour.allSeatsAssigned;
    final hasHandler = tour.handlerId != null;
    final hasPassengers = tour.passengers.isNotEmpty;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        160,
      ),
      children: [
        _HeroSummaryCard(
          tour: tour,
          busInfo: _resolveBusInfo(tour),
          c: c,
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamCard.plain(
          padding: const EdgeInsets.fromLTRB(
            UgamSpacing.lg,
            UgamSpacing.lg,
            UgamSpacing.lg,
            UgamSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.lock_outline_rounded,
                        size: 19, color: c.accent),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Ready to lock?',
                          style: UgamText.titleM
                              .copyWith(color: c.ink, fontSize: 17),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('notify.lock_gate_body'),
                          style: UgamText.caption
                              .copyWith(color: c.ink2, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UgamSpacing.lg),
              _Check(
                done: hasPassengers,
                label: tr('notify.check_has_passengers'),
                c: c,
              ),
              const SizedBox(height: UgamSpacing.sm),
              _Check(
                done: allAssigned,
                label: tr('notify.check_all_assigned'),
                c: c,
              ),
              const SizedBox(height: UgamSpacing.sm),
              _Check(
                done: hasHandler,
                label: tr('notify.check_has_handler'),
                c: c,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _lockTour(Tour tour) async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: Text(tr('notify.lock_dialog_title')),
        content: Text(
          tr(
            'notify.lock_dialog_body',
            namedArgs: {'count': tour.passengers.length.toString()},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: Text(tr('app.action.cancel')),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: Text(tr('notify.lock_dialog_lock')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await Get.find<TourController>().lockTour(tour.id);
    if (!mounted) return;
    AppSnackBar.success(
      tr('notify.locked_snack_body'),
      title: tr('notify.locked_snack_title'),
    );
  }

  _BusInfo _resolveBusInfo(Tour tour) {
    if (tour.buses.isEmpty) {
      return _BusInfo(
        busNo: tr('notify.not_assigned'),
        driverName: tr('notify.not_assigned'),
        driverPhone: null,
      );
    }
    return _BusInfo(
      busNo: tour.buses.map((b) => b.busNumber).join(', '),
      driverName: tour.buses.map((b) => b.driverName).join(', '),
      driverPhone: tour.buses.first.driverPhone,
    );
  }
}

class _BusInfo {
  final String busNo;
  final String driverName;
  final String? driverPhone;
  _BusInfo({
    required this.busNo,
    required this.driverName,
    required this.driverPhone,
  });
}

// ─── Top bar ──────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final bool searchActive;
  final VoidCallback onToggleSearch;
  final bool showSearch;
  final VoidCallback? onReset;
  final bool showReset;

  const _TopBar({
    required this.c,
    required this.searchActive,
    required this.onToggleSearch,
    required this.showSearch,
    required this.onReset,
    required this.showReset,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Notify',
              style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 28),
            ),
          ),
          if (showReset)
            _CircleBtn(
              icon: Icons.refresh_rounded,
              c: c,
              onTap: onReset!,
            ),
          if (showReset && showSearch) const SizedBox(width: UgamSpacing.sm),
          if (showSearch)
            _CircleBtn(
              icon: searchActive
                  ? Icons.close_rounded
                  : Icons.search_rounded,
              c: c,
              onTap: onToggleSearch,
              active: searchActive,
            ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final UgamColorSet c;
  final VoidCallback onTap;
  final bool active;
  const _CircleBtn({
    required this.icon,
    required this.c,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: active ? c.accentFill : c.cardElev,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 19, color: active ? c.accent : c.ink),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final UgamColorSet c;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({
    required this.c,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 18, color: c.ink2),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                onChanged: onChanged,
                style: UgamText.body.copyWith(color: c.ink, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: tr('notify.search_hint'),
                  hintStyle:
                      UgamText.body.copyWith(color: c.ink3, fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Tour selector ────────────────────────────────────────────────────

class _TourSelector extends StatelessWidget {
  final UgamColorSet c;
  final List<Tour> tours;
  final String selectedId;
  final ValueChanged<String> onSelect;

  const _TourSelector({
    required this.c,
    required this.tours,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
        itemCount: tours.length,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
        itemBuilder: (_, i) {
          final t = tours[i];
          final isActive = t.id == selectedId;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onSelect(t.id);
            },
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: isActive ? c.accent : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              alignment: Alignment.center,
              child: Text(
                t.title,
                style: UgamText.bodyStrong.copyWith(
                  color: isActive ? c.onAccent : c.ink2,
                  fontSize: 12.5,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Hero summary card ────────────────────────────────────────────────

class _HeroSummaryCard extends StatelessWidget {
  final Tour tour;
  final _BusInfo busInfo;
  final UgamColorSet c;

  const _HeroSummaryCard({
    required this.tour,
    required this.busInfo,
    required this.c,
  });

  String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String s = '${d.day} ${months[d.month - 1]}';
    return s;
  }

  String _formatTime(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final isLocked = tour.status == TourStatus.locked;
    final handler = tour.handler;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tour.title,
                  style: UgamText.titleL.copyWith(color: c.ink, fontSize: 19),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              UgamStatusDot(
                label: isLocked ? 'LOCKED' : tour.status.displayName,
                tone: isLocked
                    ? UgamStatusTone.good
                    : UgamStatusTone.accent,
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            '${tour.fromCity} → ${tour.toCity}',
            style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.event_rounded,
                  label: 'Departure',
                  value:
                      '${_formatDate(tour.departureDate)} · ${_formatTime(tour.departureDate)}',
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.directions_bus_rounded,
                  label: 'Bus',
                  value: busInfo.busNo,
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.badge_outlined,
                  label: 'Driver',
                  value: busInfo.driverName,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.person_pin_rounded,
                  label: 'Handler',
                  value: handler?.displayName ?? tr('notify.not_assigned'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoCell extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final String value;

  const _InfoCell({
    required this.c,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: c.ink3),
              const SizedBox(width: 4),
              Text(
                label.toUpperCase(),
                style: UgamText.micro.copyWith(color: c.ink3, fontSize: 9.5),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── Progress card ────────────────────────────────────────────────────

class _ProgressCard extends StatelessWidget {
  final UgamColorSet c;
  final int sent;
  final int total;

  const _ProgressCard({
    required this.c,
    required this.sent,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0.0 : (sent / total).clamp(0.0, 1.0);
    final done = sent >= total && total > 0;
    final color = done ? c.good : c.accent;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                done ? 'ALL NOTIFIED' : 'NOTIFICATION PROGRESS',
                style: UgamText.micro.copyWith(color: color, fontSize: 10),
              ),
              const Spacer(),
              Text(
                '$sent / $total',
                style: UgamText.tabular(
                  UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm + 2),
          Text(
            done
                ? 'Every passenger has been notified.'
                : '$sent of $total passengers notified',
            style: UgamText.titleM.copyWith(color: c.ink, fontSize: 18),
          ),
          const SizedBox(height: UgamSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 8,
              backgroundColor: c.cardElev,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Notify passenger row ─────────────────────────────────────────────

class _NotifyRow extends StatelessWidget {
  final Passenger passenger;
  final _BusInfo busInfo;
  final bool isSent;
  final UgamColorSet c;
  final VoidCallback onSend;

  const _NotifyRow({
    required this.passenger,
    required this.busInfo,
    required this.isSent,
    required this.c,
    required this.onSend,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    final seats = passenger.assignedSeats.map((a) => a.seatId).join(', ');
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      radius: UgamRadius.row,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initials(passenger.name),
              style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12),
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
                        passenger.displayName,
                        style: UgamText.bodyStrong
                            .copyWith(color: c.ink, fontSize: 13.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    UgamStatusDot(
                      label: isSent ? 'SENT' : 'PENDING',
                      tone: isSent
                          ? UgamStatusTone.good
                          : UgamStatusTone.warm,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.event_seat_rounded,
                        size: 11, color: c.ink3),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        seats.isEmpty ? '—' : 'Seat $seats',
                        style: UgamText.tabular(
                          UgamText.caption
                              .copyWith(color: c.ink2, fontSize: 11.5),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          GestureDetector(
            onTap: onSend,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: isSent ? c.goodFill : c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.chat_rounded,
                size: 17,
                color: isSent ? c.good : c.onAccent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Sticky CTAs ──────────────────────────────────────────────────────

class _LockStickyCTA extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final Future<void> Function(Tour) onLock;
  const _LockStickyCTA({
    required this.tour,
    required this.c,
    required this.onLock,
  });

  @override
  Widget build(BuildContext context) {
    final allAssigned = tour.allSeatsAssigned;
    final hasHandler = tour.handlerId != null;
    final hasPassengers = tour.passengers.isNotEmpty;
    final canLock = allAssigned && hasHandler && hasPassengers;

    String? reason;
    if (!hasPassengers) {
      reason = 'Add at least one passenger first';
    } else if (!allAssigned) {
      reason = 'Some seats are still unassigned';
    } else if (!hasHandler) {
      reason = 'Pick a handler before locking';
    }

    return UgamStickyCTA(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!canLock && reason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: Text(
                reason,
                style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
              ),
            ),
          UgamCTA(
            label: canLock
                ? tr('notify.lock_btn')
                : tr('notify.lock_btn_disabled'),
            leadingIcon: Icons.lock_rounded,
            onPressed: canLock ? () => onLock(tour) : null,
          ),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  final bool done;
  final String label;
  final UgamColorSet c;

  const _Check({
    required this.done,
    required this.label,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: done ? c.goodFill : c.cardElev,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            done ? Icons.check_rounded : Icons.circle_outlined,
            size: 14,
            color: done ? c.good : c.ink3,
          ),
        ),
        const SizedBox(width: UgamSpacing.md - 2),
        Expanded(
          child: Text(
            label,
            style: UgamText.body.copyWith(
              color: done ? c.ink : c.ink2,
              fontSize: 13.5,
            ),
          ),
        ),
      ],
    );
  }
}
