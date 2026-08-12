import 'dart:async';

import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/board_lens.dart';
import '../models/handler_phase.dart';
import '../models/seat_layout.dart';
import '../utils/aisle_order.dart';

/// How much room one berth tile gets on the Board.
///
/// A real sleeper coach is 36–74 berths, so there is no single tile size that
/// both fits the whole bus on a 375pt phone AND stays tappable. The design
/// (spec §3) answers that with two modes rather than a compromise between them:
///
///   * [compact] — ~20pt, berth code + state glyph only. The whole coach is
///     visible at once. These tiles are deliberately BELOW the 44pt touch
///     minimum: they are for reading, and the tap target is expanded around
///     them rather than the tile being grown to meet it.
///   * [comfortable] — ~44pt, code + occupant name + glyph. The working mode.
///
/// The default is picked from the berth count (see
/// [BoardController.compactBerthThreshold]) and then remembered per user the
/// moment they express a preference.
enum BoardDensity { compact, comfortable }

/// Everything the Board knows about what it is currently SHOWING.
///
/// The Board replaces eleven screens with one canvas and a lens switcher, so
/// the state those screens each kept privately — which colouring is active,
/// which bus, what is filtered, what is selected, where the collection round
/// has got to — has to live in one place or the canvas cannot stay a single
/// canvas. This controller is that place.
///
/// It holds VIEW state only. Berth mutations (assign, move, collect, check in)
/// belong to the passenger sheet and the repositories behind it; nothing here
/// writes to the server, which is why it can be unit-tested with no bindings
/// beyond `SharedPreferences.setMockInitialValues`.
///
/// Two of its fields follow the `HandlerController.legForBoarding` pattern —
/// an explicit user choice held separately from the derived default, with a
/// getter that prefers the choice. That shape is the whole reason a handler who
/// switches to the money lens at 5am does not get yanked back to boarding when
/// the bus departs (spec §6), and the reason a density toggle survives moving
/// to a bigger bus.
class BoardController extends GetxController {
  /// [availableLenses] is which lenses the switcher may offer. It defaults to
  /// [kShippedBoardLenses] on purpose: during the staged build (spec §15) the
  /// other three are modelled in full but have no data source, and a Board that
  /// OPENED on one of them would show an honest-looking chart of nothing.
  BoardController({Set<BoardLensId>? availableLenses}) {
    if (availableLenses != null && availableLenses.isNotEmpty) {
      this.availableLenses.assignAll(availableLenses);
    }
  }

  /// Above this many berths the Board opens compact (spec §3). Exactly 40 is
  /// still comfortable — the rule is "> 40", and the boundary is tested,
  /// because a 40-berth coach that opened compact would put every one of its
  /// tiles under the touch minimum for no reason.
  static const int compactBerthThreshold = 40;

  /// Density is a per-USER preference, not a per-tour one: it describes eyes
  /// and thumbs, which do not change between tours.
  static const String densityPrefKey = 'board_density';

  // ── Phase & lens ──────────────────────────────────────────

  /// Where the bus on screen is in its trip, or null while it is still being
  /// FILLED — [defaultLensForPhase] reads null as exactly that, because
  /// [HandlerPhase] only starts at the depot.
  ///
  /// The shell keeps this in step with `HandlerController.phase`. It lives here
  /// as its own field so the controller stays testable with no manifest, no
  /// network and no handler session behind it.
  final phase = Rxn<HandlerPhase>();

  /// Days from now until departure, or null when unknown. The one fact the
  /// phase cannot express — an un-stamped bus two days out is the money chase,
  /// the same bus on the morning itself is a headcount.
  final daysUntilDeparture = RxnInt();

  /// Which lenses the switcher may offer, and therefore which the default may
  /// resolve to.
  final availableLenses = kShippedBoardLenses.toSet().obs;

  /// The lens the user picked by hand, or null to follow the phase.
  ///
  /// Kept separate from [lens] rather than being overwritten on every phase
  /// change, because those two facts are genuinely different: "the trip has
  /// moved on" must not be allowed to erase "the human told us what they are
  /// doing". Squashing them into one field is how the old screens lost a
  /// handler's place mid-collection.
  final _manualLens = Rxn<BoardLensId>();

  /// The lens actually being rendered.
  ///
  /// Delegates the whole rule to [resolveBoardLens] — spec §6 lives in the
  /// model, in one line, so no screen and no controller can re-derive it
  /// slightly differently and yank the lens out from under the handler on a
  /// rebuild. Every path reads at least one observable, so an enclosing `Obx`
  /// always registers a dependency (GetX throws "improper use of a GetX" on a
  /// closure that reads none).
  BoardLensId get lens => resolveBoardLens(
    phase: phase.value,
    manualChoice: _manualLens.value,
    daysUntilDeparture: daysUntilDeparture.value,
    available: availableLenses,
  );

  /// Whether [lens] is a deliberate choice rather than the phase default. The
  /// switcher uses it to decide whether "auto" should read as active.
  bool get lensIsManual => _manualLens.value != null;

  /// The lens the current phase would open on, ignoring any manual choice.
  BoardLensId get phaseDefaultLens => defaultLensForPhase(
    phase.value,
    daysUntilDeparture: daysUntilDeparture.value,
    available: availableLenses,
  );

  /// The active lens as a built object — its colour function, legend, primary
  /// action and strip metric. [tints] is only read by the pickup and group
  /// lenses, which the shell derives from the berths on screen.
  BoardLens buildLens({BoardTintScale tints = BoardTintScale.empty}) =>
      BoardLens.of(lens, tints: tints);

  void setPhase(HandlerPhase? next) => phase.value = next;

  void setDaysUntilDeparture(int? days) => daysUntilDeparture.value = days;

  /// Widens (or narrows) what the switcher may offer as their data sources
  /// land. Ignores an empty set — a Board with no lenses has nothing to draw.
  void setAvailableLenses(Set<BoardLensId> lenses) {
    if (lenses.isEmpty) return;
    availableLenses.assignAll(lenses);
  }

  /// Records an explicit lens choice. Pinning happens even when the chosen lens
  /// already equals the phase default — the user having *said* it is the point,
  /// and a later phase change must not undo it. A lens that is not available is
  /// ignored rather than stored, so [lensIsManual] never claims a pin the
  /// resolver would quietly overrule.
  void selectLens(BoardLensId next) {
    if (!availableLenses.contains(next)) return;
    if (_manualLens.value == next) return;
    _manualLens.value = next;
    // Legend ids are lens-scoped ("due" means nothing under the pickup lens),
    // so a stale filter would dim the whole bus against an id no berth can
    // match. Same for the walk cursor: "next outstanding" means a different set
    // of berths under every lens.
    clearLegendFilter();
    resetCursor();
  }

  /// Drops the manual pin and goes back to following the phase.
  void followPhaseLens() {
    if (_manualLens.value == null) return;
    _manualLens.value = null;
    clearLegendFilter();
    resetCursor();
  }

  // ── Density ───────────────────────────────────────────────

  /// The user's remembered density, or null to derive it from [berthCount].
  final _densityChoice = Rxn<BoardDensity>();

  /// Drawable tiles on the bus currently shown — the input to the density
  /// default. Read off the walk so there is exactly one answer to "how big is
  /// this bus", and it is the one the canvas actually draws: a double sofa is
  /// two berths but ONE tile, and it is tiles that have to fit on the screen.
  int get berthCount => walk.value.length;

  /// The density actually in force. Same choice-beats-default shape as [lens].
  BoardDensity get density =>
      _densityChoice.value ??
      (berthCount > compactBerthThreshold
          ? BoardDensity.compact
          : BoardDensity.comfortable);

  bool get densityIsManual => _densityChoice.value != null;

  bool get isCompact => density == BoardDensity.compact;

  /// Persists as a fire-and-forget write: a density toggle must repaint on the
  /// same frame as the tap, and a prefs round-trip is not worth blocking it.
  void setDensity(BoardDensity next) {
    if (_densityChoice.value == next) return;
    _densityChoice.value = next;
    unawaited(_saveDensity(next));
  }

  void toggleDensity() => setDensity(
    density == BoardDensity.compact
        ? BoardDensity.comfortable
        : BoardDensity.compact,
  );

  @override
  void onInit() {
    super.onInit();
    unawaited(loadDensityPreference());
  }

  /// Reads the remembered density.
  ///
  /// Public and awaitable so the shell (and a test) can settle it before the
  /// first paint instead of racing [onInit]'s fire-and-forget call. A stored
  /// value is only applied when no choice has been made SINCE the load started
  /// — otherwise a user who toggled density during the first frame would watch
  /// it snap back to yesterday's setting.
  Future<void> loadDensityPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(densityPrefKey);
      if (stored == null || _densityChoice.value != null) return;
      final match = BoardDensity.values.firstWhereOrNull(
        (d) => d.name == stored,
      );
      if (match != null) _densityChoice.value = match;
    } catch (_) {
      // A prefs failure must never keep the Board off the screen. The
      // berth-count default is a perfectly good answer on its own.
    }
  }

  Future<void> _saveDensity(BoardDensity value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(densityPrefKey, value.name);
    } catch (_) {
      // Losing the preference is survivable; losing the toggle is not, and the
      // in-memory choice already took effect.
    }
  }

  // ── Buses ─────────────────────────────────────────────────

  /// How many buses this tour carries. Never below 1, so [busIndex] always has
  /// a legal slot to sit in.
  final busCount = 1.obs;

  /// Which bus the page view is on. Multi-bus switching is a swipe, not a menu
  /// (spec §3), so this changes constantly and has to be cheap.
  final busIndex = 0.obs;

  bool get isMultiBus => busCount.value > 1;

  void setBusCount(int count) {
    busCount.value = count < 1 ? 1 : count;
    if (busIndex.value > busCount.value - 1) setBusIndex(busCount.value - 1);
  }

  /// Out-of-range values are clamped rather than rejected: a page controller
  /// mid-fling can report an index the tour no longer has.
  void setBusIndex(int index) {
    final next = index.clamp(0, busCount.value - 1);
    if (next == busIndex.value) return;
    busIndex.value = next;
    // A walk cursor and a multi-selection describe berths on the bus you just
    // left. Carrying them across would let a bulk action fire against berth ids
    // that are not even on screen.
    resetCursor();
    clearSelection();
  }

  // ── Legend filter (spec §5) ───────────────────────────────

  /// The [BoardLegendEntry.id] currently acting as a filter, or null for "show
  /// all".
  ///
  /// Held as the id rather than the entry itself: legend rows are rebuilt from
  /// the berths on screen (`legendFor` drops rows nothing matches), so holding
  /// an object would pin a stale copy the moment a berth changed. It survives a
  /// bus swipe on purpose — "show me who still owes" is a question about the
  /// tour, not about one coach — and is cleared by a LENS change, where the ids
  /// stop meaning anything.
  final legendFilter = RxnString();

  bool get isFiltering => legendFilter.value != null;

  /// Tapping the active swatch again clears it — the legend IS the filter UI,
  /// so it must be able to undo itself without a second control.
  void toggleLegendFilter(String key) {
    legendFilter.value = legendFilter.value == key ? null : key;
  }

  void clearLegendFilter() => legendFilter.value = null;

  bool isLegendActive(String key) => legendFilter.value == key;

  // ── Search (spec §10) ─────────────────────────────────────

  /// The live search text. Search HIGHLIGHTS, it never navigates: leaving the
  /// chart for a list screen is the exact pattern the Board exists to delete.
  final searchQuery = ''.obs;

  bool get isSearching => searchQuery.value.trim().isNotEmpty;

  void setSearch(String query) => searchQuery.value = query;

  void clearSearch() => searchQuery.value = '';

  /// Whether any of [fields] (name, mobile, berth code…) matches the query.
  ///
  /// An EMPTY query matches everything, so callers composing this into a dim
  /// test do not have to special-case "not searching". Use [isSearchHit] when
  /// you want "this berth is a genuine hit" instead (the pulse, the scroll-to).
  bool matchesSearch(Iterable<String?> fields) {
    final q = searchQuery.value.trim().toLowerCase();
    if (q.isEmpty) return true;
    for (final field in fields) {
      if (field == null || field.isEmpty) continue;
      if (field.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  /// A berth the user is actively looking for: pulse it and scroll it into
  /// view. False whenever the search box is empty.
  bool isSearchHit(Iterable<String?> fields) =>
      isSearching && matchesSearch(fields);

  // ── What a berth should look like ─────────────────────────

  /// Whether a berth renders dimmed — the shared answer for both dimming
  /// causes, so a berth can never be filtered out and searched in at once.
  ///
  /// [legendKey] is the berth's bucket under the ACTIVE lens (the same key
  /// space [toggleLegendFilter] uses); pass null for a berth the current lens
  /// puts in no bucket, which is then dimmed by any active filter.
  ///
  /// Reads both observables on every path so an enclosing `Obx` keeps its
  /// dependency on each of them regardless of which branch decided the answer.
  bool isDimmed({String? legendKey, Iterable<String?> searchFields = const []}) {
    final filter = legendFilter.value;
    final query = searchQuery.value.trim();
    final filteredOut = filter != null && legendKey != filter;
    final missedSearch = query.isNotEmpty && !matchesSearch(searchFields);
    return filteredOut || missedSearch;
  }

  /// What a Board search reads on a berth: the code as printed on the coach and
  /// whoever is in it. Deliberately NOT the stop or group name — those are
  /// whole lenses of their own, and a name search that also lit up everyone
  /// boarding at a stop called "Ramesh Nagar" would be a worse tool.
  List<String?> berthSearchFields(BoardBerth berth) => [
    berth.code,
    berth.occupantName,
  ];

  bool isBerthSearchHit(BoardBerth berth) =>
      isSearchHit(berthSearchFields(berth));

  /// [isDimmed] for a real berth: pairs the active filter with the legend row
  /// that owns it and asks [BoardLegendEntry.selects], so "which berths does
  /// this swatch keep lit" is answered in ONE place — the lens's own predicate
  /// — instead of every tile inventing a bucket key of its own.
  ///
  /// [legend] is the lens's rows for the bus on screen (`lens.legendFor(...)`).
  /// A filter id those rows no longer contain dims NOTHING: a stale key must
  /// black out a swatch, not the whole coach.
  bool isBerthDimmed(BoardBerth berth, List<BoardLegendEntry> legend) {
    final filter = legendFilter.value;
    var filteredOut = false;
    if (filter != null) {
      final row = legend.firstWhereOrNull((e) => e.id == filter);
      filteredOut = row != null && !row.selects(berth);
    }
    final query = searchQuery.value.trim();
    final missedSearch =
        query.isNotEmpty && !matchesSearch(berthSearchFields(berth));
    return filteredOut || missedSearch;
  }

  // ── Multi-select (spec §7) ────────────────────────────────

  /// Berth ids currently selected for a bulk action.
  final selection = <String>{}.obs;

  /// Whether the Board is in multi-select mode. Tracked separately from
  /// `selection.isNotEmpty` so the bulk action bar can appear on the long-press
  /// that starts the gesture, before a second berth is added.
  final multiSelect = false.obs;

  bool get isMultiSelecting => multiSelect.value;

  int get selectedCount => selection.length;

  bool isSelected(String berthId) => selection.contains(berthId);

  /// Long-press entry point: enters the mode and takes the pressed berth with
  /// it, so the gesture that starts a selection also makes one.
  void beginMultiSelect(String berthId) {
    multiSelect.value = true;
    selection.add(berthId);
  }

  /// Taps while in multi-select mode. Deselecting the LAST berth leaves the
  /// mode — a bulk action bar over an empty selection offers nothing, and this
  /// gives the gesture a natural way out that is not a hunt for a close button.
  void toggleSelected(String berthId) {
    if (selection.contains(berthId)) {
      selection.remove(berthId);
      if (selection.isEmpty) multiSelect.value = false;
    } else {
      selection.add(berthId);
      multiSelect.value = true;
    }
  }

  void clearSelection() {
    if (selection.isNotEmpty) selection.clear();
    multiSelect.value = false;
  }

  // ── Aisle-order walk (spec §4) ────────────────────────────

  /// The bus on screen, in physical WALKING order.
  ///
  /// The order itself is `lib/utils/aisle_order.dart`'s job — it is a pure
  /// function of the layout geometry and belongs with the geometry. What
  /// belongs HERE is only how far along that order the handler has got, so this
  /// holds the prebuilt [AisleWalk] (built once per layout, as that file's own
  /// docs ask) and delegates every question about ORDER to it.
  final walk = Rx<AisleWalk>(AisleWalk.of(null));

  /// The berth the walk is parked on — the last one [advanceToNextOutstanding]
  /// handed out, or the last one tapped. Null means the walk has not started,
  /// so the next advance begins at the front of the bus.
  ///
  /// A seat id rather than an index: indices shift when a chart is edited, and
  /// a cursor that silently came to point at a DIFFERENT berth would send the
  /// handler to the wrong person.
  final cursor = RxnString();

  /// Where the handler is, as a position in the walk, for a "berth 14 of 40"
  /// readout. Null before the walk starts, or when the cursor is not on this
  /// bus.
  int? get cursorIndex => walk.value.indexOf(cursor.value);

  /// The berth the cursor sits on, or null when the walk has not started.
  SeatCell? get cursorBerth => walk.value.berthFor(cursor.value);

  /// Rebuilds the walk for [layout] — call on open and on every bus switch.
  /// Also the single source of [berthCount], and so of the density default.
  void setLayout(BusLayout? layout) {
    final next = AisleWalk.of(layout);
    walk.value = next;
    // A cursor pointing at a berth this bus does not have would silently
    // restart the walk from the front on the next advance. Make that explicit.
    final at = cursor.value;
    if (at != null && next.indexOf(at) == null) cursor.value = null;
  }

  /// Parks the walk on [seatId] — what a plain berth TAP does, so that closing
  /// the sheet and hitting "next outstanding" carries on from where the handler
  /// actually is rather than from wherever the last auto-advance left them.
  /// A berth this bus does not have is ignored rather than stored.
  void setCursor(String? seatId) {
    if (seatId == null || seatId.isEmpty) {
      cursor.value = null;
      return;
    }
    if (walk.value.indexOf(seatId) == null) return;
    cursor.value = seatId;
  }

  /// Sends the walk back to the front of the bus.
  void resetCursor() {
    if (cursor.value != null) cursor.value = null;
  }

  /// How many berths the lens still wants — the summary strip's headcount.
  int outstandingCount(BerthPredicate needsAction) =>
      walk.value.count(needsAction);

  /// The next berth the lens wants, WITHOUT moving the cursor. The "next
  /// outstanding" control reads it to know whether it has anything left to
  /// offer, so it can disable itself instead of going dead under the thumb.
  ///
  /// [needsAction] is supplied per lens — unpaid under money, un-boarded under
  /// boarding, empty under assignment — because "outstanding" is exactly what a
  /// lens means. [wrap] passes straight through to [AisleWalk.next] and keeps
  /// its default: a handler flagged down at berth 20 is still walked back to the
  /// outstanding berths in front of them once they reach the rear. Pass false
  /// for a strictly one-way sweep that stops at the back of the bus.
  SeatCell? peekNextOutstanding(
    BerthPredicate needsAction, {
    bool wrap = true,
  }) => walk.value.next(from: cursor.value, matches: needsAction, wrap: wrap);

  bool hasNextOutstanding(BerthPredicate needsAction, {bool wrap = true}) =>
      peekNextOutstanding(needsAction, wrap: wrap) != null;

  /// Moves the walk on and returns where it landed, or null when the round is
  /// done — at which point the cursor is LEFT WHERE IT WAS, so the strip can
  /// still say which berth was dealt with last.
  ///
  /// The berth the cursor already sits on is never handed back (see
  /// [AisleWalk.next]), so a double tap moves on rather than re-opening the
  /// same sheet.
  SeatCell? advanceToNextOutstanding(
    BerthPredicate needsAction, {
    bool wrap = true,
  }) {
    final next = peekNextOutstanding(needsAction, wrap: wrap);
    final id = next?.seatId;
    if (id != null && id.isNotEmpty) cursor.value = id;
    return next;
  }

  /// One step back up the aisle — the "I mis-tapped, go back" affordance the
  /// walk was given a [AisleWalk.previous] for. Same rules as
  /// [advanceToNextOutstanding], walking toward the front.
  SeatCell? rewindToPreviousOutstanding(
    BerthPredicate needsAction, {
    bool wrap = true,
  }) {
    final prev = walk.value.previous(
      from: cursor.value,
      matches: needsAction,
      wrap: wrap,
    );
    final id = prev?.seatId;
    if (id != null && id.isNotEmpty) cursor.value = id;
    return prev;
  }
}
