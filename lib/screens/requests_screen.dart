import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/passenger.dart';
import '../models/request_line.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_normalize.dart';
import '../widgets/edit_request_sheet.dart';

class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

enum _RequestFilter { newRequests, waitlist, assigned }

class _RequestsScreenState extends State<RequestsScreen> {
  final tourCtrl = Get.find<TourController>();
  int _selectedTourIndex = 0;
  _RequestFilter _filter = _RequestFilter.newRequests;

  void _openAddRequest(Tour tour) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AddRequestSheet(tour: tour),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg(context),
      // Lift the FAB above MainShell's floating pill bottom nav (~104px
       // tall with extendBody: true). Without this padding the button
       // disappears behind the nav, same fix as ToursScreen.
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 90),
        child: Obx(() {
          final tours = tourCtrl.activeTours;
          if (tours.isEmpty) return const SizedBox.shrink();
          if (_selectedTourIndex >= tours.length) {
            _selectedTourIndex = 0;
          }
          final selected = tours[_selectedTourIndex];
          return FloatingActionButton.extended(
            heroTag: 'requests_fab',
            onPressed: () => _openAddRequest(selected),
            backgroundColor: AppTheme.brand,
            foregroundColor: Colors.white,
            icon: const Icon(Icons.person_add_alt_rounded, size: 18),
            label: Text(
              tr('requests.fab_add'),
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }),
      ),
      body: SafeArea(
        // The header title is locale-only (doesn't depend on any reactive
        // state) — hoist it above the Obx so realtime tour events don't
        // repaint it. Same shape, lower rebuild cost.
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  tr('requests.title'),
                  style: AppText.pageTitle.copyWith(
                    color: AppColors.text(context),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Obx(() {
        final activeTours = tourCtrl.activeTours;
        if (activeTours.isEmpty) {
          return _Empty(
            icon: Icons.chat_bubble_outline_rounded,
            title: tr('requests.empty_no_tours.title'),
            body: tr('requests.empty_no_tours.body'),
          );
        }

        // Clamp selected index
        if (_selectedTourIndex >= activeTours.length) {
          _selectedTourIndex = 0;
        }

        final selectedTour = activeTours[_selectedTourIndex];
        final allPassengers = selectedTour.passengers;

          // "New" covers anything the admin still needs to act on — that
          // includes partially assigned passengers (e.g. customer asked
          // for 3 seats, admin only placed 1). They are NOT done, so they
          // must not drop into the "Assigned" bucket and out of sight.
          final newCount = allPassengers
              .where((p) => !p.isWaitlisted && !p.isFullyAssigned)
              .length;
          final waitlistCount =
              allPassengers.where((p) => p.isWaitlisted).length;
          final assignedCount =
              allPassengers.where((p) => p.isFullyAssigned).length;

          // Filtered list based on current chip selection.
          final passengers = switch (_filter) {
            _RequestFilter.newRequests => allPassengers
                .where((p) => !p.isWaitlisted && !p.isFullyAssigned)
                .toList(),
            _RequestFilter.waitlist =>
              allPassengers.where((p) => p.isWaitlisted).toList(),
            _RequestFilter.assigned =>
              allPassengers.where((p) => p.isFullyAssigned).toList(),
          };

          return Column(
            children: [
              // ── Tour Selector Chips ──
              SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: activeTours.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final tour = activeTours[i];
                    final isActive = i == _selectedTourIndex;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedTourIndex = i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: isActive ? AppTheme.brand : AppColors.surface(context),
                          borderRadius: BorderRadius.circular(9999),
                          border: isActive
                              ? null
                              : Border.all(color: AppColors.border(context)),
                        ),
                        child: Center(
                          child: Text(
                            tour.title,
                            style: AppText.chipText.copyWith(
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: isActive
                                  ? Colors.white
                                  : AppColors.textMuted(context),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 16),

              // ── Filter Chips (tappable stats) ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    _FilterChip(
                      value: '$newCount',
                      label: tr('requests.filter.new'),
                      color: AppTheme.info,
                      bgColor: AppTheme.infoLight,
                      isActive: _filter == _RequestFilter.newRequests,
                      onTap: () => setState(
                          () => _filter = _RequestFilter.newRequests),
                    ),
                    const SizedBox(width: 10),
                    _FilterChip(
                      value: '$waitlistCount',
                      label: tr('requests.filter.waitlist'),
                      color: const Color(0xFFB45309),
                      bgColor: const Color(0xFFFEF3C7),
                      isActive: _filter == _RequestFilter.waitlist,
                      onTap: () => setState(
                          () => _filter = _RequestFilter.waitlist),
                    ),
                    const SizedBox(width: 10),
                    _FilterChip(
                      value: '$assignedCount',
                      label: tr('requests.filter.assigned'),
                      color: AppTheme.success,
                      bgColor: AppTheme.successLight,
                      isActive: _filter == _RequestFilter.assigned,
                      onTap: () => setState(
                          () => _filter = _RequestFilter.assigned),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Request List ──
              Expanded(
                child: RefreshIndicator(
                  onRefresh: tourCtrl.refreshTours,
                  color: AppTheme.brand,
                  child: passengers.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        children: [
                          SizedBox(
                            height: MediaQuery.of(context).size.height * 0.5,
                            child: _Empty(
                        icon: switch (_filter) {
                          _RequestFilter.newRequests =>
                            Icons.people_outline_rounded,
                          _RequestFilter.waitlist =>
                            Icons.hourglass_empty_rounded,
                          _RequestFilter.assigned =>
                            Icons.check_circle_outline_rounded,
                        },
                        title: switch (_filter) {
                          _RequestFilter.newRequests => tr('requests.empty_new.title'),
                          _RequestFilter.waitlist => tr('requests.empty_waitlist.title'),
                          _RequestFilter.assigned => tr('requests.empty_assigned.title'),
                        },
                        body: switch (_filter) {
                          _RequestFilter.newRequests => tr('requests.empty_new.body'),
                          _RequestFilter.waitlist => tr('requests.empty_waitlist.body'),
                          _RequestFilter.assigned => tr('requests.empty_assigned.body'),
                        },
                            ),
                          ),
                        ],
                      )
                    : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: passengers.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 12),
                        itemBuilder: (context, i) {
                          final passenger = passengers[i];
                          // A request is only "Assigned" once every requested
                          // seat has been placed. Partial fills (1/3) stay
                          // in the New bucket and keep the "Assign seats"
                          // CTA so the admin can finish the job.
                          final isAssigned = passenger.isFullyAssigned;
                          return _RequestCard(
                            passenger: passenger,
                            tour: selectedTour,
                            isAssigned: isAssigned,
                          );
                        },
                      ),
                ),
              ),
            ],
          );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Filter Chip (tappable stat) ───────────────────────────────
class _FilterChip extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  final Color bgColor;
  final bool isActive;
  final VoidCallback onTap;

  const _FilterChip({
    required this.value,
    required this.label,
    required this.color,
    required this.bgColor,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isActive ? color : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            children: [
              Text(
                value,
                style: AppText.statValueLg.copyWith(
                  fontSize: 22,
                  color: color,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: AppText.cardLabel.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Request Card ──────────────────────────────────────────────
class _RequestCard extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final bool isAssigned;

  const _RequestCard({
    required this.passenger,
    required this.tour,
    required this.isAssigned,
  });

  Color _avatarColor(String name) {
    const colors = [
      AppTheme.brand,
      Color(0xFFD97706),
      AppTheme.success,
      Color(0xFF7C3AED),
      Color(0xFFDB2777),
      Color(0xFF0891B2),
    ];
    final hash = name.codeUnits.fold(0, (prev, c) => prev + c);
    return colors[hash % colors.length];
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) return tr('requests.time.days_ago', namedArgs: {'n': '${diff.inDays}'});
    if (diff.inHours > 0) return tr('requests.time.hours_ago', namedArgs: {'n': '${diff.inHours}'});
    if (diff.inMinutes > 0) return tr('requests.time.minutes_ago', namedArgs: {'n': '${diff.inMinutes}'});
    return tr('requests.time.just_now');
  }

  @override
  Widget build(BuildContext context) {
    final avatarBg = _avatarColor(passenger.name);
    final initials = _initials(passenger.name);
    final isWaitlisted = passenger.isWaitlisted;

    Color borderColor;
    double borderWidth;
    if (isAssigned) {
      borderColor = AppTheme.success;
      borderWidth = 1.5;
    } else if (isWaitlisted) {
      borderColor = const Color(0xFFD97706);
      borderWidth = 1.5;
    } else {
      borderColor = AppColors.border(context);
      borderWidth = 1;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: const [
          BoxShadow(
            color: Color(0x080B1120),
            offset: Offset(0, 2),
            blurRadius: 8,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: Avatar + Name + Badge ──
          Row(
            children: [
              // Avatar
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: avatarBg,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    initials,
                    style: AppText.chipText.copyWith(color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Name + time
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      passenger.displayName,
                      style: AppText.cardTitleSm.copyWith(
                        fontWeight: FontWeight.w600,
                        color: AppColors.text(context),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _timeAgo(passenger.createdAt),
                      style: AppText.cardMeta.copyWith(
                        color: AppColors.textMuted(context),
                      ),
                    ),
                  ],
                ),
              ),
              // Status badge
              _StatusBadge(
                isAssigned: isAssigned,
                isWaitlisted: isWaitlisted,
              ),
            ],
          ),

          // ── Note / WhatsApp message ──
          if (passenger.note != null && passenger.note!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.surfaceAlt(context),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.chat_bubble_outline_rounded,
                      size: 16, color: AppColors.textMuted(context)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '"${passenger.note}"',
                      style: GoogleFonts.newsreader(
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                        color: AppColors.textMuted(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ── Parsed seat info chips ──
          if (passenger.requestLines.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _SeatChip(
                  icon: Icons.event_seat_rounded,
                  // Partial state surfaces progress as "1/3 seats" so the
                  // admin can see at a glance which requests still need
                  // work. Fully-new and fully-done rows keep the compact
                  // "3 seats" label.
                  label: tr(
                    'requests.seat_chip.seats',
                    namedArgs: {
                      'count': passenger.isPartiallyAssigned
                          ? '${passenger.totalSeatsAssigned}/${passenger.totalSeatsRequested}'
                          : '${passenger.totalSeatsRequested}',
                    },
                  ),
                  color: isAssigned ? AppTheme.success : AppTheme.brand,
                  bgColor: isAssigned
                      ? AppTheme.successLight
                      : AppTheme.brandLight,
                ),
                _SeatChip(
                  label: passenger.requestLines
                      .map((l) => l.label.replaceAll(' ×', ' × '))
                      .join(' + '),
                  color: isAssigned ? AppTheme.success : AppTheme.brand,
                  bgColor: isAssigned
                      ? AppTheme.successLight
                      : AppTheme.brandLight,
                ),
                if (passenger.tripType.isOneWay)
                  _SeatChip(
                    icon: passenger.tripType == TripType.outboundOnly
                        ? Icons.arrow_forward_rounded
                        : Icons.arrow_back_rounded,
                    label: passenger.tripType == TripType.outboundOnly
                        ? tr('requests.chip.trip_outbound', namedArgs: {
                            'from': tour.fromCity,
                            'to': tour.toCity,
                          })
                        : tr('requests.chip.trip_return', namedArgs: {
                            'from': tour.toCity,
                            'to': tour.fromCity,
                          }),
                    color: AppTheme.warning,
                    bgColor: AppTheme.warningLight,
                  ),
              ],
            ),
          ],

          const SizedBox(height: 12),

          // ── Action area ──
          // Single primary CTA + overflow menu. Replaces the previous
          // mess of 3-4 visible buttons per state.
          _CardActions(
            passenger: passenger,
            tour: tour,
            isAssigned: isAssigned,
            isWaitlisted: isWaitlisted,
          ),
        ],
      ),
    );
  }
}

// ── Unified card actions: one primary CTA + overflow menu ─────
class _CardActions extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final bool isAssigned;
  final bool isWaitlisted;

  const _CardActions({
    required this.passenger,
    required this.tour,
    required this.isAssigned,
    required this.isWaitlisted,
  });

  TourController get _ctrl => Get.find<TourController>();

  Future<void> _sendAck() async {
    final sent = await WhatsAppService().sendAck(
      passenger: passenger,
      tour: tour,
    );
    if (sent) {
      AppSnackBar.success(
        tr('requests.snack.ack_opened', namedArgs: {'name': passenger.displayName}),
        title: tr('requests.snack.ack_title'),
      );
    } else {
      AppSnackBar.error(tr('requests.snack.ack_error'));
    }
  }

  Future<void> _toWaitlist() async {
    await _ctrl.setWaitlisted(tour.id, passenger.id, true);
    AppSnackBar.success(
      tr('requests.snack.moved_to_waitlist', namedArgs: {'name': passenger.displayName}),
    );
  }

  Future<void> _promote() async {
    await _ctrl.setWaitlisted(tour.id, passenger.id, false);
    AppSnackBar.success(
      tr('requests.snack.promoted_to_new', namedArgs: {'name': passenger.displayName}),
    );
  }

  Future<void> _unassignAll() async {
    await _ctrl.unassignSeats(tour.id, passenger.id);
    AppSnackBar.success(
      tr('requests.snack.seats_cleared', namedArgs: {'name': passenger.displayName}),
    );
  }

  Future<void> _confirmDecline() async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: Text(tr('requests.decline_dialog.title')),
        content: Text(
          tr('requests.decline_dialog.body', namedArgs: {'name': passenger.displayName}),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: Text(tr('app.action.cancel')),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: Text(tr('requests.decline_dialog.confirm')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _ctrl.removePassenger(tour.id, passenger.id);
    AppSnackBar.success(
      tr('requests.snack.declined_body', namedArgs: {'name': passenger.displayName}),
      title: tr('requests.snack.declined_title'),
    );
  }

  void _openAssignment() {
    Get.toNamed('/seat-assignment', arguments: {
      'tourId': tour.id,
      'passengerId': passenger.id,
    });
  }

  void _openEdit(BuildContext context) {
    EditRequestSheet.show(
      context: context,
      tour: tour,
      passenger: passenger,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Pick primary action + menu items by state.
    final String primaryLabel;
    final IconData primaryIcon;
    final Color primaryColor;
    final VoidCallback primaryAction;
    final List<_MenuItem> menu;

    final editItem = _MenuItem(
      tr('requests.action.edit_request'),
      Icons.edit_rounded,
      () => _openEdit(context),
    );

    if (isAssigned) {
      primaryLabel = tr('requests.action.view_assignment');
      primaryIcon = Icons.visibility_rounded;
      primaryColor = AppTheme.success;
      primaryAction = _openAssignment;
      menu = [
        editItem,
        _MenuItem(tr('requests.action.send_wa_ack'), Icons.chat_rounded, _sendAck),
        _MenuItem(tr('requests.action.unassign_all'), Icons.replay_rounded, _unassignAll),
      ];
    } else if (isWaitlisted) {
      primaryLabel = tr('requests.action.back_to_new');
      primaryIcon = Icons.arrow_back_rounded;
      primaryColor = AppTheme.brand;
      primaryAction = _promote;
      menu = [
        editItem,
        _MenuItem(tr('requests.action.send_wa_ack'), Icons.chat_rounded, _sendAck),
        _MenuItem(tr('requests.action.decline_request'), Icons.close_rounded,
            _confirmDecline,
            isDanger: true),
      ];
    } else {
      // NEW
      primaryLabel = tr('requests.action.assign_seats');
      primaryIcon = Icons.grid_view_rounded;
      primaryColor = AppTheme.brand;
      primaryAction = _openAssignment;
      menu = [
        editItem,
        _MenuItem(tr('requests.action.send_wa_ack'), Icons.chat_rounded, _sendAck),
        _MenuItem(tr('requests.action.move_to_waitlist'), Icons.hourglass_top_rounded, _toWaitlist),
        _MenuItem(tr('requests.action.decline_request'), Icons.close_rounded,
            _confirmDecline,
            isDanger: true),
      ];
    }

    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: primaryAction,
            child: Container(
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: primaryColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(primaryIcon, size: 16, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    primaryLabel,
                    style: AppText.chipText.copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Overflow menu — secondary actions live here instead of being
        // tiled across the card. Keeps the visible CTA count to one.
        Container(
          height: 40,
          width: 40,
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border(context)),
          ),
          child: PopupMenuButton<_MenuItem>(
            tooltip: tr('requests.action.more_actions'),
            icon: Icon(Icons.more_vert_rounded,
                size: 18, color: AppColors.textMuted(context)),
            position: PopupMenuPosition.under,
            onSelected: (item) => item.onTap(),
            itemBuilder: (_) => [
              for (final item in menu)
                PopupMenuItem<_MenuItem>(
                  value: item,
                  child: Row(
                    children: [
                      Icon(
                        item.icon,
                        size: 16,
                        color: item.isDanger
                            ? AppTheme.danger
                            : AppColors.textMuted(context),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        item.label,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: item.isDanger
                              ? AppTheme.danger
                              : AppColors.text(context),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MenuItem {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDanger;

  const _MenuItem(this.label, this.icon, this.onTap,
      {this.isDanger = false});
}

// ── Status Badge ──────────────────────────────────────────────
class _StatusBadge extends StatelessWidget {
  final bool isAssigned;
  final bool isWaitlisted;

  const _StatusBadge({
    required this.isAssigned,
    required this.isWaitlisted,
  });

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final String label;
    if (isAssigned) {
      bg = AppTheme.successLight;
      fg = AppTheme.success;
      label = tr('requests.status.seats_assigned');
    } else if (isWaitlisted) {
      bg = const Color(0xFFFEF3C7);
      fg = const Color(0xFFB45309);
      label = tr('requests.status.waitlist');
    } else {
      bg = AppTheme.infoLight;
      fg = AppTheme.info;
      label = tr('requests.status.new');
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(9999),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
          color: fg,
        ),
      ),
    );
  }
}

// ── Seat Chip ──────────────────────────────────────────────────
class _SeatChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color color;
  final Color bgColor;

  const _SeatChip({
    this.icon,
    required this.label,
    required this.color,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: AppText.cardMeta.copyWith(
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Empty State ───────────────────────────────────────────────
class _Empty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _Empty({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 56,
              color: AppColors.textMuted(context).withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.text(context),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppColors.textMuted(context),
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Add Request Sheet ─────────────────────────────────────────
// Agent-side direct-add flow. Bypasses the customer form entirely:
// the agent enters name + phone + seat counts and a Passenger row is
// written straight to the DB. Used when an old customer asks via
// WhatsApp / phone instead of submitting through the customer app.
class _AddRequestSheet extends StatefulWidget {
  final Tour tour;

  const _AddRequestSheet({required this.tour});

  @override
  State<_AddRequestSheet> createState() => _AddRequestSheetState();
}

class _AddRequestSheetState extends State<_AddRequestSheet> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();
  int _doubleSofa = 0;
  int _singleSofa = 0;
  TripType _tripType = TripType.roundTrip;
  bool _saving = false;

  int get _totalSeats => _doubleSofa + _singleSofa;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty) {
      AppSnackBar.error(tr('requests.validation.name_required'));
      return;
    }
    if (phone.length != 10) {
      AppSnackBar.error(tr('requests.validation.phone_invalid'));
      return;
    }
    if (_totalSeats == 0) {
      AppSnackBar.error(tr('requests.validation.seat_required'));
      return;
    }
    setState(() => _saving = true);
    try {
      final note = _note.text.trim();
      final requestLines = <RequestLine>[
        if (_doubleSofa > 0)
          RequestLine(seatType: SeatType.doubleSofa, qty: _doubleSofa),
        if (_singleSofa > 0)
          RequestLine(seatType: SeatType.singleSofa, qty: _singleSofa),
      ];
      final passenger = Passenger(
        tourId: widget.tour.id,
        name: name,
        phone: '+91${normalisePhone(phone)}',
        requestLines: requestLines,
        note: note.isEmpty ? null : note,
        tripType: _tripType,
      );
      await Get.find<TourController>().addPassenger(widget.tour.id, passenger);
      if (!mounted) return;
      Get.back();
      AppSnackBar.success(
        _totalSeats == 1
            ? tr('requests.snack.added_one', namedArgs: {'name': name})
            : tr('requests.snack.added_many', namedArgs: {'name': name, 'count': '$_totalSeats'}),
      );
    } catch (_) {
      if (mounted) {
        AppSnackBar.error(tr('requests.snack.add_error'));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.border(context),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              tr('requests.sheet.title'),
              style: GoogleFonts.inter(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.text(context),
              ),
            ),
            Text(
              tr('requests.sheet.subtitle', namedArgs: {'tourTitle': widget.tour.title}),
              style: GoogleFonts.inter(
                fontSize: 11,
                color: AppColors.textMuted(context),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: tr('requests.sheet.name_label'),
                hintText: tr('requests.sheet.name_hint'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  height: 48,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.bg(context),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.border(context)),
                  ),
                  child: Text(
                    '+91',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(10),
                    ],
                    decoration: InputDecoration(
                      labelText: tr('requests.sheet.phone_label'),
                      hintText: tr('requests.sheet.phone_hint'),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _TripTypeSegmented(
              value: _tripType,
              fromCity: widget.tour.fromCity,
              toCity: widget.tour.toCity,
              onChanged: (v) => setState(() => _tripType = v),
            ),
            const SizedBox(height: 12),
            _SeatCounter(
              label: tr('requests.sheet.double_sofa'),
              value: _doubleSofa,
              onChanged: (v) => setState(() => _doubleSofa = v),
            ),
            const SizedBox(height: 8),
            _SeatCounter(
              label: tr('requests.sheet.single_sofa'),
              value: _singleSofa,
              onChanged: (v) => setState(() => _singleSofa = v),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              maxLines: 2,
              maxLength: 160,
              decoration: InputDecoration(
                labelText: tr('requests.sheet.note_label'),
                hintText: tr('requests.sheet.note_hint'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _submit,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_rounded, size: 18),
                label: Text(_saving ? tr('requests.sheet.saving') : tr('requests.sheet.save')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
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

class _TripTypeSegmented extends StatelessWidget {
  final TripType value;
  final String fromCity;
  final String toCity;
  final ValueChanged<TripType> onChanged;

  const _TripTypeSegmented({
    required this.value,
    required this.fromCity,
    required this.toCity,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('requests.sheet.trip_type_label'),
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.textMuted(context),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _TripChip(
                icon: Icons.sync_alt_rounded,
                label: tr('requests.sheet.trip_round'),
                selected: value == TripType.roundTrip,
                onTap: () => onChanged(TripType.roundTrip),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _TripChip(
                icon: Icons.arrow_forward_rounded,
                label: tr('requests.sheet.trip_outbound', namedArgs: {
                  'from': fromCity,
                  'to': toCity,
                }),
                selected: value == TripType.outboundOnly,
                onTap: () => onChanged(TripType.outboundOnly),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _TripChip(
                icon: Icons.arrow_back_rounded,
                label: tr('requests.sheet.trip_return', namedArgs: {
                  'from': toCity,
                  'to': fromCity,
                }),
                selected: value == TripType.returnOnly,
                onTap: () => onChanged(TripType.returnOnly),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _TripChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TripChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppTheme.brandLight : AppColors.bg(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppTheme.brand : AppColors.border(context),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected ? AppTheme.brand : AppColors.textMuted(context),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 10,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: selected
                    ? AppTheme.brandDark
                    : AppColors.text(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeatCounter extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  const _SeatCounter({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.text(context),
              ),
            ),
          ),
          IconButton.outlined(
            visualDensity: VisualDensity.compact,
            onPressed: value > 0 ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          SizedBox(
            width: 32,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.text(context),
              ),
            ),
          ),
          IconButton.outlined(
            visualDensity: VisualDensity.compact,
            onPressed: value < 10 ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}
