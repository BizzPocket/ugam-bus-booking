part of 'passenger_sheet.dart';

IconData _iconFor(BoardAction action) => switch (action) {
  BoardAction.call => Icons.call_rounded,
  BoardAction.collect => Icons.payments_rounded,
  BoardAction.move => Icons.swap_horiz_rounded,
  BoardAction.checkIn => Icons.how_to_reg_rounded,
};

// ─────────────────────────────────────────────────────────────────────────────
// Small parts
// ─────────────────────────────────────────────────────────────────────────────

/// The number, visible and dialable in one tap.
///
/// Visible rather than hidden behind a "Call" button on purpose: a handler at a
/// pickup point often wants to read the number out to somebody, and going back
/// to a list screen to find it is the pattern the Board exists to delete.
class _PhoneRow extends StatelessWidget {
  final String phone;
  final VoidCallback onCall;

  const _PhoneRow({required this.phone, required this.onCall});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final has = phone.isNotEmpty;

    final body = Container(
      constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: has ? c.accentFill : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(
          color: has ? c.accent.withValues(alpha: 0.28) : c.border,
        ),
      ),
      child: Row(
        children: [
          Icon(
            has ? Icons.call_rounded : Icons.phone_disabled_rounded,
            size: UgamScale.px(context, 20),
            color: has ? c.accent : c.ink3,
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              has ? phone : tr('seat_detail.roster.no_mobile'),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: has ? c.ink : c.ink3),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    if (!has) return body;
    return UgamTappable(
      onTap: onCall,
      semanticLabel: tr('seat_detail.call_a11y', namedArgs: {'phone': phone}),
      child: ExcludeSemantics(child: body),
    );
  }
}

/// A state chip that carries its glyph as well as its fill — spec §11's "colour
/// is never the only signal", applied inside the sheet as well as on the tile.
class _GlyphChip extends StatelessWidget {
  final String glyph;
  final String label;
  final Color fill;
  final Color ink;

  /// The chip's own ground. Neutral by default — the glyph and the word carry
  /// the meaning, and a chip per lens state would put five competing colours in
  /// one header. [UgamChipVariant.warm] is used for the one fact that IS a
  /// colour in the app's vocabulary everywhere else: a lady seated here.
  final UgamChipVariant variant;

  const _GlyphChip({
    required this.glyph,
    required this.label,
    required this.fill,
    required this.ink,
    this.variant = UgamChipVariant.neutral,
  });

  @override
  Widget build(BuildContext context) {
    return UgamReqChip(
      label: label.toUpperCase(),
      variant: variant,
      leadingWidget: Text(
        glyph,
        style: UgamText.micro.copyWith(color: ink, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// The rider's note, quoted.
///
/// Same shape as the box `requests_screen` renders on an expanded row, so the
/// one fact that is free text reads the same in both places while both exist.
/// Unlike that one it is NOT clipped to two lines: a note that matters ("uses a
/// wheelchair", "boarding at Kim, not Adajan") is exactly the sentence a
/// truncation would eat the end of.
class _NoteBox extends StatelessWidget {
  final String note;

  const _NoteBox({required this.note});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Semantics(
      container: true,
      label: '${tr('chart.note_label')}: $note',
      child: ExcludeSemantics(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md,
            vertical: UgamSpacing.tight,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.input),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: UgamScale.px(context, 16),
                color: c.ink3,
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  '"$note"',
                  style: UgamText.body.copyWith(
                    color: c.ink2,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One label/value pair. Stacked, not side by side: a Gujarati label runs ~30%
/// longer than its English source and would squeeze the value off the line.
class _Fact extends StatelessWidget {
  final String label;
  final String value;
  final UgamColorSet c;

  const _Fact({required this.label, required this.value, required this.c});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: UgamText.micro.copyWith(color: c.ink3),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: UgamText.bodyStrong.copyWith(color: c.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// A secondary action. Same geometry as the occupant sheet's row so the two
/// read identically while both exist, but built on [UgamTappable] for the
/// press feedback the remediation pass added, and floored at the 44pt target.
class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;

  /// Null renders the row inert AND visibly muted — an action that is not
  /// available must not look tappable.
  final VoidCallback? onTap;

  /// A figure the action carries (the amount to collect, the change to hand
  /// back). Tabular so a column of them lines up.
  final String? trailing;

  final bool danger;
  final bool accent;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.danger = false,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final enabled = onTap != null;
    final fg = !enabled
        ? c.ink3
        : danger
        ? c.danger
        : accent
        ? c.accent
        : c.ink;
    final bg = !enabled
        ? c.card
        : danger
        ? c.dangerFill
        : accent
        ? c.accentFill
        : c.cardElev;

    final body = Container(
      constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        children: [
          Icon(icon, size: UgamScale.px(context, 20), color: fg),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              label,
              style: UgamText.bodyStrong.copyWith(color: fg),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: UgamSpacing.sm),
            Text(
              trailing!,
              style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: fg)),
              maxLines: 1,
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: enabled
          ? UgamTappable(onTap: onTap, child: body)
          : Semantics(enabled: false, child: body),
    );
  }
}
