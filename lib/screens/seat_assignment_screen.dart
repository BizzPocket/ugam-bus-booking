import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/passenger.dart';
import 'confirm_seat_screen.dart';

enum _SeatState { available, booked, selected }

class SeatAssignmentScreen extends StatefulWidget {
  final String? tourId;
  const SeatAssignmentScreen({super.key, this.tourId});

  @override
  State<SeatAssignmentScreen> createState() => _SeatAssignmentScreenState();
}

class _SeatAssignmentScreenState extends State<SeatAssignmentScreen> {
  int _activeDeckTab = 0;
  final Set<String> _selectedSeats = {};
  int _selectedPassengerIndex = 0;

  String get _tourId =>
      widget.tourId ?? (Get.arguments?['tourId'] as String? ?? '');

  String? get _passengerId => Get.arguments?['passengerId'] as String?;

  @override
  void initState() {
    super.initState();
    // If a specific passenger was passed, pre-select them
    if (_passengerId != null) {
      final tourCtrl = Get.find<TourController>();
      final tour = tourCtrl.getTour(_tourId);
      if (tour != null) {
        final idx =
            tour.passengers.indexWhere((p) => p.id == _passengerId);
        if (idx >= 0) _selectedPassengerIndex = idx;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Obx(() {
      final tour = tourCtrl.getTour(_tourId);
      if (tour == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('Tour not found')),
        );
      }

      final busDetails = tour.busDetails;
      final passengers = tour.passengers;

      if (passengers.isEmpty) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Seat Assignment'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Get.back(),
            ),
          ),
          body: const Center(
              child: Text('No passengers added to this tour yet.')),
        );
      }

      // Clamp index
      if (_selectedPassengerIndex >= passengers.length) {
        _selectedPassengerIndex = 0;
      }
      final currentPassenger = passengers[_selectedPassengerIndex];

      // Collect all already-booked seats from other passengers
      final bookedSeats = <String>{};
      for (final p in passengers) {
        if (p.id != currentPassenger.id) {
          bookedSeats.addAll(p.assignedSeats);
        }
      }
      // Also include this passenger's currently assigned seats as pre-selected
      // (so they can modify)

      final totalSeats = busDetails?.totalSeats ?? 45;
      final busNumber = busDetails?.busNumber ?? 'Not assigned';
      final busType = busDetails?.busType ?? 'Unknown';
      final driverName = busDetails?.driverName ?? 'Not assigned';
      final isAC = busDetails?.isAC ?? false;
      final totalAssigned = passengers.fold<int>(
          0, (sum, p) => sum + p.assignedSeats.length);

      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: Column(
            children: [
              _buildHeader(tour.title, totalSeats, totalAssigned),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 12),
                      // Passenger selector
                      _buildPassengerSelector(passengers),
                      const SizedBox(height: 12),
                      // Bus info
                      _buildBusInfoCard(
                          busNumber, busType, driverName, isAC,
                          totalSeats, totalAssigned),
                      const SizedBox(height: 12),
                      _buildDeckTabs(),
                      const SizedBox(height: 12),
                      _buildSeatChart(totalSeats, bookedSeats),
                      const SizedBox(height: 100),
                    ],
                  ),
                ),
              ),
              _buildAssignPanel(
                  currentPassenger, busNumber, busType, driverName),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildHeader(
      String tourTitle, int totalSeats, int totalAssigned) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 12),
      color: AppTheme.bgLight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Get.back(),
                icon: const Icon(Icons.arrow_back,
                    color: AppTheme.textPrimary, size: 22),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 40, minHeight: 40),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Seat Assignment',
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 44),
            child: Text(
              '$tourTitle \u00B7 $totalAssigned/$totalSeats Seats Assigned',
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPassengerSelector(List<Passenger> passengers) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: passengers.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final p = passengers[index];
          final isSelected = index == _selectedPassengerIndex;
          final hasSeats = p.assignedSeats.isNotEmpty;
          return GestureDetector(
            onTap: () => setState(() {
              _selectedPassengerIndex = index;
              _selectedSeats.clear();
            }),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.brand
                    : hasSeats
                        ? AppTheme.successLight
                        : Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: isSelected
                    ? null
                    : Border.all(
                        color: hasSeats
                            ? AppTheme.success
                            : AppTheme.borderLight),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    p.name,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isSelected
                          ? Colors.white
                          : hasSeats
                              ? AppTheme.success
                              : AppTheme.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hasSeats
                        ? 'Seats: ${p.assignedSeats.join(", ")}'
                        : '${p.requestedSeats} seat${p.requestedSeats > 1 ? "s" : ""} needed',
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w400,
                      color: isSelected
                          ? Colors.white.withAlpha(200)
                          : AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBusInfoCard(String busNumber, String busType,
      String driverName, bool isAC, int totalSeats, int totalAssigned) {
    final percentFull =
        totalSeats > 0 ? ((totalAssigned / totalSeats) * 100).round() : 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.brand.withAlpha(30)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                const Icon(Icons.directions_bus,
                    size: 16, color: AppTheme.brand),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$busNumber \u00B7 $busType',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Driver: $driverName \u00B7 ${isAC ? "AC" : "Non-AC"} \u00B7 $totalSeats seats',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w400,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$totalAssigned/$totalSeats',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.brand,
                ),
              ),
              Text(
                '$percentFull% full',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: AppTheme.success,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDeckTabs() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          _buildDeckTab('Lower Deck', 0),
          _buildDeckTab('Upper Deck', 1),
        ],
      ),
    );
  }

  Widget _buildDeckTab(String label, int index) {
    final isActive = _activeDeckTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _activeDeckTab = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isActive ? AppTheme.brand : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              color: isActive ? Colors.white : AppTheme.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSeatChart(int totalSeats, Set<String> bookedSeats) {
    final prefix = _activeDeckTab == 0 ? 'L' : 'U';
    final seatsPerDeck = (totalSeats / 2).ceil();
    final totalRows = (seatsPerDeck / 4).ceil();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: AppTheme.cardShadow,
      ),
      child: Column(
        children: [
          // Driver row
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.textMuted.withAlpha(38),
                  ),
                  child: const Icon(Icons.person,
                      size: 16, color: AppTheme.textMuted),
                ),
                const SizedBox(width: 8),
                Text(
                  'DRIVER',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textMuted,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          // Seat grid
          ...List.generate(totalRows, (row) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildSeat('$prefix${row * 4 + 1}', bookedSeats),
                  const SizedBox(width: 8),
                  _buildSeat('$prefix${row * 4 + 2}', bookedSeats),
                  const SizedBox(width: 24),
                  _buildSeat('$prefix${row * 4 + 3}', bookedSeats),
                  const SizedBox(width: 8),
                  _buildSeat('$prefix${row * 4 + 4}', bookedSeats),
                ],
              ),
            );
          }),
          const SizedBox(height: 16),
          // Legend
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegendItem('Available', AppTheme.brandLight,
                  borderColor: AppTheme.borderLight),
              const SizedBox(width: 16),
              _buildLegendItem('Booked', AppTheme.brand),
              const SizedBox(width: 16),
              _buildLegendItem('Selected', const Color(0xFFF59E0B)),
            ],
          ),
        ],
      ),
    );
  }

  _SeatState _getSeatState(String seatId, Set<String> bookedSeats) {
    if (_selectedSeats.contains(seatId)) return _SeatState.selected;
    if (bookedSeats.contains(seatId)) return _SeatState.booked;
    return _SeatState.available;
  }

  Widget _buildSeat(String seatId, Set<String> bookedSeats) {
    final state = _getSeatState(seatId, bookedSeats);

    Color bgColor;
    Color textColor;
    FontWeight fontWeight = FontWeight.w500;
    List<BoxShadow>? shadow;
    Border? border;

    switch (state) {
      case _SeatState.available:
        bgColor = AppTheme.brandLight;
        textColor = AppTheme.textMuted;
        border = Border.all(color: AppTheme.borderLight, width: 1.5);
        break;
      case _SeatState.booked:
        bgColor = AppTheme.brand;
        textColor = Colors.white;
        break;
      case _SeatState.selected:
        bgColor = const Color(0xFFF59E0B);
        textColor = Colors.white;
        fontWeight = FontWeight.w700;
        shadow = [
          const BoxShadow(
            color: Color(0x40F59E0B),
            offset: Offset(0, 2),
            blurRadius: 8,
          ),
        ];
        break;
    }

    return GestureDetector(
      onTap: () {
        if (bookedSeats.contains(seatId)) return;
        setState(() {
          if (_selectedSeats.contains(seatId)) {
            _selectedSeats.remove(seatId);
          } else {
            _selectedSeats.add(seatId);
          }
        });
      },
      child: Container(
        width: 60,
        height: 44,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          border: border,
          boxShadow: shadow,
        ),
        alignment: Alignment.center,
        child: Text(
          seatId,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: fontWeight,
            color: textColor,
          ),
        ),
      ),
    );
  }

  Widget _buildLegendItem(String label, Color color,
      {Color? borderColor}) {
    return Row(
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
            border:
                borderColor != null ? Border.all(color: borderColor) : null,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildAssignPanel(Passenger passenger, String busNumber,
      String busType, String driverName) {
    final seatsNeeded = passenger.requestedSeats;
    final selectedCount = _selectedSeats.length;
    final remaining = seatsNeeded - selectedCount;
    final tourCtrl = Get.find<TourController>();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(12)),
        border:
            const Border(top: BorderSide(color: AppTheme.borderLight)),
        boxShadow: [
          const BoxShadow(
            color: Color(0x0A000000),
            offset: Offset(0, -4),
            blurRadius: 12,
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Passenger info
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.brand,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    passenger.name.isNotEmpty
                        ? passenger.name[0].toUpperCase()
                        : '?',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        passenger.name,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      Text(
                        passenger.phone,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Seat badges
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.brandLight,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${passenger.requestedSeats} seats',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.brand,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.brandLight,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    passenger.seatPreference.name == 'singleSofa'
                        ? 'Single Sofa'
                        : 'Double Sofa',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.brand,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Selected seats row
            Row(
              children: [
                Text(
                  'Selected:',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                if (_selectedSeats.isEmpty)
                  Text(
                    'Tap seats to select',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      color: AppTheme.textMuted,
                    ),
                  )
                else
                  Expanded(
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: (_selectedSeats.toList()..sort())
                          .map(
                            (seat) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF3C7),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                seat,
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF92400E),
                                ),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                if (remaining > 0 && _selectedSeats.isNotEmpty)
                  Text(
                    '$remaining more',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: const Color(0xFFDC2626),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // Assign button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: selectedCount > 0
                    ? () {
                        final sortedSeats = _selectedSeats.toList()
                          ..sort();
                        // Save to Appwrite
                        tourCtrl.assignSeats(
                          _tourId,
                          passenger.id,
                          sortedSeats,
                        );
                        Get.to(() => ConfirmSeatScreen(
                              tourId: _tourId,
                              passengerId: passenger.id,
                              passengerName: passenger.name,
                              passengerPhone: passenger.phone,
                              assignedSeats: sortedSeats,
                              busNumber: busNumber,
                              busType: busType,
                              driverName: driverName,
                              deckLabel: _activeDeckTab == 0
                                  ? 'Lower Deck'
                                  : 'Upper Deck',
                              totalRequested: passenger.requestedSeats,
                            ));
                      }
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  disabledBackgroundColor:
                      AppTheme.brand.withAlpha(100),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  elevation: 0,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.grid_view_rounded,
                        size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      'Assign $selectedCount of $seatsNeeded Seats',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
