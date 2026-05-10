import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../utils/passenger_display.dart';

class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  final tourCtrl = Get.find<TourController>();
  int _selectedTourIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgLight,
      body: SafeArea(
        child: Obx(() {
          final activeTours = tourCtrl.activeTours;
          if (activeTours.isEmpty) {
            return const _Empty(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'No active tours',
              body: 'Create a tour to start collecting seat requests.',
            );
          }

          // Clamp selected index
          if (_selectedTourIndex >= activeTours.length) {
            _selectedTourIndex = 0;
          }

          final selectedTour = activeTours[_selectedTourIndex];
          final passengers = selectedTour.passengers;

          final newCount =
              passengers.where((p) => p.totalSeatsAssigned == 0).length;
          final assignedCount =
              passengers.where((p) => p.totalSeatsAssigned > 0).length;

          return Column(
            children: [
              // ── Header ──
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Requests',
                      style: GoogleFonts.inter(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.brandLight,
                        borderRadius: BorderRadius.circular(9999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.tune_rounded,
                              size: 14, color: AppTheme.brand),
                          const SizedBox(width: 6),
                          Text(
                            'Filter',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.brand,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

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
                          color: isActive ? AppTheme.brand : Colors.white,
                          borderRadius: BorderRadius.circular(9999),
                          border: isActive
                              ? null
                              : Border.all(color: AppTheme.borderLight),
                        ),
                        child: Center(
                          child: Text(
                            tour.title,
                            style: GoogleFonts.inter(
                              fontSize: 13,
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

              // ── Stats Bar ──
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    _StatCard(
                      value: '$newCount',
                      label: 'NEW',
                      color: AppTheme.info,
                      bgColor: AppTheme.infoLight,
                    ),
                    const SizedBox(width: 10),
                    _StatCard(
                      value: '$assignedCount',
                      label: 'ASSIGNED',
                      color: AppTheme.success,
                      bgColor: AppTheme.successLight,
                    ),
                    const SizedBox(width: 10),
                    _StatCard(
                      value: '0',
                      label: 'DECLINED',
                      color: AppTheme.danger,
                      bgColor: AppTheme.dangerLight,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Request List ──
              Expanded(
                child: passengers.isEmpty
                    ? const _Empty(
                        icon: Icons.people_outline_rounded,
                        title: 'No requests yet',
                        body: 'Passengers will appear here once they submit seat requests.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: passengers.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: 12),
                        itemBuilder: (context, i) {
                          final passenger = passengers[i];
                          final isAssigned =
                              passenger.totalSeatsAssigned > 0;
                          return _RequestCard(
                            passenger: passenger,
                            tour: selectedTour,
                            isAssigned: isAssigned,
                          );
                        },
                      ),
              ),
            ],
          );
        }),
      ),
    );
  }
}

// ── Stat Card ─────────────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final Color color;
  final Color bgColor;

  const _StatCard({
    required this.value,
    required this.label,
    required this.color,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: GoogleFonts.inter(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1,
                color: color,
              ),
            ),
          ],
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
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'Just now';
  }

  @override
  Widget build(BuildContext context) {
    final avatarBg = _avatarColor(passenger.name);
    final initials = _initials(passenger.name);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isAssigned ? AppTheme.success : AppTheme.borderLight,
          width: isAssigned ? 1.5 : 1,
        ),
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
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
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
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _timeAgo(passenger.createdAt),
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              // Status badge
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color:
                      isAssigned ? AppTheme.successLight : AppTheme.infoLight,
                  borderRadius: BorderRadius.circular(9999),
                ),
                child: Text(
                  isAssigned ? 'SEATS ASSIGNED' : 'NEW',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: isAssigned ? AppTheme.success : AppTheme.info,
                  ),
                ),
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
                color: AppTheme.hoverLight,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.chat_bubble_outline_rounded,
                      size: 16, color: AppTheme.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '"${passenger.note}"',
                      style: GoogleFonts.newsreader(
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                        color: AppTheme.textSecondary,
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
                  label: '${passenger.totalSeatsRequested} Seats',
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
              ],
            ),
          ],

          const SizedBox(height: 12),

          // ── Action Buttons ──
          if (isAssigned)
            _AssignedSection(passenger: passenger, tour: tour)
          else
            _NewRequestActions(passenger: passenger, tour: tour),
        ],
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
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

// ── New Request Actions (Assign + Decline) ────────────────────
class _NewRequestActions extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;

  const _NewRequestActions({
    required this.passenger,
    required this.tour,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Assign Seats button
        Expanded(
          child: GestureDetector(
            onTap: () {
              Get.toNamed('/seat-assignment', arguments: {
                'tourId': tour.id,
                'passengerId': passenger.id,
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.brand,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.grid_view_rounded,
                      size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                  Text(
                    'Assign Seats →',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Decline button
        Expanded(
          child: GestureDetector(
            onTap: () async {
              final confirmed = await Get.dialog<bool>(
                AlertDialog(
                  title: const Text('Decline request?'),
                  content: Text(
                    'Remove ${passenger.displayName}\'s request from this tour? '
                    'They will need to resubmit if you change your mind.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Get.back(result: false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Get.back(result: true),
                      style: TextButton.styleFrom(
                        foregroundColor: AppTheme.danger,
                      ),
                      child: const Text('Decline'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              await Get.find<TourController>()
                  .removePassenger(tour.id, passenger.id);
              Get.snackbar(
                'Declined',
                '${passenger.displayName} removed from this tour.',
                snackPosition: SnackPosition.BOTTOM,
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderDefault),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.close_rounded,
                      size: 14, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    'Decline',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Assigned Section (View Assignment + Bus Info + Seat Badges) ──
class _AssignedSection extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;

  const _AssignedSection({
    required this.passenger,
    required this.tour,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // View Assignment button
        GestureDetector(
          onTap: () {
            Get.toNamed('/seat-assignment', arguments: {
              'tourId': tour.id,
              'passengerId': passenger.id,
            });
          },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.successLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.success),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.visibility_rounded,
                    size: 14, color: AppTheme.success),
                const SizedBox(width: 6),
                Text(
                  'View Assignment',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.success,
                  ),
                ),
              ],
            ),
          ),
        ),

        // Bus info + seat badges
        if (passenger.assignedSeats.isNotEmpty) ...[
          const SizedBox(height: 12),
          // Bus info row
          _buildBusInfo(),
          const SizedBox(height: 8),
          // Seat badges
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Text(
                'Seats:',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.textSecondary,
                ),
              ),
              ...passenger.assignedSeats.map(
                (seat) => Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.successLight,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: AppTheme.success),
                  ),
                  child: Text(
                    seat.seatId,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.success,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildBusInfo() {
    final firstSeat = passenger.assignedSeats.first;
    final busMatch = tour.buses.where((b) => b.id == firstSeat.busId);
    final busLabel = busMatch.isNotEmpty
        ? '${busMatch.first.name} · ${busMatch.first.busNumber}'
        : 'Bus';

    return Row(
      children: [
        const Icon(Icons.directions_bus_rounded,
            size: 12, color: AppTheme.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            busLabel,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppTheme.textSecondary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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
              color: AppTheme.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppTheme.textMuted,
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
