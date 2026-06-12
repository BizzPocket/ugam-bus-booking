import 'package:flutter/material.dart';

/// Infinite, visually-distinct group-color generator for seat tiles.
///
/// Groups have no upper bound, so a fixed N-hue palette eventually recycles and
/// two unrelated groups read as one. Instead we walk the hue wheel by the
/// golden angle (137.508 deg). Successive indices land far apart on the wheel
/// and the sequence never exactly repeats, so even adjacent groups stay
/// distinguishable for an unbounded count.
///
/// All hues are deliberately kept OUT of three reserved bands so a group ring is
/// never confused with another tile signal:
///   * warm-amber attention band (~25-55 deg) — that hue belongs to the `warm`
///     priority / forward ring (occupant.isPriorityApproved, cell.forward).
///   * coffee / mocha accent band (~20-35 deg, low saturation) — the brand
///     `accent`. Group rings stay high-saturation, which separates them from
///     the muted coffee even where the hues are near.
///   * one-way cool-cyan band around [kOneWayTint] (~190 deg) — reserved for the
///     outbound (GO) one-way trip treatment. Group hues skip a guard window
///     around it.
///   * return violet band around [kReturnTint] (~284 deg) — reserved for the
///     return-only (RET) one-way treatment, so a RET tint never reads as a group
///     ring. Group hues skip a guard window around it too.
///
/// Saturation and lightness are fixed so a thin ring reads as a crisp, saturated
/// stroke on the near-black dark ground while staying acceptable on the light
/// ground (not so pale it vanishes on white).
class GroupColor {
  const GroupColor._();

  /// Golden angle, in degrees. Stepping the hue wheel by this amount gives a
  /// maximally-spread, low-collision sequence for an unbounded index.
  static const double _goldenAngle = 137.508;

  /// Fixed HSL saturation/lightness for every group ring. High saturation keeps
  /// the ring distinct from the muted coffee accent; this lightness reads on
  /// both the near-black dark ground and the white light ground.
  static const double _saturation = 0.68;
  static const double _lightness = 0.66;

  /// Hue (deg) of the reserved outbound one-way tint. Group hues are pushed out
  /// of a guard window centered here so a group ring never reads as the GO
  /// treatment.
  static const double _oneWayHue = 190;

  /// Hue (deg) of the reserved return-only tint. Group hues skip a guard window
  /// here too so a RET tint never reads as a group ring.
  static const double _returnHue = 284;

  /// Half-width (deg) of each reserved guard window.
  static const double _warmHalfWidth = 18; // covers ~22-58 around amber 40
  static const double _warmCenter = 40;
  static const double _oneWayHalfWidth = 12; // covers ~178-202 around 190
  static const double _returnHalfWidth = 12; // covers ~272-296 around 284

  /// Maps a raw wheel hue into the allowed band by skipping the reserved
  /// warm-amber, GO one-way, and RET return guard windows. The hue is remapped
  /// onto a continuous "allowed" circle then projected back, so the golden-angle
  /// spread is preserved while no output ever lands in a reserved window.
  static double _avoidReservedBands(double rawHue) {
    // Total width removed from the 360 deg wheel by the guard windows.
    const warmSpan = _warmHalfWidth * 2;
    const oneWaySpan = _oneWayHalfWidth * 2;
    const returnSpan = _returnHalfWidth * 2;
    const allowedSpan = 360 - warmSpan - oneWaySpan - returnSpan;

    // Position on the shrunken allowed circle.
    var t = (rawHue % 360) / 360 * allowedSpan;

    // Build the allowed circle by walking 0..360 and skipping the windows.
    final warmStart = (_warmCenter - _warmHalfWidth) % 360;
    final oneWayStart = (_oneWayHue - _oneWayHalfWidth) % 360;
    final returnStart = (_returnHue - _returnHalfWidth) % 360;

    // Order the windows by their start so we can project linearly: each window
    // the projected hue has reached shifts it past that window's full width.
    final windows = <List<double>>[
      [warmStart, warmStart + warmSpan],
      [oneWayStart, oneWayStart + oneWaySpan],
      [returnStart, returnStart + returnSpan],
    ]..sort((a, b) => a[0].compareTo(b[0]));

    var hue = t;
    for (final w in windows) {
      // If the projected hue has reached this window's start, jump past it.
      if (hue >= w[0]) {
        hue += (w[1] - w[0]);
      } else {
        break;
      }
    }
    return hue % 360;
  }

  /// Color for a group at a known [index] (0-based). Stable for a given index.
  static Color forIndex(int index) {
    final rawHue = (index * _goldenAngle) % 360;
    final hue = _avoidReservedBands(rawHue);
    return HSLColor.fromAHSL(1, hue, _saturation, _lightness).toColor();
  }

  /// Color for a group when the caller has no stable index — hashes [groupId]
  /// into the same golden-angle sequence so a given id always yields the same
  /// color within and across sessions (hashCode is stable for a given string).
  static Color forId(String groupId) {
    // Spread the hash across a wide index range before stepping by the golden
    // angle, so distinct ids rarely share a hue.
    final index = groupId.hashCode.abs() % 100000;
    return forIndex(index);
  }
}

/// Color for a group at a known [index]. Golden-angle hue rotation; see
/// [GroupColor].
Color groupColor(int index) => GroupColor.forIndex(index);

/// Color for a group identified only by [groupId]. Hashes the id into the same
/// generator; see [GroupColor].
Color groupColorForId(String groupId) => GroupColor.forId(groupId);

/// Reserved one-way trip tint — a cool cyan/teal (~190 deg) used to mark the
/// OUTBOUND (GO) one-way leg on a seat. [groupColor] deliberately avoids this
/// hue band so a one-way tint is never mistaken for a group ring.
const Color kOneWayTint = Color(0xFF2BC8D6);

/// Reserved return-only trip tint — an orchid violet (~284 deg) used to mark the
/// RETURN (RET) one-way leg, distinct from the GO cyan so the handler can tell a
/// go-only seat from a return-only seat at a glance (each pays half fare).
/// [groupColor] avoids this hue band too so a RET tint never reads as a group.
const Color kReturnTint = Color(0xFFC06BE0);

/// Resolves a [Passenger.groupId] to its stable ring colour, shared by every
/// seat chart in the app so a group reads as the same colour everywhere.
///
/// Groups have no upper bound, so a fixed N-hue palette eventually recycles and
/// two unrelated groups read as one. This resolver feeds the unbounded
/// [groupColor] / [groupColorForId] golden-angle sequence:
///
///   * When the tour carries a `PassengerGroup` list, each group's own stable
///     `colorIndex` drives [groupColor] — deterministic per group across
///     sessions, not a session-local hash.
///   * Any id NOT in that map (or a tour with no groups) falls back to
///     [groupColorForId], which hashes the id into the same sequence.
class GroupColorResolver {
  /// groupId → stable palette index (from `PassengerGroup.colorIndex`).
  final Map<String, int> _indexById;

  const GroupColorResolver(this._indexById);

  Color colorFor(String groupId) {
    final idx = _indexById[groupId];
    if (idx != null) return groupColor(idx);
    return groupColorForId(groupId);
  }
}
