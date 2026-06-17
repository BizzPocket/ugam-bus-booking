import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/customer_requests_store.dart';
import '../utils/app_snackbar.dart';
import '../widgets/customer_seat_layout_sheet.dart';
import 'customer_booking_request_screen.dart';
import 'handler_bus_chart_screen.dart';

/// Customer-facing list of every booking request submitted from this
/// device — image-5 fidelity.
///
/// Layout:
///   [Title row + circle refresh]
///   [Status pills row (All / Pending / Confirmed / Cancelled)]
///   [Photo-anchored request rows]
///
/// Tap a row → opens the seat-layout sheet when seats are assigned,
/// otherwise routes to edit when editable. The data layer is preserved:
/// `CustomerRequestsStore` bootstraps from cache and refreshes per-row
/// via RPC.
class CustomerMyRequestsScreen extends StatefulWidget {
  const CustomerMyRequestsScreen({super.key});

  @override
  State<CustomerMyRequestsScreen> createState() =>
      _CustomerMyRequestsScreenState();
}

enum _StatusFilter { all, pending, confirmed, cancelled }

class _CustomerMyRequestsScreenState extends State<CustomerMyRequestsScreen> {
  final _store = CustomerRequestsStore();
  bool _loading = true;
  bool _refreshing = false;
  List<CustomerRequestEntry> _entries = const [];
  _StatusFilter _filter = _StatusFilter.all;

  /// Cached handler status per request id. Populated once per entry set so the
  /// `isRequestHandler` RPC is not re-fired on every rebuild.
  final Map<String, bool> _handlerStatus = {};

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Resolves handler status for any entries we haven't checked yet and caches
  /// the result. Safe to call repeatedly — already-resolved ids are skipped.
  Future<void> _resolveHandlers(List<CustomerRequestEntry> entries) async {
    final pending = entries
        .where((e) => !_handlerStatus.containsKey(e.id))
        .toList();
    if (pending.isEmpty) return;
    for (final e in pending) {
      try {
        final isHandler = await _store.isRequestHandler(e.id);
        if (!mounted) return;
        _handlerStatus[e.id] = isHandler;
      } catch (_) {
        if (!mounted) return;
        _handlerStatus[e.id] = false;
      }
    }
    if (mounted) setState(() {});
  }

  // ─── DATA LAYER — PRESERVED ────────────────────────────────────────

  Future<void> _bootstrap() async {
    final cached = await _store.list();
    if (!mounted) return;
    setState(() {
      _entries = cached;
      _loading = false;
    });
    _resolveHandlers(cached);
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final fresh = await _store.refreshAll();
      if (!mounted) return;
      setState(() => _entries = fresh);
      _resolveHandlers(fresh);
    } catch (_) {
      // Cached list is still usable.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _openEdit(CustomerRequestEntry entry) async {
    Tour? tour;
    if (Get.isRegistered<TourController>()) {
      tour = Get.find<TourController>().getTour(entry.tourId);
    }
    tour ??= _tourFromEntry(entry);
    await Get.to<void>(
      () => CustomerBookingRequestScreen(tour: tour!, existing: entry),
    );
    _refresh();
  }

  Tour _tourFromEntry(CustomerRequestEntry e) => Tour(
    id: e.tourId,
    title: e.tourTitle,
    fromCity: e.tourFromCity,
    toCity: e.tourToCity,
    departureDate: e.tourDepartureDate,
    pricePerSeat: e.tourPricePerSeat,
  );

  // ─── UI ────────────────────────────────────────────────────────────

  /// Active tickets only — trips whose date has passed (completed/past) are
  /// hidden; they're history, not live bookings. Tickets for tours the
  /// organiser deleted are flagged `rejected` on refresh, so they surface
  /// under the "Cancelled" tab rather than as live tickets.
  List<CustomerRequestEntry> get _live =>
      _entries.where((e) => !e.isPast).toList();

  List<CustomerRequestEntry> get _visible {
    final live = _live;
    switch (_filter) {
      case _StatusFilter.pending:
        return live
            .where((e) => e.status == 'pending' && !e.hasSeatsAssigned)
            .toList();
      case _StatusFilter.confirmed:
        return live
            .where((e) => e.hasSeatsAssigned || e.status == 'accepted')
            .toList();
      case _StatusFilter.cancelled:
        return live.where((e) => e.status == 'rejected').toList();
      case _StatusFilter.all:
        return live;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final live = _live;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              showBack: true,
              title: tr('customer_my_requests.title'),
              actions: [
                _RefreshAction(
                  c: c,
                  refreshing: _refreshing,
                  onRefresh: _refreshing ? null : _refresh,
                ),
              ],
            ),
            if (!_loading && live.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  0,
                  UgamSpacing.gutter,
                  UgamSpacing.md,
                ),
                child: UgamTabPills(
                  currentIndex: _filter.index,
                  onChanged: (i) =>
                      setState(() => _filter = _StatusFilter.values[i]),
                  items: [
                    UgamTabItem(
                      label: tr('customer_my_requests.tab_all'),
                      count: live.length,
                    ),
                    UgamTabItem(
                      label: tr('customer_my_requests.tab_pending'),
                      count: live
                          .where(
                            (e) => e.status == 'pending' && !e.hasSeatsAssigned,
                          )
                          .length,
                    ),
                    UgamTabItem(
                      label: tr('customer_my_requests.tab_confirmed'),
                      count: live
                          .where(
                            (e) => e.hasSeatsAssigned || e.status == 'accepted',
                          )
                          .length,
                    ),
                    UgamTabItem(
                      label: tr('customer_my_requests.tab_cancelled'),
                      count: live.where((e) => e.status == 'rejected').length,
                    ),
                  ],
                ),
              ),
            ],
            Expanded(
              child: _loading
                  ? _LoadingShimmer()
                  : live.isEmpty
                  ? UgamEmpty(
                      icon: Icons.inbox_outlined,
                      title: tr('customer_my_requests.empty_title'),
                      body: tr('customer_my_requests.empty_body'),
                    )
                  : _visible.isEmpty
                  ? UgamEmpty(
                      icon: Icons.filter_alt_off_rounded,
                      title: tr('customer_my_requests.empty_filter_title'),
                      body: tr('customer_my_requests.empty_filter_body'),
                    )
                  : RefreshIndicator(
                      color: c.accent,
                      onRefresh: _refresh,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.gutter,
                          UgamSpacing.sm,
                          UgamSpacing.gutter,
                          140,
                        ),
                        itemCount: _visible.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: UgamSpacing.sm + 2),
                        itemBuilder: (_, i) => _RequestRow(
                          entry: _visible[i],
                          isHandler: _handlerStatus[_visible[i].id] ?? false,
                          onTap: () => _onRowTap(_visible[i]),
                          onEdit: () => _openEdit(_visible[i]),
                          onViewChart: () => _openFullChart(_visible[i]),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _onRowTap(CustomerRequestEntry entry) {
    HapticFeedback.selectionClick();
    // Seats are only viewable once the tour is locked — until then assignments
    // are provisional, so we neither open the layout sheet nor reveal numbers.
    if (entry.seatsVisible) {
      showCustomerSeatLayoutSheet(context, entry: entry);
    } else if (entry.hasSeatsAssigned) {
      // Assigned but not yet locked: explain why seats stay hidden for now.
      AppSnackBar.info(tr('customer_my_requests.seats_pending_toast'));
    } else if (entry.canEdit) {
      _openEdit(entry);
    }
    // Otherwise: read-only, tap is a no-op (status chip + lock copy explain).
  }

  void _openFullChart(CustomerRequestEntry entry) {
    HapticFeedback.selectionClick();
    Get.to(
      () => HandlerBusChartScreen(requestId: entry.id),
      transition: Transition.cupertino,
    );
  }
}

// ─── REFRESH ACTION (UgamAppBar trailing slot) ────────────────────────

/// Trailing refresh affordance for the shared [UgamAppBar]. Matches the
/// [UgamAppBarAction] circle styling, but swaps the glyph for a spinner while
/// a refresh is in flight (so the customer sees the pull is working).
class _RefreshAction extends StatelessWidget {
  final UgamColorSet c;
  final bool refreshing;
  final VoidCallback? onRefresh;

  const _RefreshAction({
    required this.c,
    required this.refreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (!refreshing) {
      return UgamAppBarAction(
        icon: Icons.refresh_rounded,
        onTap: onRefresh ?? () {},
      );
    }
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: c.ink2),
      ),
    );
  }
}

// ─── REQUEST ROW (photo-anchored) ─────────────────────────────────────

class _RequestRow extends StatelessWidget {
  final CustomerRequestEntry entry;
  final bool isHandler;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onViewChart;

  const _RequestRow({
    required this.entry,
    required this.isHandler,
    required this.onTap,
    required this.onEdit,
    required this.onViewChart,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final (statusLabel, statusTone) = _statusFor(entry);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.sm),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                // Small backdrop + date pill.
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: 76,
                    height: 88,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        UgamBusBackdrop(
                          seed: entry.tourId,
                          label: _routeInitials(
                            entry.tourFromCity,
                            entry.tourToCity,
                          ),
                        ),
                        Positioned(
                          left: 4,
                          top: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: c.cardElev,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              _formatDate(entry.tourDepartureDate),
                              style: UgamText.tabular(
                                UgamText.micro.copyWith(
                                  color: c.ink,
                                  fontSize: 9.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: UgamSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.tourTitle,
                        style: UgamText.titleS.copyWith(
                          color: c.ink,
                          fontSize: 14.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(
                            Icons.south_east_rounded,
                            size: 12,
                            color: c.ink2,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              '${entry.tourFromCity} → ${entry.tourToCity}',
                              style: UgamText.caption.copyWith(
                                color: c.ink2,
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: UgamSpacing.sm + 2),
                      Row(
                        children: [
                          UgamStatusDot(label: statusLabel, tone: statusTone),
                          const SizedBox(width: UgamSpacing.sm),
                          Flexible(
                            child: Text(
                              _seatsLabel(entry),
                              style: UgamText.caption.copyWith(
                                color: c.ink,
                                fontSize: 11.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: c.ink3,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (entry.wasEdited ||
                entry.tripType.isOneWay ||
                entry.canEdit ||
                entry.hasSeatsAssigned) ...[
              const SizedBox(height: UgamSpacing.sm + 2),
              _RowFooter(entry: entry, c: c, onEdit: onEdit),
            ],
            if (isHandler) ...[
              const SizedBox(height: UgamSpacing.sm + 2),
              _HandlerChartButton(c: c, onTap: onViewChart),
            ],
          ],
        ),
      ),
    );
  }

  (String, UgamStatusTone) _statusFor(CustomerRequestEntry e) {
    // Reveal "Seats assigned" only once the tour is locked. While assignments
    // are still provisional, show a neutral "being finalized" state instead.
    if (e.seatsVisible) {
      return (
        tr('customer_my_requests.chip_seats_assigned'),
        UgamStatusTone.good,
      );
    }
    if (e.hasSeatsAssigned) {
      return (
        tr('customer_my_requests.chip_seats_finalizing'),
        UgamStatusTone.warm,
      );
    }
    if (e.status == 'accepted') {
      return (tr('customer_my_requests.chip_confirmed'), UgamStatusTone.good);
    }
    if (e.status == 'rejected') {
      return (tr('customer_my_requests.chip_cancelled'), UgamStatusTone.warm);
    }
    return (tr('customer_my_requests.chip_pending'), UgamStatusTone.warm);
  }

  String _seatsLabel(CustomerRequestEntry e) {
    final parts = <String>[];
    if (e.doubleSofa > 0) {
      parts.add(
        tr(
          'customer_my_requests.seats_double',
          namedArgs: {'count': e.doubleSofa.toString()},
        ),
      );
    }
    if (e.singleSofa > 0) {
      parts.add(
        tr(
          'customer_my_requests.seats_single',
          namedArgs: {'count': e.singleSofa.toString()},
        ),
      );
    }
    if (parts.isEmpty) {
      return tr(
        'customer_my_requests.seats_fallback',
        namedArgs: {'count': e.partySize.toString()},
      );
    }
    return parts.join(' + ');
  }

  static String _formatDate(DateTime d) {
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}';
  }
}

class _RowFooter extends StatelessWidget {
  final CustomerRequestEntry entry;
  final UgamColorSet c;
  final VoidCallback onEdit;

  const _RowFooter({
    required this.entry,
    required this.c,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final widgets = <Widget>[];

    if (entry.wasEdited) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_edited'),
          variant: UgamChipVariant.neutral,
        ),
      );
    }
    if (entry.tripType == TripType.outboundOnly) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_oneway_out'),
          variant: UgamChipVariant.warm,
        ),
      );
    } else if (entry.tripType == TripType.returnOnly) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_oneway_return'),
          variant: UgamChipVariant.warm,
        ),
      );
    }
    // Seat NUMBERS are revealed only after the tour locks. Before that, show a
    // neutral "being finalized" chip so the customer knows seats are coming but
    // never sees provisional numbers that may still change.
    if (entry.seatsVisible) {
      widgets.add(
        UgamReqChip(
          label: tr(
            'customer_my_requests.chip_seats',
            namedArgs: {
              'seats': entry.assignedSeats.map((s) => s.seatId).join(", "),
            },
          ),
          variant: UgamChipVariant.good,
        ),
      );
    } else if (entry.hasSeatsAssigned) {
      widgets.add(
        UgamReqChip(
          label: tr('customer_my_requests.chip_seats_finalizing'),
          variant: UgamChipVariant.neutral,
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.sm,
        UgamSpacing.sm,
        UgamSpacing.sm,
        UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(child: Wrap(spacing: 5, runSpacing: 5, children: widgets)),
          if (entry.canEdit) ...[
            const SizedBox(width: UgamSpacing.sm),
            GestureDetector(
              onTap: onEdit,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: c.accent,
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_rounded, size: 12, color: c.onAccent),
                    const SizedBox(width: 4),
                    Text(
                      tr('customer_my_requests.edit_request_btn'),
                      style: UgamText.bodyStrong.copyWith(
                        color: c.onAccent,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else if (entry.note != null && entry.note!.isNotEmpty) ...[
            const SizedBox(width: UgamSpacing.sm),
            Icon(Icons.sticky_note_2_outlined, size: 14, color: c.ink3),
          ],
        ],
      ),
    );
  }
}

/// Handler-only affordance: opens the full bus chart for this request.
/// Rendered only when `isRequestHandler` resolved true for the entry.
class _HandlerChartButton extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _HandlerChartButton({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: c.accent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(Icons.grid_view_rounded, size: 16, color: c.onAccent),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                tr('customer_my_requests.view_full_chart'),
                style: UgamText.bodyStrong.copyWith(
                  color: c.onAccent,
                  fontSize: 12.5,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.onAccent),
          ],
        ),
      ),
    );
  }
}

class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 110, radius: 20),
        SizedBox(height: UgamSpacing.sm),
        UgamSkeleton(height: 110, radius: 20),
        SizedBox(height: UgamSpacing.sm),
        UgamSkeleton(height: 110, radius: 20),
      ],
    );
  }
}

/// Route monogram (e.g. `"S→M"`) from the from/to city initials, for the
/// graphite UgamBusBackdrop tile. Matches the sibling customer screens.
String _routeInitials(String from, String to) {
  String first(String s) {
    final t = s.trim();
    return t.isEmpty ? '' : t.characters.first.toUpperCase();
  }

  final f = first(from);
  final t = first(to);
  if (f.isEmpty && t.isEmpty) return '';
  return '$f→$t';
}
