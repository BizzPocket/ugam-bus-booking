import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/passenger_group.dart';
import '../models/tour.dart';
import '../routes/app_routes.dart';
import '../utils/app_snackbar.dart';

part 'group_picker/add_member_sheet.dart';
part 'group_picker/option_rows.dart';
part 'group_picker/assign_group_sheet.dart';

/// Small colour dot for a cross-booking group. Uses the app-wide golden-angle
/// [groupColor] so a group reads as the SAME hue here as on every seat chart.
class GroupDot extends StatelessWidget {
  final int colorIndex;
  final double size;
  const GroupDot({super.key, required this.colorIndex, this.size = 9});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: groupColor(colorIndex),
      shape: BoxShape.circle,
    ),
  );
}

/// Rounded-square numbered badge in the group's golden-angle colour. [number]
/// is the group's 1-based order on the tour (so the colour reads as "group #1"),
/// and the hue matches the SAME group on every seat chart. Used as the group
/// card's avatar and, shrunk down, inside [GroupTag].
class GroupNumberBadge extends StatelessWidget {
  final int number;
  final int colorIndex;
  final double size;
  final double radius;
  final double fontSize;

  const GroupNumberBadge({
    super.key,
    required this.number,
    required this.colorIndex,
    this.size = 28,
    this.radius = 9,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: groupColor(colorIndex),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        '$number',
        style: UgamText.bodyStrong.copyWith(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Compact group tag for a passenger row: a tiny numbered colour square + the
/// group label in one pill, meant to sit BESIDE the passenger's name. Reads the
/// same number + colour as the group's card, so the two never drift.
class GroupTag extends StatelessWidget {
  final int number;
  final int colorIndex;
  final String label;

  const GroupTag({
    super.key,
    required this.number,
    required this.colorIndex,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(3, 3, 8, 3),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GroupNumberBadge(
            number: number,
            colorIndex: colorIndex,
            size: 16,
            radius: 5,
            fontSize: 9,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: UgamText.caption.copyWith(
                color: c.ink2,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Capacity facts for a cross-booking group measured against ONE bus. A group
/// must ride a single bus, so its berths are sized against the tour's largest
/// bus ([Tour.biggestBusSeats]). [capacity] is 0 when the tour has no buses,
/// in which case sizing can't be enforced ([hasBus] is false).
class GroupFit {
  final int used;
  final int capacity;
  const GroupFit(this.used, this.capacity);

  factory GroupFit.of(Tour tour, String groupId) =>
      GroupFit(tour.groupSeatBerths(groupId), tour.biggestBusSeats);

  bool get hasBus => capacity > 0;
  int get remaining => capacity - used;
  bool get isFull => hasBus && used >= capacity;
  bool get isOver => hasBus && used > capacity;

  /// Whether [extra] more berths still fit on one bus.
  bool fits(int extra) => !hasBus || used + extra <= capacity;
}

String _displayName(Passenger p) =>
    p.name.trim().isEmpty ? tr('tour_groups.unnamed') : p.name.trim();
