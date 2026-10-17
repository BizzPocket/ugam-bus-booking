part of '../tour_detail_screen.dart';

// ─── IDENTITY HEADER / STICKY CHROME / TAB STRIP ──────────────────────

/// Sticky bar shown once the identity header has scrolled away — on every tab,
/// for every tour. Carries the tab strip too, so a 52-rider roster never traps
/// the user: back and all five tabs stay one tap away at any scroll depth.
///
/// Deliberately carries no photo thumbnail: the bar is chrome, and chrome that
/// changes shape per tour is what this screen was being fixed for.
class _CollapsedTourChrome extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  /// The same [_TabBar] the page renders in place. It appears here exactly as
  /// the in-place strip reaches the top edge, so the two never show at once.
  final Widget tabs;
  final VoidCallback onBack;
  final VoidCallback onMore;

  const _CollapsedTourChrome({
    super.key,
    required this.tour,
    required this.c,
    required this.tabs,
    required this.onBack,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    // `viewPaddingOf`: the physical status-bar / cutout inset, which is what
    // chrome has to sit below. `padding` collapses to zero the moment a
    // `viewInset` covers that edge, and it costs a rebuild on every unrelated
    // MediaQuery change; this reads one metric and never lies about the notch.
    final top = MediaQuery.viewPaddingOf(context).top;
    return Material(
      color: c.bg.withValues(alpha: 0.96),
      elevation: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          top + UgamSpacing.sm,
          UgamSpacing.gutter,
          UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                UgamIconButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: onBack,
                  semanticLabel: tr('app.action.back'),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        tour.title,
                        style: UgamText.titleS.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      UgamStatusDot(
                        label: tour.status.displayName,
                        tone: _toneFor(tour.status),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                UgamIconButton(
                  icon: Icons.more_vert_rounded,
                  onTap: onMore,
                  semanticLabel: tr('tour_detail.actions_title'),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm),
            tabs,
          ],
        ),
      ),
    );
  }
}

// ─── IDENTITY HEADER ──────────────────────────────────────────────────

/// The one and only tour header. Chrome row, title, route, status, live
/// vitals, seat badge — identical on all five tabs, so the screen keeps the
/// same identity wherever the user is working.
class _TourIdentityHeader extends StatelessWidget {
  final Tour tour;
  final VoidCallback onBack;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TourIdentityHeader({
    required this.tour,
    required this.onBack,
    required this.onEdit,
    required this.onDelete,
  });

  /// Bottom sheet of tour-level actions (edit / delete), opened from the single
  /// overflow chrome circle so the header stays uncluttered.
  void _showActions(BuildContext context) {
    final c = UgamColors.of(context);
    UgamSheet.show<void>(
      context,
      title: tr('tour_detail.actions_title'),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HeroActionRow(
            icon: Icons.edit_rounded,
            label: tr('tour_detail.edit_tour'),
            c: c,
            onTap: () {
              // Close the actions sheet on the correct navigator (it may sit on
              // a nested tab navigator — see BUG-002), then run edit.
              AppNav.pop(ctx);
              onEdit();
            },
          ),
          const SizedBox(height: UgamSpacing.sm),
          _HeroActionRow(
            icon: Icons.delete_outline_rounded,
            label: tr('tour_detail.delete_tour'),
            c: c,
            danger: true,
            onTap: () {
              // Same nested-navigator-safe close before the delete confirm.
              AppNav.pop(ctx);
              onDelete();
            },
          ),
        ],
      ),
    );
  }

  /// No illustration — just chrome + tour identity, so the tabbed body
  /// reclaims the ~200px the old backdrop spent on a photo or a generated
  /// glyph. Status shows once (the status dot in the identity block), so no
  /// extra chip in the chrome row.
  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Same reasoning as the sticky bar's inset — see [_CollapsedTourChrome].
    // The scrim painted over this strip by the screen's Stack is what stops
    // the chrome colliding with the clock ONCE THE PAGE MOVES; this keeps it
    // clear at rest.
    final topInset = MediaQuery.viewPaddingOf(context).top;
    final statusTone = _toneFor(tour.status);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        topInset + UgamSpacing.sm,
        UgamSpacing.gutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              UgamIconButton(
                icon: Icons.arrow_back_rounded,
                onTap: onBack,
                semanticLabel: tr('app.action.back'),
              ),
              const Spacer(),
              UgamIconButton(
                icon: Icons.more_vert_rounded,
                onTap: () => _showActions(context),
                semanticLabel: tr('tour_detail.actions_title'),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tour.title,
                      style: UgamText.titleL.copyWith(color: c.ink),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.south_east_rounded, size: 13, color: c.ink2),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${tour.fromCity} → ${tour.toCity}',
                            style: UgamText.caption.copyWith(color: c.ink2),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: UgamSpacing.sm),
                        Text('·',
                            style: UgamText.caption.copyWith(color: c.ink3)),
                        const SizedBox(width: UgamSpacing.sm),
                        Text(
                          _durationLabel(context, tour),
                          style: UgamText.tabular(
                            UgamText.caption.copyWith(color: c.ink2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    UgamStatusDot(
                      label: tour.status.description,
                      tone: statusTone,
                    ),
                    // Live "how's this tour doing" vitals — seats filled +
                    // rider count — so the agent reads progress at a glance
                    // without drilling into Seats/Passengers.
                    _HeroVitals(tour: tour, c: c),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              TourHeroChipBadge(tour: tour, c: c),
            ],
          ),
        ],
      ),
    );
  }

  String _durationLabel(BuildContext context, Tour t) {
    final r = t.returnDate;
    final locale = context.locale.toString();
    if (r == null) {
      return Formatters.formatDateShort(t.departureDate, locale: locale);
    }
    final days = r.difference(t.departureDate).inDays + 1;
    return days == 1
        ? tr('tour_detail.duration_day_one')
        : tr('tour_detail.duration_day_other', namedArgs: {'n': '$days'});
  }
}

/// A full-width tappable row inside the hero actions sheet (icon square +
/// label). `danger` tints it with the destructive colour for Delete.
class _HeroActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final UgamColorSet c;
  final VoidCallback onTap;
  final bool danger;

  const _HeroActionRow({
    required this.icon,
    required this.label,
    required this.c,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    // Neutral medallion, matching [_TourToolRow]'s un-highlighted rows — this
    // sheet and that list are the same anatomy and used to disagree. A copper
    // square behind "Edit" / "Message" / "Call" is decoration: none of those
    // rows is a thing the user OWNS or has SELECTED, which is the accent's
    // only job. Danger keeps its tint, because destructive IS a state.
    final fg = danger ? c.danger : c.ink;
    final fill = danger ? c.dangerFill : c.card;
    return UgamTappable(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      semanticLabel: label,
      haptic: false,
      child: Container(
        // One anatomy = one height: this matches _TourToolRow's fixed 56 so the
        // sheet's rows don't read airier than the Overview tool rows behind it.
        height: UgamScale.tap(context, 56),
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            Container(
              width: UgamScale.px(context, 40),
              height: UgamScale.px(context, 40),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: UgamScale.px(context, 19), color: fg),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                label,
                style: UgamText.titleS.copyWith(color: fg, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── TAB BAR ──────────────────────────────────────────────────────────

class _TabBar extends StatelessWidget {
  final int index;
  final List<int?> counts;
  final ValueChanged<int> onChanged;

  const _TabBar({
    required this.index,
    required this.counts,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final labels = [
      tr('tour_detail.tab_overview'),
      tr('tour_detail.tab_passengers'),
      tr('tour_detail.tab_buses'),
      tr('tour_detail.tab_money'),
      tr('tour_detail.tab_activity'),
    ];
    return UgamTabPills(
      currentIndex: index,
      onChanged: onChanged,
      items: List.generate(labels.length, (i) {
        return UgamTabItem(label: labels[i], count: counts[i]);
      }),
    );
  }
}
