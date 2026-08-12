import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/tokens.dart';

/// WCAG 2.1 relative-contrast guard over the palette itself.
///
/// Every contrast bug found by hand this cycle (rose caveat text on its own
/// rose fill, ~4.4:1 in Daylight) was a token PAIR problem, not a screen
/// problem — so it belongs here, checked once, rather than re-measured per
/// screen forever.
///
/// Fills in this palette are semi-transparent (e.g. `warmFill` is 16% rose),
/// so a naive ratio against the raw fill colour is meaningless — each one is
/// composited over the surface it actually sits on first.
Color _composite(Color fg, Color bg) {
  final a = fg.a;
  return Color.from(
    alpha: 1,
    red: fg.r * a + bg.r * (1 - a),
    green: fg.g * a + bg.g * (1 - a),
    blue: fg.b * a + bg.b * (1 - a),
  );
}

double _contrast(Color fg, Color bg) {
  final l1 = fg.computeLuminance();
  final l2 = bg.computeLuminance();
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

/// AA for normal-size text. The palette's small styles (micro, caption) are
/// normal text as far as WCAG is concerned — 11–13px is nowhere near the
/// 18.66px bold / 24px threshold that would let 3:1 apply.
const _aaNormal = 4.5;

void main() {
  final themes = {'Midnight (dark)': UgamColors.dark, 'Daylight (light)': UgamColors.light};

  group('body ink meets AA on every surface it is painted on', () {
    themes.forEach((name, c) {
      final surfaces = {'bg': c.bg, 'card': c.card, 'cardElev': c.cardElev};

      surfaces.forEach((surfaceName, surface) {
        test('$name — ink on $surfaceName', () {
          expect(
            _contrast(c.ink, surface),
            greaterThanOrEqualTo(_aaNormal),
            reason: 'primary text must be readable on $surfaceName',
          );
        });

        test('$name — ink2 on $surfaceName', () {
          expect(
            _contrast(c.ink2, surface),
            greaterThanOrEqualTo(_aaNormal),
            reason: 'secondary text carries real content, not decoration',
          );
        });
      });
    });
  });

  // Tonal strips: coloured ink on that same colour's fill. This is the exact
  // shape that failed by hand.
  group('tonal fills carry legible ink', () {
    themes.forEach((name, c) {
      final pairs = {
        'warm on warmFill': (c.warm, _composite(c.warmFill, c.card)),
        'good on goodFill': (c.good, _composite(c.goodFill, c.card)),
        'danger on dangerFill': (c.danger, _composite(c.dangerFill, c.card)),
        'accent on accentFill': (c.accent, _composite(c.accentFill, c.card)),
        'ink2 on warmFill': (c.ink2, _composite(c.warmFill, c.card)),
        // UgamButtonKind.tonal's lettering. It used to be `accent`, which only
        // just cleared AA in Daylight (4.57:1); the accent-rationing law
        // ("this is yours" is a meaning, not a control) retired it in favour of
        // full-contrast ink. Guarded on `cardElev`, the darkest surface a tonal
        // button is placed on and therefore the worst case in Midnight.
        'ink on accentFill (tonal button)': (
          c.ink,
          _composite(c.accentFill, c.cardElev),
        ),
      };

      pairs.forEach((pairName, pair) {
        test('$name — $pairName', () {
          expect(
            _contrast(pair.$1, pair.$2),
            greaterThanOrEqualTo(_aaNormal),
            reason: '$pairName is used for text, so it owes AA',
          );
        });
      });
    });
  });

  group('ink on solid action surfaces', () {
    themes.forEach((name, c) {
      test('$name — onAction on action', () {
        expect(_contrast(c.onAction, c.action), greaterThanOrEqualTo(_aaNormal));
      });
      test('$name — onAccent on accent', () {
        expect(_contrast(c.onAccent, c.accent), greaterThanOrEqualTo(_aaNormal));
      });
    });
  });
}
