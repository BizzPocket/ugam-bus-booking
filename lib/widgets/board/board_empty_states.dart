/// The Board's per-lens empty and zero states — spec §13 of
/// `docs/superpowers/specs/2026-08-12-board-interaction-design.md`.
///
/// **The rule this file exists to enforce: an empty state that names a problem
/// and offers no way out is a bug.** The audit found that shape all over this
/// app — the chart says "this bus has no seat layout yet" and stops there, with
/// a ten-row colour key floating above the seats that do not exist; the finance
/// screen paints ₹0 into every cell of a tour whose fares were never set, so a
/// working tour reads exactly like a broken one. Both are honest sentences and
/// neither is usable.
///
/// So every state modelled here carries a [BoardEmptyAction]. It is required by
/// the constructor, in the same spirit as [BerthPaint]'s non-empty glyph: the
/// rule is enforced by the type rather than by review.
///
/// **The second rule: "no data yet" and "genuinely zero" are different
/// situations and must not look the same.** ₹0 outstanding because nobody set a
/// fare is a setup step; ₹0 outstanding because the handler collected every
/// rupee is a finished job. Today both render as a blank. Here they are split
/// three ways by [BoardEmptyKind], and the two halves do not even use the same
/// presentation:
///
///  * [BoardEmptyKind.missing] and [BoardEmptyKind.notYet] REPLACE the canvas
///    ([BoardEmptyState.replacesChart]) — there is nothing to draw, so the
///    legend and the summary strip must be suppressed with it.
///  * [BoardEmptyKind.allClear] sits ABOVE a canvas that still draws, as a
///    compact [BoardZeroNote]. The chart of green berths is the evidence; the
///    note only says that the zero is the good kind.
///
/// Nothing in this file navigates. Each state names its action as an enum value
/// and the host wires it, because the destinations need a `Tour`/`Bus` this
/// widget deliberately does not take. The REAL destinations, found in the
/// codebase rather than invented, are documented on [BoardEmptyAction].
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../design/components/ugam_button.dart';
import '../../design/text_styles.dart';
import '../../design/tokens.dart';
import '../../design/ui_scale.dart';
import '../../models/board_lens.dart';
import '../../models/collection.dart';
import '../../utils/formatters.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Kind — the whole point of the file.
// ─────────────────────────────────────────────────────────────────────────────

/// Which of the three genuinely different "there is nothing here" situations
/// this is.
///
/// The distinction is carried by the eyebrow word on every panel, NOT by
/// colour: [missing] and [notYet] are the same neutral tone on purpose, because
/// nothing is wrong in either, and the thing that actually differs between them
/// is whether the handler has something to fix right now.
enum BoardEmptyKind {
  /// A prerequisite does not exist yet — no seat plan, no fares, no stops. The
  /// action FIXES it, so it is offered at [UgamButtonKind.tonal] weight.
  missing,

  /// The data will exist; the moment has not come. Boarding before departure
  /// day. Nothing is broken and nothing is required, so the action is a
  /// preview at [UgamButtonKind.neutral] weight.
  notYet,

  /// Genuinely zero, and that is the good answer: every rupee collected, every
  /// head counted. Never replaces the chart.
  allClear;

  /// The micro-label above the title. Uppercased at the call site, which is a
  /// no-op in Gujarati and Hindi (neither script has case) and gives English
  /// the section-eyebrow look the type scale is built for.
  String get eyebrow {
    switch (this) {
      case BoardEmptyKind.missing:
        return tr('board_empty.kind_missing');
      case BoardEmptyKind.notYet:
        return tr('board_empty.kind_not_yet');
      case BoardEmptyKind.allClear:
        return tr('board_empty.kind_all_clear');
    }
  }
}

/// The way out of an empty state.
///
/// Every value here has a destination that ALREADY EXISTS. None of them is a
/// route invented for the Board:
///
///  * [createSeatPlan] → `AddBusScreen(tourId: tour.id, existing: bus)`. The
///    layout is generated in exactly one place in the app — `BusLayout.generate`
///    on that wizard's save path, driven by its Step 2 capacity inputs — which
///    is why `charts_screen._createLayout` opens the same screen rather than a
///    layout editor. There is no standalone seat-plan editor to point at.
///  * [setFares] → the SAME wizard, Step 3 (`_price`, `_singleSofaPrice`,
///    `_doubleSofaPrice`, `priceBands`). Per-bus fares live on
///    `Bus.pricePerSeat` / `Bus.priceBands` and seed from `Tour.pricePerSeat`.
///    `AddBusScreen` has no "open at step N" parameter today — see the file's
///    reported gaps.
///  * [addPickupPoints] → `AppRoutes.pickupLocations`
///    (`PickupLocationsScreen`), the admin home for the global
///    `pickup_locations` list every tour draws from.
///  * [createGroup] → `AppRoutes.tourGroups` today. Once spec §7's long-press
///    multi-select lands, the Board makes groups itself and this becomes an
///    in-Board hint rather than a push.
///  * [placeRiders] → `AppRoutes.seatAssignment` with `{tourId, busId}`, or —
///    preferably, once the assignment walk is wired — the Board's own
///    "next empty berth" advance (spec §4).
///  * [previewExpected] → in-Board: switch to [BoardLensId.occupancy], which
///    shows exactly who is on the bus without leaving the canvas. No push.
///  * [reviewCollection] → `AppRoutes.tourMoney` (`TourMoneyBoardScreen`).
enum BoardEmptyAction {
  createSeatPlan,
  placeRiders,
  setFares,
  reviewCollection,
  previewExpected,
  addPickupPoints,
  createGroup;

  String get label {
    switch (this) {
      case BoardEmptyAction.createSeatPlan:
        return tr('board_empty.action_create_seat_plan');
      case BoardEmptyAction.placeRiders:
        return tr('board_empty.action_place_riders');
      case BoardEmptyAction.setFares:
        return tr('board_empty.action_set_fares');
      case BoardEmptyAction.reviewCollection:
        return tr('board_empty.action_review_collection');
      case BoardEmptyAction.previewExpected:
        return tr('board_empty.action_preview_expected');
      case BoardEmptyAction.addPickupPoints:
        return tr('board_empty.action_add_pickup_points');
      case BoardEmptyAction.createGroup:
        return tr('board_empty.action_create_group');
    }
  }

  IconData get icon {
    switch (this) {
      case BoardEmptyAction.createSeatPlan:
        return Icons.grid_view_rounded;
      case BoardEmptyAction.placeRiders:
        return Icons.person_add_alt_1_rounded;
      case BoardEmptyAction.setFares:
        return Icons.currency_rupee_rounded;
      case BoardEmptyAction.reviewCollection:
        return Icons.account_balance_wallet_outlined;
      case BoardEmptyAction.previewExpected:
        return Icons.visibility_outlined;
      case BoardEmptyAction.addPickupPoints:
        return Icons.add_location_alt_outlined;
      case BoardEmptyAction.createGroup:
        return Icons.group_add_outlined;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The state itself.
// ─────────────────────────────────────────────────────────────────────────────

/// One number worth previewing while the lens itself has nothing to draw — the
/// "expected headcount" spec §13 asks the boarding lens to show before
/// departure day.
@immutable
class BoardEmptyFact {
  /// Already formatted and already localised.
  final String value;

  final String label;

  const BoardEmptyFact({required this.value, required this.label});

  @override
  bool operator ==(Object other) =>
      other is BoardEmptyFact && other.value == value && other.label == label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// A resolved empty / zero state: what happened, what to say about it, and the
/// one action that gets out of it.
@immutable
class BoardEmptyState {
  /// Stable, never shown. Tests and analytics key off this rather than off a
  /// translated title.
  final String id;

  final BoardEmptyKind kind;

  /// The lens this state belongs to, or null when it applies to every lens
  /// (a bus with no seat plan has nothing for ANY lens to colour).
  final BoardLensId? lens;

  final IconData icon;
  final String title;
  final String body;
  final BoardEmptyAction action;

  /// Optional preview numbers rendered between the body and the action.
  final List<BoardEmptyFact> facts;

  const BoardEmptyState({
    required this.id,
    required this.kind,
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    this.lens,
    this.facts = const [],
  }) : assert(title != '', 'an empty state must name what is missing'),
       // The rule the whole file exists for. `action` is non-nullable, so this
       // only has to guard the degenerate case.
       assert(body != '', 'an empty state must explain itself');

  /// True when this state stands INSTEAD of the chart, and therefore when the
  /// host must also suppress the legend and the summary strip — spec §13's
  /// *"never render a legend for berths that do not exist"*. False for
  /// [BoardEmptyKind.allClear], which annotates a chart that still draws.
  bool get replacesChart => kind != BoardEmptyKind.allClear;

  @override
  String toString() => 'BoardEmptyState($id, ${kind.name})';
}

// ─────────────────────────────────────────────────────────────────────────────
// Facts in — the resolver's only input.
// ─────────────────────────────────────────────────────────────────────────────

/// Everything the resolver needs, as a flat value type with no `Tour`, `Bus` or
/// controller inside it, so every branch below is provable in a unit test.
@immutable
class BoardEmptyFacts {
  /// False while the bus's layout is still in flight.
  ///
  /// `layout == null` is AMBIGUOUS on its own — cold start ships buses without
  /// their grids to save 2G bytes — so it means either "still loading" or "this
  /// bus genuinely has no seat map. Answering the second while the first is
  /// true is how the old chart showed an empty-bus dead end over 36 seated
  /// riders. While this is false the resolver returns null and the host shows
  /// its skeleton.
  final bool loaded;

  /// Whether this bus has a seat plan at all.
  final bool hasLayout;

  /// The berths on the bus currently shown. Same input [BoardLegend] takes, so
  /// the two can never disagree about whether there is a bus to describe.
  final List<BoardBerth> berths;

  /// Days from now until departure, or null when unknown. Positive means the
  /// bus has not left the depot — the one fact [HandlerPhase] cannot express,
  /// and the trigger for the boarding lens's "not yet" state.
  final int? daysUntilDeparture;

  /// Used only to print "boarding opens on 14 Aug". Null falls back to a
  /// dateless phrasing rather than to a fake date.
  final DateTime? departureDate;

  /// `context.locale.languageCode`, so the month name follows the app locale.
  final String? locale;

  const BoardEmptyFacts({
    this.loaded = true,
    this.hasLayout = true,
    this.berths = const [],
    this.daysUntilDeparture,
    this.departureDate,
    this.locale,
  });

  Iterable<BoardBerth> get _riders => berths.where((b) => b.isOccupied);

  /// Riders on this bus. The headcount every lens but occupancy needs before it
  /// has anything to say.
  int get riderCount => _riders.length;

  /// Whether ANY rider has a fare or a payment against them. False is the
  /// finance-screen failure: a whole bus of ₹0 that reads as broken.
  ///
  /// Partial pricing (some berths priced, some comped) is deliberately NOT an
  /// empty state — the money lens paints those `—` and the chart is the better
  /// answer than a panel over the top of it.
  bool get hasFares => _riders.any((b) => b.money != BerthMoney.none);

  double get outstanding =>
      _riders.fold<double>(0, (sum, b) => sum + b.outstanding);

  double get collected => _riders.fold<double>(0, (sum, b) => sum + b.paid);

  int get boardedCount =>
      _riders.where((b) => b.boarding == BerthBoarding.boarded).length;

  /// Distinct pickup points actually recorded against riders. Zero is spec
  /// §13's "pickup lens, no stops configured".
  int get stopCount => _riders
      .map((b) => b.pickupStopId)
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet()
      .length;

  int get groupCount => _riders
      .map((b) => b.groupId)
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet()
      .length;

  /// Before departure day, per spec §6's T-2d reading of the same number.
  bool get beforeDepartureDay =>
      daysUntilDeparture != null && daysUntilDeparture! > 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// The resolver — pure, and the whole of spec §13's decision table.
// ─────────────────────────────────────────────────────────────────────────────

/// The state to show for [lens], or **null when the Board should just draw the
/// chart**.
///
/// Order matters and is deliberate:
///
///  1. still loading → nothing, ever. A panel that says "no seat plan" over a
///     bus whose plan is one frame away is worse than a skeleton.
///  2. no seat plan → the same answer under every lens; nothing else can be
///     true yet.
///  3. no riders → every lens EXCEPT occupancy. An empty bus under the
///     occupancy lens is not an empty state at all: the grid of `—` berths IS
///     the tool you place people with, and covering it with a panel would take
///     away the one screen that could fix the problem.
///  4. the lens's own prerequisite (fares / stops / groups / departure day).
///  5. genuinely zero, if the lens has a positive completion to report.
BoardEmptyState? resolveBoardEmptyState({
  required BoardLensId lens,
  required BoardEmptyFacts facts,
}) {
  if (!facts.loaded) return null;

  if (!facts.hasLayout || facts.berths.isEmpty) {
    return BoardEmptyState(
      id: 'no_layout',
      kind: BoardEmptyKind.missing,
      icon: Icons.event_seat_outlined,
      title: tr('board_empty.no_layout_title'),
      body: tr('board_empty.no_layout_body'),
      action: BoardEmptyAction.createSeatPlan,
    );
  }

  if (lens == BoardLensId.occupancy) {
    // The occupancy lens is never empty while a plan exists — see rule 3.
    return null;
  }

  if (facts.riderCount == 0) {
    return BoardEmptyState(
      id: 'no_riders',
      kind: BoardEmptyKind.missing,
      lens: lens,
      icon: Icons.people_outline_rounded,
      title: tr('board_empty.no_riders_title'),
      body: tr('board_empty.no_riders_body'),
      action: BoardEmptyAction.placeRiders,
    );
  }

  switch (lens) {
    case BoardLensId.occupancy:
      return null;

    case BoardLensId.money:
      if (!facts.hasFares) {
        return BoardEmptyState(
          id: 'no_fares',
          kind: BoardEmptyKind.missing,
          lens: lens,
          icon: Icons.payments_outlined,
          title: tr('board_empty.no_fares_title'),
          body: tr('board_empty.no_fares_body'),
          action: BoardEmptyAction.setFares,
        );
      }
      if (facts.outstanding <= Collection.kMoneyEpsilon) {
        return BoardEmptyState(
          id: 'all_collected',
          kind: BoardEmptyKind.allClear,
          lens: lens,
          icon: Icons.check_circle_outline_rounded,
          title: tr('board_empty.all_collected_title'),
          body: tr(
            'board_empty.all_collected_body',
            namedArgs: {
              'count': '${facts.riderCount}',
              'amount': Formatters.formatMoneyInrCompact(facts.collected),
            },
          ),
          action: BoardEmptyAction.reviewCollection,
        );
      }
      return null;

    case BoardLensId.boarding:
      if (facts.beforeDepartureDay) {
        final date = facts.departureDate;
        return BoardEmptyState(
          id: 'boarding_not_open',
          kind: BoardEmptyKind.notYet,
          lens: lens,
          icon: Icons.event_outlined,
          title: date == null
              ? tr('board_empty.boarding_not_open_title_no_date')
              : tr(
                  'board_empty.boarding_not_open_title',
                  namedArgs: {'date': _shortDate(date, facts.locale)},
                ),
          body: tr('board_empty.boarding_not_open_body'),
          // Spec §13 asks this one for a preview of the expected headcount, so
          // the panel is not just a closed door: the handler still learns how
          // many people and how many stops they are walking into.
          facts: [
            BoardEmptyFact(
              value: '${facts.riderCount}',
              label: tr('board_empty.preview_expected'),
            ),
            if (facts.stopCount > 0)
              BoardEmptyFact(
                value: '${facts.stopCount}',
                label: tr('board_empty.preview_stops'),
              ),
          ],
          action: BoardEmptyAction.previewExpected,
        );
      }
      if (facts.boardedCount >= facts.riderCount) {
        return BoardEmptyState(
          id: 'all_boarded',
          kind: BoardEmptyKind.allClear,
          lens: lens,
          icon: Icons.how_to_reg_outlined,
          title: tr('board_empty.all_boarded_title'),
          body: tr(
            'board_empty.all_boarded_body',
            namedArgs: {
              'done': '${facts.boardedCount}',
              'total': '${facts.riderCount}',
            },
          ),
          action: BoardEmptyAction.reviewCollection,
        );
      }
      return null;

    case BoardLensId.pickup:
      if (facts.stopCount == 0) {
        return BoardEmptyState(
          id: 'no_stops',
          kind: BoardEmptyKind.missing,
          lens: lens,
          icon: Icons.place_outlined,
          title: tr('board_empty.no_stops_title'),
          body: tr('board_empty.no_stops_body'),
          action: BoardEmptyAction.addPickupPoints,
        );
      }
      return null;

    case BoardLensId.group:
      if (facts.groupCount == 0) {
        return BoardEmptyState(
          id: 'no_groups',
          kind: BoardEmptyKind.missing,
          lens: lens,
          icon: Icons.groups_outlined,
          title: tr('board_empty.no_groups_title'),
          body: tr('board_empty.no_groups_body'),
          action: BoardEmptyAction.createGroup,
        );
      }
      return null;
  }
}

/// Localised `14 Aug`, falling back to the default locale rather than throwing.
///
/// `initializeDateFormatting()` runs in `main`, but a Board that crashed
/// because a month name was unavailable would be a spectacularly bad way to
/// fail an EMPTY state — the one screen whose whole job is to survive missing
/// data.
String _shortDate(DateTime date, String? locale) {
  try {
    return Formatters.formatDateShort(date, locale: locale);
  } catch (_) {
    return Formatters.formatDateShort(date);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Presentation.
// ─────────────────────────────────────────────────────────────────────────────

/// Medallion behind the state's icon. Decorative, so it scales with [UgamScale]
/// rather than being floored at a tap size.
const double _kMedallion = 56;
const double _kMedallionIcon = 26;
const double _kNoteMedallion = 32;
const double _kNoteIcon = 18;

/// The panel never stretches to the full width of a landscape phone — spec §3
/// makes landscape first-class, and a title stretched across 800pt reads as a
/// banner, not as a message.
const double _kPanelMaxWidth = 420;

/// Above this the zero note puts its action beside the text instead of under
/// it. Vertical space is the scarce one in landscape.
const double _kNoteRowBreakpoint = 420;

/// A full-bleed empty state that stands INSTEAD of the chart.
///
/// Deliberately not built on [UgamEmpty] even though it is the same family of
/// object, for three reasons that all matter here: this one carries a kind
/// eyebrow (the only signal separating "set up" from "not yet", and it is a
/// word, not a colour), it carries the preview facts spec §13 asks the boarding
/// state for, and its body is not capped at two lines — Gujarati is the primary
/// language and runs ~30% longer, so a two-line clamp truncates exactly the
/// sentence that explains the way out.
class BoardEmptyPanel extends StatelessWidget {
  final BoardEmptyState state;

  /// Fires with [BoardEmptyState.action]. The host owns the destination; see
  /// [BoardEmptyAction] for the real one behind each value.
  final ValueChanged<BoardEmptyAction> onAction;

  final EdgeInsetsGeometry padding;

  const BoardEmptyPanel({
    super.key,
    required this.state,
    required this.onAction,
    this.padding = const EdgeInsets.symmetric(
      horizontal: UgamSpacing.huge,
      vertical: UgamSpacing.huge2,
    ),
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final allClear = state.kind == BoardEmptyKind.allClear;
    final medallionFill = allClear ? c.goodFill : c.cardElev;
    final iconInk = allClear
        ? c.good
        : (state.kind == BoardEmptyKind.missing ? c.ink2 : c.ink3);

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: padding,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kPanelMaxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: UgamScale.px(context, _kMedallion),
                  height: UgamScale.px(context, _kMedallion),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: medallionFill,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.border),
                  ),
                  child: Icon(
                    state.icon,
                    size: UgamScale.px(context, _kMedallionIcon),
                    color: iconInk,
                  ),
                ),
                const SizedBox(height: UgamSpacing.lg),
                // One screen-reader node for the message: eyebrow, then title,
                // then body, then any preview numbers — the same order a
                // sighted user reads them in.
                MergeSemantics(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state.kind.eyebrow.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: UgamText.micro.copyWith(
                          color: allClear ? c.good : c.ink3,
                        ),
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      Text(
                        state.title,
                        textAlign: TextAlign.center,
                        style: UgamText.titleM.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      Text(
                        state.body,
                        textAlign: TextAlign.center,
                        style: UgamText.body.copyWith(color: c.ink2),
                      ),
                      if (state.facts.isNotEmpty) ...[
                        const SizedBox(height: UgamSpacing.lg),
                        _FactRow(facts: state.facts),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: UgamSpacing.xl),
                UgamButton(
                  label: state.action.label,
                  icon: state.action.icon,
                  // A missing prerequisite is the thing to do next, so it takes
                  // the quiet-primary tonal weight; a "not yet" state is only
                  // offering a look ahead and must not compete with it.
                  kind: state.kind == BoardEmptyKind.missing
                      ? UgamButtonKind.tonal
                      : UgamButtonKind.neutral,
                  onPressed: () => onAction(state.action),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The preview numbers. A [Wrap], not a [Row]: two Gujarati labels side by side
/// on a 360pt phone are wider than they look in English.
class _FactRow extends StatelessWidget {
  final List<BoardEmptyFact> facts;

  const _FactRow({required this.facts});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: UgamSpacing.lg,
      runSpacing: UgamSpacing.sm,
      children: [
        for (final fact in facts)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fact.value, style: UgamText.numLg.copyWith(color: c.ink)),
              const SizedBox(height: UgamSpacing.xs),
              Text(
                fact.label,
                style: UgamText.caption.copyWith(color: c.ink3),
              ),
            ],
          ),
      ],
    );
  }
}

/// The **genuinely zero** state: a compact note pinned above a chart that still
/// draws.
///
/// This is the half of spec §13 the app gets wrong in the other direction. When
/// every rupee is in, the money lens is a bus of green ticks and a ₹0 total —
/// visually indistinguishable from a tour whose fares were never set. The note
/// says which of the two it is, in one line, without taking the chart away.
class BoardZeroNote extends StatelessWidget {
  final BoardEmptyState state;
  final ValueChanged<BoardEmptyAction> onAction;
  final EdgeInsetsGeometry margin;

  const BoardZeroNote({
    super.key,
    required this.state,
    required this.onAction,
    this.margin = const EdgeInsets.symmetric(
      horizontal: UgamSpacing.gutter,
      vertical: UgamSpacing.sm,
    ),
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final text = MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            state.title,
            style: UgamText.bodyStrong.copyWith(color: c.ink),
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            state.body,
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
        ],
      ),
    );

    final button = UgamButton(
      label: state.action.label,
      kind: UgamButtonKind.ghost,
      onPressed: () => onAction(state.action),
    );

    return Padding(
      padding: margin,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.goodFill,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          // The tonal fill alone is a colour-only signal; the hairline plus the
          // tick glyph carry the same "this is settled" meaning without it.
          border: Border.all(color: c.good.withValues(alpha: 0.28)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _kNoteRowBreakpoint;
            final head = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: UgamScale.px(context, _kNoteMedallion),
                  height: UgamScale.px(context, _kNoteMedallion),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.good.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    state.icon,
                    size: UgamScale.px(context, _kNoteIcon),
                    color: c.good,
                  ),
                ),
                const SizedBox(width: UgamSpacing.md),
                Expanded(child: text),
                if (wide) ...[const SizedBox(width: UgamSpacing.md), button],
              ],
            );

            if (wide) return head;
            // Narrow: the action drops to its own line rather than squeezing
            // the Gujarati title into an ellipsis.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                head,
                const SizedBox(height: UgamSpacing.sm),
                button,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The one integration point: wraps the canvas and decides what the Board shows.
///
/// ```dart
/// BoardEmptyStates(
///   lens: controller.lens,
///   facts: BoardEmptyFacts(
///     loaded: page.loaded,
///     hasLayout: page.layout != null,
///     berths: berths,
///     daysUntilDeparture: controller.daysUntilDeparture.value,
///     departureDate: tour.departureDate,
///     locale: context.locale.languageCode,
///   ),
///   onAction: _handleEmptyAction,
///   child: BoardCanvas(...),
/// )
/// ```
///
/// **The host still owns the chrome.** When [resolveBoardEmptyState] returns a
/// state whose [BoardEmptyState.replacesChart] is true, the legend and the
/// summary strip must be hidden too — spec §13's *"never render a legend for
/// berths that do not exist"*. This widget only owns the canvas slot it was
/// given, so it cannot do that for you; call [boardEmptyReplacesChart] with the
/// same lens and facts where the chrome is built.
class BoardEmptyStates extends StatelessWidget {
  final BoardLensId lens;
  final BoardEmptyFacts facts;
  final ValueChanged<BoardEmptyAction> onAction;

  /// The canvas. Drawn whenever there is a bus worth drawing — which includes
  /// every [BoardEmptyKind.allClear] state.
  final Widget child;

  const BoardEmptyStates({
    super.key,
    required this.lens,
    required this.facts,
    required this.onAction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final state = resolveBoardEmptyState(lens: lens, facts: facts);
    if (state == null) return child;
    if (state.replacesChart) {
      return BoardEmptyPanel(state: state, onAction: onAction);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BoardZeroNote(state: state, onAction: onAction),
        Flexible(child: child),
      ],
    );
  }
}

/// Whether the Board is about to replace its canvas, and therefore whether the
/// legend, the summary strip and the "next outstanding" control should be
/// suppressed with it. Cheap enough to call from the chrome builder.
bool boardEmptyReplacesChart({
  required BoardLensId lens,
  required BoardEmptyFacts facts,
}) =>
    resolveBoardEmptyState(lens: lens, facts: facts)?.replacesChart ?? false;
