part of '../collection_screen.dart';

class _SummaryHeader extends StatelessWidget {
  final double collected;
  final double toReturn;
  final double toCollect;

  const _SummaryHeader({
    required this.collected,
    required this.toReturn,
    required this.toCollect,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final settled = toCollect.abs() <= 0.005;
    // Outstanding cash is a semantic state (danger — "something needs you"),
    // not an ownership. Matches the live pill inside the collect sheet, so the
    // header figure and the sheet agree on what red means.
    final figureColor = settled ? c.good : c.danger;

    // ── ONE compact summary card ───────────────────────────────────────
    // Hero = the action number (still to collect); collected / to-return are
    // quiet inline chips on the row below, no longer a separate stat grid.
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Decorative leading glyph tile — [UgamScale.px], so it tracks
              // the label text beside it instead of staying chunky at full
              // size while that text shrinks on a narrow phone.
              Container(
                width: UgamScale.px(context, 42),
                height: UgamScale.px(context, 42),
                decoration: BoxDecoration(
                  color: settled ? c.goodFill : c.dangerFill,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.account_balance_wallet_rounded,
                  size: UgamScale.px(context, 20),
                  color: figureColor,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The eyebrow over the screen's hero figure → the
                    // script-safe [UgamText.label] step (Inter 13 / w700 /
                    // zero tracking), not `micro`. This site was the ladder's
                    // worst case in one line: `.toUpperCase()` (a no-op in
                    // Gujarati), a forked `letterSpacing` (tracking splits
                    // conjuncts), and a hand-set w700 on a 10px Sora step that
                    // renders at 8.5 on a small phone. All three are gone; the
                    // emphasis is weight + `ink2`, the one device that
                    // survives a fallback Indic face.
                    Text(
                      tr('collection.filter_to_collect'),
                      style: UgamText.label.copyWith(color: c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UgamSpacing.xs),
                    // LADDER GAP: this was a raw `fontSize: 30`. The numeric
                    // ladder runs numLg 20 → numXl 26 → hero 56, so 30 is not
                    // a step and there is nothing between 26 and 56 for a
                    // "card hero figure". Taken to numXl (26) rather than
                    // hardcoded; if a 30-ish numeric step is wanted it belongs
                    // in UgamText, not here.
                    // scaleDown, not ellipsis: an ellipsised total is a WRONG
                    // total, and this is the number the handler settles on.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        Formatters.formatMoneyInr(toCollect),
                        style: UgamText.tabular(
                          UgamText.numXl.copyWith(color: figureColor),
                        ),
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Divider(height: 1, thickness: 1, color: c.border),
          const SizedBox(height: UgamSpacing.md),
          // ── Demoted pair: inline chips, single row ─────────────────────
          Row(
            children: [
              Expanded(
                child: _SummaryChip(
                  icon: Icons.payments_rounded,
                  label: tr('collection.collected'),
                  value: Formatters.formatMoneyInr(collected),
                  tone: c.good,
                ),
              ),
              const SizedBox(width: UgamSpacing.lg),
              Expanded(
                child: _SummaryChip(
                  icon: Icons.undo_rounded,
                  label: tr('collection.filter_to_return'),
                  value: Formatters.formatMoneyInr(toReturn),
                  tone: c.warm,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One demoted figure inside [_SummaryHeader]: a tinted glyph, a tabular
/// value, and a micro caps label — the inline replacement for the old
/// separate [UgamStatTile] row.
class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color tone;

  const _SummaryChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: tone),
        const SizedBox(width: UgamSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: UgamText.tabular(
                    UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  maxLines: 1,
                ),
              ),
              const SizedBox(height: 1),
              // The label half of a value pair → [captionStrong] (12, the
              // documented script floor), not `micro`, which is Latin-only.
              Text(
                label,
                style: UgamText.captionStrong.copyWith(color: c.ink2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
