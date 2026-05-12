import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../services/whatsapp_service.dart';

class NotifyScreen extends StatefulWidget {
  const NotifyScreen({super.key});

  @override
  State<NotifyScreen> createState() => _NotifyScreenState();
}

class _NotifyScreenState extends State<NotifyScreen> {
  /// Passenger ids the agent has already sent a confirmation to in this
  /// session. Reset on app restart — kept in-memory by design.
  final Set<String> _sentIds = <String>{};

  /// Currently selected tour. Null until the agent picks one (or the list
  /// has only one active tour and we auto-select it).
  String? _selectedTourId;

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: SafeArea(
        child: Obx(() {
          // All non-completed tours, newest first.
          final activeTours = tourCtrl.tours
              .where((t) => t.status != TourStatus.completed)
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          // Auto-select the first active tour if nothing is selected, or
          // if the previously selected tour disappeared from the list.
          final selected = _selectedTourId != null
              ? activeTours.firstWhereOrNull((t) => t.id == _selectedTourId)
              : null;
          final Tour? tour = selected ??
              (activeTours.isEmpty ? null : activeTours.first);

          if (tour == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.notifications_off_rounded,
                      size: 48,
                      color: AppTheme.textMuted,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      tr('notify.no_active_tours_title'),
                      style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('notify.no_active_tours_body'),
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final tourName = tour.title;
          final String busNo;
          final String totalSeats;
          final String driverName;
          final String? driverPhone;
          
          if (tour.buses.isNotEmpty) {
            busNo = tour.buses.map((b) => b.busNumber).join(', ');
            totalSeats = tour.totalBusSeats.toString();
            driverName = tour.buses.map((b) => b.driverName).join(', ');
            driverPhone = tour.buses.first.driverPhone; // Simplified for broadcast
          } else {
            busNo = tr('notify.not_assigned');
            totalSeats = '-';
            driverName = tr('notify.not_assigned');
            driverPhone = null;
          }

          // Format date range
          final months = [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
          ];
          final depDate = tour.departureDate;
          String tourDate = '${months[depDate.month - 1]} ${depDate.day}';
          if (tour.returnDate != null) {
            final ret = tour.returnDate!;
            tourDate += '–${ret.day}';
          }

          // Passengers with assigned seats
          final assignedPassengers = tour.passengers
              .where((p) => p.assignedSeats.isNotEmpty)
              .toList();

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // -- Tour picker --
                if (activeTours.length > 1) ...[
                  Text(
                    tr('notify.section_label'),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 40,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: activeTours.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final t = activeTours[i];
                        final isActive = t.id == tour.id;
                        return GestureDetector(
                          onTap: () =>
                              setState(() {
                                _selectedTourId = t.id;
                                _sentIds.clear();
                              }),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: isActive ? AppTheme.brand : Colors.white,
                              borderRadius: BorderRadius.circular(9999),
                              border: isActive
                                  ? null
                                  : Border.all(color: AppTheme.borderLight),
                            ),
                            child: Center(
                              child: Text(
                                t.title,
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: isActive
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: isActive
                                      ? Colors.white
                                      : AppTheme.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // -- Summary Card --
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.cardLight,
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: AppTheme.cardShadow,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tourName,
                        style: GoogleFonts.inter(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          _SummaryBox(label: tr('notify.summary_date'), value: tourDate),
                          const SizedBox(width: 10),
                          _SummaryBox(label: tr('notify.summary_bus_no'), value: busNo),
                          const SizedBox(width: 10),
                          _SummaryBox(label: tr('notify.summary_seats'), value: totalSeats),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // -- Lock gate or Person-wise notifier --
                if (tour.status != TourStatus.locked)
                  _buildLockGate(tour: tour)
                else
                  _PersonWiseNotifier(
                    tour: tour,
                    busNo: busNo,
                    driverName: driverName,
                    driverPhone: driverPhone,
                    passengers: assignedPassengers,
                    sentIds: _sentIds,
                    onSent: (id) => setState(() => _sentIds.add(id)),
                    onReset: () => setState(_sentIds.clear),
                  ),

                const SizedBox(height: 20),
              ],
            ),
          );
        }),
      ),
    );
  }

  // ── Lock Gate: shown before tour is locked ────────────────
  Widget _buildLockGate({required Tour tour}) {
    final allAssigned = tour.allSeatsAssigned;
    final hasHandler = tour.handlerId != null;
    final hasPassengers = tour.passengers.isNotEmpty;
    final canLock = allAssigned && hasHandler && hasPassengers;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: AppTheme.cardShadow,
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.lock_outline_rounded,
                size: 20,
                color: AppTheme.brand,
              ),
              const SizedBox(width: 8),
              Text(
                tr('notify.lock_gate_title'),
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: AppTheme.brand,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            tr('notify.lock_gate_body'),
            style: GoogleFonts.inter(
              fontSize: 13,
              color: AppTheme.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          // Pre-flight checklist
          _Check(
            done: hasPassengers,
            label: tr('notify.check_has_passengers'),
          ),
          const SizedBox(height: 6),
          _Check(
            done: allAssigned,
            label: tr('notify.check_all_assigned'),
          ),
          const SizedBox(height: 6),
          _Check(
            done: hasHandler,
            label: tr('notify.check_has_handler'),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: canLock ? () => _lockTour(tour) : null,
              icon: const Icon(Icons.lock_rounded, size: 18),
              label: Text(
                canLock ? tr('notify.lock_btn') : tr('notify.lock_btn_disabled'),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.brand,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppTheme.bgLight,
                disabledForegroundColor: AppTheme.textMuted,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ],
      ),
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
            style: TextButton.styleFrom(foregroundColor: AppTheme.brand),
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
}

// ── Person-wise notifier: shown once the tour is locked ──────
class _PersonWiseNotifier extends StatelessWidget {
  final Tour tour;
  final String busNo;
  final String driverName;
  final String? driverPhone;
  final List<Passenger> passengers;
  final Set<String> sentIds;
  final void Function(String id) onSent;
  final VoidCallback onReset;

  const _PersonWiseNotifier({
    required this.tour,
    required this.busNo,
    required this.driverName,
    this.driverPhone,
    required this.passengers,
    required this.sentIds,
    required this.onSent,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    if (passengers.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.bgLight,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: Column(
          children: [
            Icon(Icons.info_outline_rounded, size: 22, color: AppTheme.textMuted),
            const SizedBox(height: 8),
            Text(
              tr('notify.assign_first'),
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 13, color: AppTheme.textMuted),
            ),
          ],
        ),
      );
    }

    final pending = passengers.where((p) => !sentIds.contains(p.id)).toList();
    final sentCount = passengers.length - pending.length;
    final allDone = pending.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Progress card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: AppTheme.cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    allDone
                        ? tr('notify.all_sent')
                        : tr('notify.sending_confirmations'),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1,
                      color: allDone ? AppTheme.success : AppTheme.brand,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$sentCount / ${passengers.length}',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: passengers.isEmpty
                      ? 0
                      : sentCount / passengers.length,
                  minHeight: 6,
                  backgroundColor: AppTheme.bgLight,
                  valueColor: AlwaysStoppedAnimation(
                    allDone ? AppTheme.success : AppTheme.brand,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (allDone)
                _buildAllDoneCard(context)
              else
                _buildNextUpCard(context, pending.first, pending.length),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // Passenger list with sent checkmarks
        Text(
          tr('notify.passenger_assignments'),
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
            color: AppTheme.textMuted,
          ),
        ),
        const SizedBox(height: 12),
        ...passengers.map((p) {
          final isSent = sentIds.contains(p.id);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isSent ? AppTheme.successLight : Colors.white,
                borderRadius: BorderRadius.circular(6),
                boxShadow: AppTheme.cardShadow,
              ),
              child: Row(
                children: [
                  Icon(
                    isSent
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: isSent ? AppTheme.success : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      p.displayName,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    tr(
                      'notify.seat_label',
                      namedArgs: {
                        'seats': p.assignedSeats.map((a) => a.seatId).join(', '),
                      },
                    ),
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _buildNextUpCard(BuildContext context, Passenger passenger, int remaining) {
    final seats = passenger.assignedSeats.map((a) => a.seatId).join(', ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.brandLight,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('notify.next_label'),
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: AppTheme.brand,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                passenger.displayName,
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                tr(
                  'notify.next_seat_phone',
                  namedArgs: {'seats': seats, 'phone': passenger.phone},
                ),
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: () => _sendNext(context, passenger),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF25D366),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.chat_rounded, size: 18),
                const SizedBox(width: 8),
                Text(
                  tr('notify.open_whatsapp'),
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              onPressed: () => onSent(passenger.id),
              icon: const Icon(Icons.skip_next_rounded, size: 16),
              label: Text(tr('app.action.skip')),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              tr('notify.remaining', namedArgs: {'count': remaining.toString()}),
              style: GoogleFonts.inter(fontSize: 12, color: AppTheme.textMuted),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAllDoneCard(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.successLight,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.success),
          ),
          child: Column(
            children: [
              Icon(Icons.check_circle, size: 28, color: AppTheme.success),
              const SizedBox(height: 8),
              Text(
                tr('notify.all_done_title'),
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.success,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                tr('notify.all_done_body'),
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: onReset,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: Text(tr('notify.reset_send_again')),
          style: TextButton.styleFrom(foregroundColor: AppTheme.textSecondary),
        ),
      ],
    );
  }

  Future<void> _sendNext(BuildContext context, Passenger passenger) async {
    final sent = await WhatsAppService().sendToPassenger(
      passenger: passenger,
      tour: tour,
      busNumber: busNo,
      driverName: driverName,
      driverPhone: driverPhone,
      handlerPhone: tour.handler?.phone,
    );
    if (!context.mounted) return;
    if (sent) {
      onSent(passenger.id);
      AppSnackBar.success(
        tr('notify.opened_snack_body'),
        title: tr(
          'notify.opened_snack_title',
          namedArgs: {'name': passenger.displayName},
        ),
      );
    } else {
      AppSnackBar.error(tr('notify.wa_error'));
    }
  }
}

class _Check extends StatelessWidget {
  final bool done;
  final String label;

  const _Check({required this.done, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          done ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
          size: 18,
          color: done ? AppTheme.success : AppTheme.textMuted,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: done ? AppTheme.textPrimary : AppTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _SummaryBox extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryBox({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        decoration: BoxDecoration(
          color: AppTheme.bgLight,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8,
                color: AppTheme.textMuted,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
