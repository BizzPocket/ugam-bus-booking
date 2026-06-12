import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../utils/seat_grid_placement.dart';

/// Stacked passenger identity for a seat tile: the full name (bold) above the
/// mobile number, both auto-shrunk to fit the cell.
///
/// Name and mobile are mandatory on every passenger, so this is the canonical
/// way a booked seat reads in the grid charts — replacing the old initials-only
/// glyph. The number is formatted with [displayPhone] (last-10 / digits-only)
/// and only hidden in the rare case a passenger has no digits on file.
class SeatOccupantLabel extends StatelessWidget {
  final String name;
  final String? phone;
  final Color nameColor;
  final Color phoneColor;

  /// Cap font sizes; the [FittedBox] only ever scales DOWN from these, so a
  /// short name stays crisp while a long one shrinks to fit.
  final double nameSize;
  final double phoneSize;

  const SeatOccupantLabel({
    super.key,
    required this.name,
    required this.phone,
    required this.nameColor,
    required this.phoneColor,
    this.nameSize = 13,
    this.phoneSize = 10,
  });

  @override
  Widget build(BuildContext context) {
    final number = displayPhone(phone);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            name,
            textAlign: TextAlign.center,
            maxLines: 1,
            softWrap: false,
            style: UgamText.bodyStrong.copyWith(
              color: nameColor,
              fontSize: nameSize,
              fontWeight: FontWeight.w800,
              height: 1.05,
            ),
          ),
        ),
        if (number != null && number.isNotEmpty) ...[
          const SizedBox(height: 1),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              number,
              maxLines: 1,
              softWrap: false,
              style: UgamText.tabular(
                UgamText.micro.copyWith(
                  color: phoneColor,
                  fontSize: phoneSize,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
