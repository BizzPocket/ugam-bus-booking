import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/customer_requests_store.dart';
import '../widgets/customer_seat_layout_sheet.dart';
import 'customer_booking_request_screen.dart';

/// Customer-facing list of every booking request submitted from THIS
/// device. Pull-to-refresh fans out one RPC per row to fetch live status
/// + seat assignment. Rows in the `pending` state with no seats assigned
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
    // Kick off a server refresh in the background.
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
      // Swallow — the cached list is still usable.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _openEdit(CustomerRequestEntry entry) async {
    // Resolve the live Tour from the existing TourController cache. We need
    // a Tour instance (not just the stored snapshot) so the booking form's
    // pricing/route logic stays consistent with the server.
    Tour? tour;
    if (Get.isRegistered<TourController>()) {
      tour = Get.find<TourController>().getTour(entry.tourId);
    }
    tour ??= _tourFromEntry(entry);

    await Get.to<void>(() => CustomerBookingRequestScreen(
          tour: tour!,
          existing: entry,
        ));
    // On return, refresh — the edit may have flipped customer_edited_at
    // or, in the blocked case, surfaced new server state.
    _refresh();
  }

  /// Synthesise a Tour from the local snapshot. Used when the
  /// TourController doesn't have this tour cached (e.g., it was removed
  /// from the public list after the customer submitted).
  Tour _tourFromEntry(CustomerRequestEntry e) {
    return Tour(
      id: e.tourId,
      title: e.tourTitle,
      fromCity: e.tourFromCity,
      toCity: e.tourToCity,
      departureDate: e.tourDepartureDate,
      pricePerSeat: e.tourPricePerSeat,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back(),
        ),
        title: Text(
          tr('customer_my_requests.title'),
          style: GoogleFonts.inter(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
            onPressed: _refreshing ? null : _refresh,
            tooltip: tr('customer_my_requests.refresh_tooltip'),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _entries.isEmpty
                ? _empty(theme)
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      itemCount: _entries.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 14),
                      itemBuilder: (_, i) => _RequestCard(
                        entry: _entries[i],
                        onEdit: () => _openEdit(_entries[i]),
                      ),
                    ),
                  ),
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              tr('customer_my_requests.empty_title'),
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              tr('customer_my_requests.empty_body'),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outline),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status + edited pill row
          Row(
            children: [
              _StatusBadge(status: entry.status, hasSeats: entry.hasSeatsAssigned),
              const SizedBox(width: 8),
              if (entry.wasEdited)
                _MutedPill(
                  icon: Icons.edit_rounded,
                  label: tr('customer_my_requests.edited_pill'),
                ),
              const Spacer(),
              Text(
                _formatDate(entry.tourDepartureDate),
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            entry.tourTitle,
            style: GoogleFonts.inter(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${entry.tourFromCity} → ${entry.tourToCity}',
            style: GoogleFonts.inter(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.event_seat_rounded,
                  size: 16, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                _seatsLabel(entry),
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
          if (entry.tripType.isOneWay) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(
                  entry.tripType == TripType.outboundOnly
                      ? Icons.arrow_forward_rounded
                      : Icons.arrow_back_rounded,
                  size: 16,
                  color: AppTheme.warning,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.tripType == TripType.outboundOnly
                        ? tr('customer_my_requests.trip_outbound',
                            namedArgs: {
                              'from': entry.tourFromCity,
                              'to': entry.tourToCity,
                            })
                        : tr('customer_my_requests.trip_return',
                            namedArgs: {
                              'from': entry.tourToCity,
                              'to': entry.tourFromCity,
                            }),
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.warning,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (entry.hasSeatsAssigned) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => showCustomerSeatLayoutSheet(context, entry: entry),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.confirmation_number_rounded,
                        size: 16, color: AppTheme.brand),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr(
                          'customer_my_requests.seats_assigned_label',
                          namedArgs: {
                            'seats': entry.assignedSeats
                                .map((s) => s.seatId)
                                .join(', '),
                          },
                        ),
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.brand,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.grid_view_rounded,
                        size: 14, color: AppTheme.brand),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tr('customer_my_requests.layout_view_hint'),
              style: GoogleFonts.inter(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (entry.note != null && entry.note!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '📝 ${entry.note}',
              style: GoogleFonts.inter(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (entry.canEdit)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_rounded, size: 16),
                label: Text(tr('customer_my_requests.edit_request_btn')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.brand,
                  side: const BorderSide(color: AppTheme.brand),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            )
          else
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.bg(context),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline_rounded,
                      size: 14, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      entry.hasSeatsAssigned
                          ? tr('customer_my_requests.locked_seats_assigned')
                          : tr('customer_my_requests.locked_no_edit'),
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: colorScheme.onSurfaceVariant,
                      ),
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

class _StatusBadge extends StatelessWidget {
  final String status;
  final bool hasSeats;
  const _StatusBadge({required this.status, required this.hasSeats});

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = _palette(status, hasSeats);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  (String, Color, Color) _palette(String status, bool hasSeats) {
    if (hasSeats) {
      return (
        tr('customer_my_requests.status_seats_assigned'),
        const Color(0xFF065F46),
        const Color(0xFFD1FAE5),
      );
    }
    switch (status) {
      case 'accepted':
        return (
          tr('customer_my_requests.status_accepted'),
          const Color(0xFF065F46),
          const Color(0xFFD1FAE5),
        );
      case 'rejected':
        return (
          tr('customer_my_requests.status_rejected'),
          const Color(0xFF991B1B),
          const Color(0xFFFEE2E2),
        );
      case 'pending':
      default:
        return (
          tr('customer_my_requests.status_pending'),
          const Color(0xFF92400E),
          const Color(0xFFFEF3C7),
        );
    }
  }
}

class _MutedPill extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MutedPill({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
