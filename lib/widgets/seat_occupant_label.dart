import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../utils/seat_grid_placement.dart';

/// Stacked passenger identity for a seat tile: the full name (bold) above the
/// mobile number, at FIXED readable sizes.
///
/// Name and mobile are mandatory on every passenger, so this is the canonical
/// way a booked seat reads in the grid charts. The name is shown at a fixed
/// size and WRAPS up to [nameMaxLines] before ellipsis — it never shrinks to
/// unreadable (the old FittedBox scale-down made long names vanish). The number
/// is one tabular line, formatted with [displayPhone] (last-10 / digits-only)
/// and only hidden when a passenger has no digits on file.
class SeatOccupantLabel extends StatelessWidget {
  final String name;
  final String? phone;
  final Color nameColor;
  final Color phoneColor;

  /// FIXED font sizes — the text is never scaled below these.
  final double nameSize;
  final double phoneSize;

  /// How many lines the name may wrap to before ellipsis. Two by default so a
  /// medium name stays whole; tight split halves pass 1.
  final int nameMaxLines;

  const SeatOccupantLabel({
    super.key,
    required this.name,
    required this.phone,
    required this.nameColor,
    required this.phoneColor,
    this.nameSize = 13,
    this.phoneSize = 9.5,
    this.nameMaxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final number = displayPhone(phone);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          name,
          textAlign: TextAlign.center,
          maxLines: nameMaxLines,
          overflow: TextOverflow.ellipsis,
          style: UgamText.bodyStrong.copyWith(
            color: nameColor,
            fontSize: nameSize,
            fontWeight: FontWeight.w700,
            height: 1.12,
          ),
        ),
        if (number != null && number.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            number,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: UgamText.tabular(
              UgamText.micro.copyWith(
                color: phoneColor,
                fontSize: phoneSize,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
