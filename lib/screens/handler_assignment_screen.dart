import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../utils/app_snackbar.dart';

class HandlerAssignmentScreen extends StatefulWidget {
  final String tourId;
  const HandlerAssignmentScreen({super.key, required this.tourId});

  @override
  State<HandlerAssignmentScreen> createState() =>
      _HandlerAssignmentScreenState();
}

class _HandlerAssignmentScreenState extends State<HandlerAssignmentScreen> {
  String? _selectedPassengerId;

  @override
  void initState() {
    super.initState();
    final tourCtrl = Get.find<TourController>();
    final tour = tourCtrl.getTour(widget.tourId);
    // Pre-select the current handler if one exists
    _selectedPassengerId = tour?.handlerId;
  }

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();

    return Obx(() {
      final tour = tourCtrl.getTour(widget.tourId);
      if (tour == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const Center(child: Text('Tour not found')),
        );
      }

      final passengers = tour.passengers;

      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: Column(
            children: [
              // ── Header ──────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 20, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Get.back(),
                      icon: const Icon(
                        Icons.arrow_back,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Assign Handler',
                            style: GoogleFonts.inter(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                          Text(
                            tour.title,
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: AppTheme.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Body ────────────────────────────────────────
              Expanded(
                child: passengers.isEmpty
                    ? Center(
                        child: Text(
                          'No passengers added yet.',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Info card
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: AppTheme.infoLight,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: const BoxDecoration(
                                      color: AppTheme.info,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.info_outline,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      'The handler manages on-trip logistics including cash collection, passenger coordination, and emergency contact. Select a passenger to assign as handler.',
                                      style: GoogleFonts.inter(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w400,
                                        color: AppTheme.info,
                                        height: 1.5,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 20),

                            // Passenger label row
                            Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'PASSENGERS',
                                  style: GoogleFonts.inter(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 1,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                                Text(
                                  '${passengers.length} total',
                                  style: GoogleFonts.inter(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w400,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 12),

                            // Passenger list
                            ...passengers.map((p) {
                              final isSelected =
                                  p.id == _selectedPassengerId;
                              final isCurrentHandler = p.isHandler;
                              final seatLabel = p.assignedSeats.isNotEmpty
                                  ? 'Seat ${p.assignedSeats.join(', ')}'
                                  : '${p.requestedSeats} seat${p.requestedSeats > 1 ? 's' : ''} requested';

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: GestureDetector(
                                  onTap: () => setState(
                                      () => _selectedPassengerId = p.id),
                                  child: Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? AppTheme.warningLight
                                          : Colors.white,
                                      borderRadius:
                                          BorderRadius.circular(6),
                                      border: Border.all(
                                        color: isSelected
                                            ? AppTheme.warning
                                            : AppTheme.borderLight,
                                        width: 1,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Flexible(
                                                    child: Text(
                                                      p.name,
                                                      style:
                                                          GoogleFonts.inter(
                                                        fontSize: 15,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        color: AppTheme
                                                            .textPrimary,
                                                      ),
                                                      maxLines: 1,
                                                      overflow: TextOverflow
                                                          .ellipsis,
                                                    ),
                                                  ),
                                                  if (isCurrentHandler) ...[
                                                    const SizedBox(
                                                        width: 8),
                                                    Container(
                                                      padding:
                                                          const EdgeInsets
                                                              .symmetric(
                                                        horizontal: 8,
                                                        vertical: 3,
                                                      ),
                                                      decoration:
                                                          BoxDecoration(
                                                        color: AppTheme
                                                            .warningLight,
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(
                                                                    100),
                                                      ),
                                                      child: Row(
                                                        mainAxisSize:
                                                            MainAxisSize
                                                                .min,
                                                        children: [
                                                          const Icon(
                                                            Icons.star,
                                                            size: 10,
                                                            color: AppTheme
                                                                .warning,
                                                          ),
                                                          const SizedBox(
                                                              width: 3),
                                                          Text(
                                                            'Current Handler',
                                                            style: GoogleFonts
                                                                .inter(
                                                              fontSize: 10,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                              color: AppTheme
                                                                  .warning,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  const Icon(
                                                    Icons.phone,
                                                    size: 11,
                                                    color:
                                                        AppTheme.textMuted,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    p.phone,
                                                    style:
                                                        GoogleFonts.inter(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w400,
                                                      color: AppTheme
                                                          .textSecondary,
                                                    ),
                                                  ),
                                                  const SizedBox(
                                                      width: 12),
                                                  Text(
                                                    seatLabel,
                                                    style:
                                                        GoogleFonts.inter(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w400,
                                                      color: AppTheme
                                                          .textMuted,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                        // Radio button
                                        Container(
                                          width: 22,
                                          height: 22,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: isSelected
                                                  ? AppTheme.warning
                                                  : AppTheme.borderLight,
                                              width:
                                                  isSelected ? 2 : 1.5,
                                            ),
                                            color: isSelected
                                                ? AppTheme.warning
                                                : Colors.transparent,
                                          ),
                                          child: isSelected
                                              ? const Center(
                                                  child: CircleAvatar(
                                                    radius: 4,
                                                    backgroundColor:
                                                        Colors.white,
                                                  ),
                                                )
                                              : null,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
              ),

              // ── CTA ─────────────────────────────────────────
              if (passengers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _selectedPassengerId == null
                          ? null
                          : () async {
                              await tourCtrl.setHandler(
                                widget.tourId,
                                _selectedPassengerId!,
                              );
                              final selected = passengers.firstWhereOrNull(
                                  (p) => p.id == _selectedPassengerId);
                              if (selected != null) {
                                AppSnackBar.success(
                                  '${selected.name} is now the handler for this tour.',
                                  title: 'Handler Assigned',
                                );
                              }
                              Get.back();
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.brand,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor:
                            AppTheme.brand.withAlpha(100),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.verified_user, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Confirm Handler',
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
                ),
            ],
          ),
        ),
      );
    });
  }
}
