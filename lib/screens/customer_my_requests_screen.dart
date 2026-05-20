import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/customer_requests_store.dart';
import '../widgets/customer_seat_layout_sheet.dart';
import 'customer_booking_request_screen.dart';

/// Customer-facing list of every booking request submitted from this
/// device. Pull-to-refresh fans out one RPC per row to fetch live
/// status + seat assignment. Rows in the `pending` state with no seats
/// expose an Edit affordance; everything else is read-only.
class CustomerMyRequestsScreen extends StatefulWidget {
  const CustomerMyRequestsScreen({super.key});

  @override
  State<CustomerMyRequestsScreen> createState() =>
      _CustomerMyRequestsScreenState();
}

class _CustomerMyRequestsScreenState extends State<CustomerMyRequestsScreen> {
  final _store = CustomerRequestsStore();
  bool _loading = true;
  bool _refreshing = false;
  List<CustomerRequestEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final cached = await _store.list();
    if (!mounted) return;
    setState(() {
      _entries = cached;
      _loading = false;
    });
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final fresh = await _store.refreshAll();
      if (!mounted) return;
      setState(() => _entries = fresh);
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
    await Get.to<void>(() => CustomerBookingRequestScreen(
          tour: tour!,
          existing: entry,
        ));
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

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(
              c: c,
              refreshing: _refreshing,
              onRefresh: _refreshing ? null : _refresh,
            ),
            Expanded(
              child: _loading
                  ? _LoadingShimmer()
                  : _entries.isEmpty
                      ? UgamEmpty(
                          icon: Icons.inbox_outlined,
                          title: tr('customer_my_requests.empty_title'),
                          body: tr('customer_my_requests.empty_body'),
                        )
                      : RefreshIndicator(
                          color: c.accent,
                          onRefresh: _refresh,
                          child: ListView.separated(
                            padding: const EdgeInsets.fromLTRB(
                              UgamSpacing.gutter,
                              UgamSpacing.sm,
                              UgamSpacing.gutter,
                              UgamSpacing.xxl,
                            ),
                            itemCount: _entries.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: UgamSpacing.md),
                            itemBuilder: (_, i) => _RequestCard(
                              entry: _entries[i],
                              onEdit: () => _openEdit(_entries[i]),
                            ),
                          ),
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final bool refreshing;
  final VoidCallback? onRefresh;
  const _TopBar({
    required this.c,
    required this.refreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.md,
        UgamSpacing.sm,
        UgamSpacing.md,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 18, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              tr('customer_my_requests.title'),
              style: UgamText.titleL.copyWith(color: c.ink),
            ),
          ),
          GestureDetector(
            onTap: onRefresh,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: refreshing
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.ink2,
                      ),
                    )
                  : Icon(Icons.refresh_rounded, size: 18, color: c.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final CustomerRequestEntry entry;
  final VoidCallback onEdit;

  const _RequestCard({required this.entry, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamCard.plain(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _StatusChip(status: entry.status, hasSeats: entry.hasSeatsAssigned),
              const SizedBox(width: UgamSpacing.sm),
              if (entry.wasEdited)
                const UgamReqChip(
                  label: 'EDITED',
                  variant: UgamChipVariant.neutral,
                ),
              const Spacer(),
              Text(
                _formatDate(entry.tourDepartureDate),
                style: UgamText.tabular(
                  UgamText.micro.copyWith(color: c.ink3),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Text(
            entry.tourTitle,
            style: UgamText.titleM.copyWith(color: c.ink, fontSize: 16),
          ),
          const SizedBox(height: 2),
          Text(
            '${entry.tourFromCity} → ${entry.tourToCity}',
            style: UgamText.caption.copyWith(color: c.ink2, fontSize: 13),
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              Icon(Icons.event_seat_rounded, size: 16, color: c.ink2),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _seatsLabel(entry),
                  style: UgamText.body
                      .copyWith(color: c.ink, fontSize: 13),
                ),
              ),
            ],
          ),
          if (entry.tripType.isOneWay) ...[
            const SizedBox(height: UgamSpacing.sm),
            Row(
              children: [
                Icon(
                  entry.tripType == TripType.outboundOnly
                      ? Icons.arrow_forward_rounded
                      : Icons.arrow_back_rounded,
                  size: 16,
                  color: c.warm,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.tripType == TripType.outboundOnly
                        ? tr('customer_my_requests.trip_outbound', namedArgs: {
                            'from': entry.tourFromCity,
                            'to': entry.tourToCity,
                          })
                        : tr('customer_my_requests.trip_return', namedArgs: {
                            'from': entry.tourToCity,
                            'to': entry.tourFromCity,
                          }),
                    style: UgamText.bodyStrong.copyWith(
                      color: c.warm,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (entry.hasSeatsAssigned) ...[
            const SizedBox(height: UgamSpacing.md),
            GestureDetector(
              onTap: () => showCustomerSeatLayoutSheet(context, entry: entry),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md,
                  vertical: UgamSpacing.sm + 2,
                ),
                decoration: BoxDecoration(
                  color: c.accentFill,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                child: Row(
                  children: [
                    Icon(Icons.confirmation_number_rounded,
                        size: 16, color: c.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr('customer_my_requests.seats_assigned_label',
                            namedArgs: {
                              'seats': entry.assignedSeats
                                  .map((s) => s.seatId)
                                  .join(', '),
                            }),
                        style: UgamText.bodyStrong
                            .copyWith(color: c.accent, fontSize: 13),
                      ),
                    ),
                    Icon(Icons.grid_view_rounded, size: 14, color: c.accent),
                  ],
                ),
              ),
            ),
          ],
          if (entry.note != null && entry.note!.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.sm),
            Text(
              '📝 ${entry.note}',
              style: UgamText.caption
                  .copyWith(color: c.ink2, fontSize: 12, height: 1.4),
            ),
          ],
          const SizedBox(height: UgamSpacing.md),
          if (entry.canEdit)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_rounded, size: 16),
                label: Text(tr('customer_my_requests.edit_request_btn')),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.sm + 2,
              ),
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline_rounded, size: 14, color: c.ink3),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      entry.hasSeatsAssigned
                          ? tr('customer_my_requests.locked_seats_assigned')
                          : tr('customer_my_requests.locked_no_edit'),
                      style: UgamText.caption.copyWith(color: c.ink3),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _seatsLabel(CustomerRequestEntry e) {
    final parts = <String>[];
    if (e.doubleSofa > 0) {
      parts.add(tr('customer_my_requests.seats_double',
          namedArgs: {'count': e.doubleSofa.toString()}));
    }
    if (e.singleSofa > 0) {
      parts.add(tr('customer_my_requests.seats_single',
          namedArgs: {'count': e.singleSofa.toString()}));
    }
    if (parts.isEmpty) {
      return tr('customer_my_requests.seats_fallback',
          namedArgs: {'count': e.partySize.toString()});
    }
    final total = tr('customer_my_requests.seats_total',
        namedArgs: {'total': e.partySize.toString()});
    return '${parts.join(' + ')}  ·  $total';
  }

  static String _formatDate(DateTime d) {
    const months = [
      'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
      'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}';
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  final bool hasSeats;
  const _StatusChip({required this.status, required this.hasSeats});

  @override
  Widget build(BuildContext context) {
    final (label, variant) = _palette();
    return UgamReqChip(label: label, variant: variant);
  }

  (String, UgamChipVariant) _palette() {
    if (hasSeats) {
      return (
        tr('customer_my_requests.status_seats_assigned').toUpperCase(),
        UgamChipVariant.good,
      );
    }
    switch (status) {
      case 'accepted':
        return (
          tr('customer_my_requests.status_accepted').toUpperCase(),
          UgamChipVariant.good,
        );
      case 'rejected':
        return (
          tr('customer_my_requests.status_rejected').toUpperCase(),
          UgamChipVariant.warm,
        );
      case 'pending':
      default:
        return (
          tr('customer_my_requests.status_pending').toUpperCase(),
          UgamChipVariant.warm,
        );
    }
  }
}

class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 180, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 180, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 180, radius: UgamRadius.card),
      ],
    );
  }
}
