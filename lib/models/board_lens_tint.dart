part of 'board_lens.dart';

// ─────────────────────────────────────────────────────────────────────────────
// The five-tint cap.
// ─────────────────────────────────────────────────────────────────────────────

/// One candidate bucket for a tinted lens, before ranking.
@immutable
class BoardTintSeed {
  final String id;

  /// Already translated / already the stop's or group's own name.
  final String label;

  /// How many berths fall in this bucket. Buckets with none are dropped —
  /// "never render a legend for berths that do not exist" (spec §13).
  final int count;

  const BoardTintSeed({
    required this.id,
    required this.label,
    required this.count,
  });
}

/// A ranked bucket that won a tint.
@immutable
class BoardTintBucket {
  final String id;
  final String label;
  final int count;

  /// 0-4. Feeds [BoardTintScale.colorOf].
  final int tintIndex;

  const BoardTintBucket({
    required this.id,
    required this.label,
    required this.count,
    required this.tintIndex,
  });
}

/// The pickup / group lens's colour budget.
///
/// Past five fills the eye cannot rank colours reliably, so a tour with nine
/// pickup points does NOT get nine tints — it gets the five biggest and one
/// grey "other" bucket that says how many it stands for (spec §5). This class
/// is the whole of that rule, kept pure so the cap is provable in a test rather
/// than an intention in a widget.
@immutable
class BoardTintScale {
  /// Five. See the class doc — this is not a tunable.
  static const int maxTints = 5;

  /// The tinted buckets, biggest first, `tintIndex` 0-4.
  final List<BoardTintBucket> tinted;

  /// How many distinct buckets were folded into "other".
  final int otherBuckets;

  /// How many berths those folded buckets hold.
  final int otherBerths;

  const BoardTintScale._({
    required this.tinted,
    required this.otherBuckets,
    required this.otherBerths,
  });

  /// Nothing to tint — every occupied berth lands in "other". The state a
  /// pickup lens is in before any stop is configured.
  static const BoardTintScale empty = BoardTintScale._(
    tinted: <BoardTintBucket>[],
    otherBuckets: 0,
    otherBerths: 0,
  );

  /// Ranks [seeds] by berth count and keeps the top [maxTints].
  ///
  /// Ties break by the order [seeds] arrived in, which for pickups is the
  /// admin's route order — so two equal-sized stops always tint in the order
  /// the bus visits them, and the same tour never re-colours itself between
  /// two loads. (`List.sort` is not stable, hence the explicit index
  /// tiebreak.)
  factory BoardTintScale.fromSeeds(Iterable<BoardTintSeed> seeds) {
    final present = <(int, BoardTintSeed)>[];
    var i = 0;
    for (final s in seeds) {
      if (s.count > 0) present.add((i, s));
      i++;
    }
    present.sort((a, b) {
      final byCount = b.$2.count.compareTo(a.$2.count);
      return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
    });

    final tinted = <BoardTintBucket>[];
    var otherBuckets = 0;
    var otherBerths = 0;
    for (var rank = 0; rank < present.length; rank++) {
      final seed = present[rank].$2;
      if (rank < maxTints) {
        tinted.add(
          BoardTintBucket(
            id: seed.id,
            label: seed.label,
            count: seed.count,
            tintIndex: rank,
          ),
        );
      } else {
        otherBuckets++;
        otherBerths += seed.count;
      }
    }

    return BoardTintScale._(
      tinted: List.unmodifiable(tinted),
      otherBuckets: otherBuckets,
      otherBerths: otherBerths,
    );
  }

  bool get hasOther => otherBuckets > 0;

  bool get isEmpty => tinted.isEmpty && !hasOther;

  /// The tint slot for [id], or null when it belongs in "other" (including a
  /// berth with no stop / no group at all).
  int? tintIndexOf(String? id) {
    if (id == null) return null;
    for (final b in tinted) {
      if (b.id == id) return b.tintIndex;
    }
    return null;
  }

  String? labelOf(String? id) {
    if (id == null) return null;
    for (final b in tinted) {
      if (b.id == id) return b.label;
    }
    return null;
  }

  /// The app's one unbounded, collision-avoiding tint generator
  /// (`lib/design/group_color.dart`) — the same hues seat charts already ring
  /// groups with, so a stop tint can never be mistaken for the amber "yours"
  /// accent or the GO/RET one-way tints.
  Color colorOf(int tintIndex) => groupColor(tintIndex);
}

/// Non-colour identifiers for the five tint slots. Letters, not digits, so a
/// tint marker is never misread as part of a berth code like `DL3`.
const List<String> kTintGlyphs = <String>['A', 'B', 'C', 'D', 'E'];

/// The "other" bucket's glyph.
const String kOtherGlyph = '+';

/// An occupied berth with no stop / no group at all.
const String kUnbucketedGlyph = '·';

/// Alpha the tinted lenses paint a generated hue at. Defined ONCE: the
/// semantic colours ship paired `…Fill` tokens for exactly this reason, and a
/// generated hue has no such pair, so this is the single place the pairing is
/// invented rather than drifting per call site. Low enough that
/// [UgamColorSet.ink] stays AA-legible on top in both themes.
const double kTintFillAlpha = 0.22;
