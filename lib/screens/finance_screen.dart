import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/finance_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour_finance.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../widgets/cash_so_far_line.dart';
import '../widgets/money_loading_skeleton.dart';
import 'create_tour_screen.dart';
import 'tour_detail_screen.dart';
import 'tour_money_board_screen.dart';

part 'finance/finance_hero.dart';
part 'finance/finance_zero_state.dart';
part 'finance/finance_tour_row.dart';

/// FINANCE — the cross-tour Profit & Loss report.
///
/// Sums the realised revenue (net cash collected) and expenses of every
/// COMPLETED tour, scoped to a period (this month / this year / all time), and
/// shows the headline net profit, a few roll-up stats, and one tappable row per
/// past trip. Tapping a trip opens its full tour detail (passengers, buses,
/// seat chart, and the money board via its Money tool), so a completed tour's
/// whole record stays reachable. Long-pressing a trip offers to delete it,
/// after a confirm that lists every rider and rupee the trip still holds.
///
/// All aggregation is delegated to [FinanceController]; colour comes only from
/// [UgamColors.of] and every figure uses tabular numerals, per the locked DNA.
class FinanceScreen extends StatefulWidget {
  const FinanceScreen({super.key});

  @override
  State<FinanceScreen> createState() => _FinanceScreenState();
}

/// What the period's numbers actually MEAN — the distinction the report used to
/// throw away by rendering every one of these as the same confident `₹0`.
///
/// The three "no data" shapes are genuinely different problems with genuinely
/// different fixes, and the screen now says which one you are looking at:
///
/// * [periodEmpty] — trips exist, none of them ENDED inside the chosen period.
///   Nothing is wrong; the filter is too narrow. Fix = widen the period.
/// * [noTrips]     — there is no trip anywhere, in any period. Fix = make one.
/// * [noMoney]     — trips exist in the period but not one rupee has been
///   collected or spent against them. Fix = record the first entry.
/// * [breakEven]   — money genuinely moved and cancelled out. This is the ONLY
///   one of the four where `₹0` is a real answer, and it is the reading the old
///   screen silently gave to all four.
enum _ReportState { periodEmpty, noTrips, noMoney, breakEven, profit, loss }

extension on _ReportState {
  /// "Has a real answer" — the only three states where a rupee figure is an
  /// honest thing to print.
  bool get hasFigures =>
      this == _ReportState.profit ||
      this == _ReportState.loss ||
      this == _ReportState.breakEven;
}

class _FinanceScreenState extends State<FinanceScreen> {
  FinanceController get _finance => Get.find<FinanceController>();

  // Default to this month — running trips are included in financesFor, so the
  // report is no longer empty mid-season the way it was under completed-only.
  // All-time / this-year remain one tap away.
  FinancePeriod _period = FinancePeriod.thisMonth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Refetch when a money write happened since the last load, so the report
      // can't disagree with the per-tour money board.
      _finance.refreshIfStale();
    });
  }

  /// A trip row opens the WHOLE trip — details, passengers, buses, seat chart
  /// and its Money tool — not just the money board. [TourDetailScreen] hydrates
  /// an archived tour on open (cold start skips completed rosters) and routes a
  /// completed tour's Seats row to the frozen seat history, so nothing about
  /// an old trip is lost by opening it from here.
  void _openTour(TourFinance tf) {
    // Start the roster fetch now so it overlaps the push animation; the detail
    // screen's own call then joins this in-flight request.
    if (Get.isRegistered<TourController>()) {
      // ignore: unawaited_futures
      Get.find<TourController>()
          .ensureTourReadyForSeating(tf.tourId)
          .catchError((_) {});
    }
    Get.to(
      () => TourDetailScreen(tourId: tf.tourId),
      transition: Transition.cupertino,
    );
  }

  /// The zero-state "record the first entry" CTA still goes straight to the
  /// money board — that card is about money, not the trip. Cupertino, matching
  /// every other push into or between the money screens.
  void _openMoney(TourFinance tf) {
    Get.to(
      () => TourMoneyBoardScreen(tourId: tf.tourId),
      transition: Transition.cupertino,
    );
  }

  /// Long-press → delete a trip from the report (and the app).
  ///
  /// The roster is hydrated FIRST: an archived tour arrives with no passengers
  /// in memory, and a confirm that says "no passengers" over a trip that has
  /// fifty is exactly the silent wipe this must never be. If that check cannot
  /// run, nothing is deleted. Whatever the trip still holds — riders, buses,
  /// money in or out — is spelled out in the dialog before the agent confirms.
  Future<void> _confirmDelete(TourFinance tf) async {
    if (!Get.isRegistered<TourController>()) return;
    final tourCtrl = Get.find<TourController>();
    try {
      await tourCtrl.ensureTourHydrated(tf.tourId);
    } catch (_) {
      AppSnackBar.error(tr('finance.delete_check_failed'));
      return;
    }
    if (!mounted) return;
    final tour = tourCtrl.getTour(tf.tourId);
    if (tour == null) return;

    final title = tf.title.isEmpty ? tf.route : tf.title;
    final lines = <String>[
      if (tour.passengers.isNotEmpty)
        tr(
          'finance.delete_line_passengers',
          namedArgs: {'n': '${tour.passengers.length}'},
        ),
      if (tour.buses.isNotEmpty)
        tr(
          'finance.delete_line_buses',
          namedArgs: {'n': '${tour.buses.length}'},
        ),
      if (tf.revenue.round() != 0)
        tr(
          'finance.delete_line_collected',
          namedArgs: {'amount': _inr(tf.revenue)},
        ),
      if (tf.income.round() != 0)
        tr(
          'finance.delete_line_income',
          namedArgs: {'amount': _inr(tf.income)},
        ),
      if (tf.expenses.round() != 0)
        tr(
          'finance.delete_line_expenses',
          namedArgs: {'amount': _inr(tf.expenses)},
        ),
    ];
    final message = lines.isEmpty
        ? tr('finance.delete_body_empty')
        : tr(
            'finance.delete_body_data',
            namedArgs: {'details': lines.join('\n')},
          );

    final ok = await UgamDialog.confirm(
      context,
      title: tr('finance.delete_title', namedArgs: {'title': title}),
      message: message,
      confirmLabel: tr('finance.delete_trip'),
      confirmIcon: Icons.delete_outline_rounded,
      destructive: true,
    );
    if (!ok) return;
    try {
      // Soft delete (054): the row is archived with deleted_at, never
      // destroyed. The report iterates TourController.tours, so the row and
      // every total drop out on the same frame.
      await tourCtrl.deleteTour(tf.tourId);
      AppSnackBar.success(tr('finance.deleted', namedArgs: {'title': title}));
    } catch (_) {
      // deleteTour already surfaces its own error snackbar.
    }
  }

  /// The real create-trip destination, pushed exactly the way the charts screen
  /// empty state pushes it (charts_screen.dart:205) — an invented route or a
  /// second animation for the same screen is how an app starts feeling stitched
  /// together.
  void _createTour() {
    Get.to(() => const CreateTourScreen(), transition: Transition.cupertino);
  }

  /// Classify the period. See [_ReportState] for why this exists.
  _ReportState _stateFor(FinanceTotals t) {
    if (t.tourCount == 0) {
      // Only worth asking on a narrowed period — "all time" is already the
      // widest answer there is, so an empty all-time really means no trips.
      final anyEver =
          _period != FinancePeriod.allTime &&
          _finance.financesFor(FinancePeriod.allTime).isNotEmpty;
      return anyEver ? _ReportState.periodEmpty : _ReportState.noTrips;
    }
    if (t.pnl.isEmpty) return _ReportState.noMoney;
    if (t.tripProfit.round() == 0) return _ReportState.breakEven;
    return t.tripProfit > 0 ? _ReportState.profit : _ReportState.loss;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(
              eyebrow: tr('finance.eyebrow'),
              title: tr('finance.title'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                UgamSpacing.sm,
                UgamSpacing.gutter,
                UgamSpacing.md,
              ),
              child: UgamTabPills(
                currentIndex: FinancePeriod.values.indexOf(_period),
                onChanged: (i) =>
                    setState(() => _period = FinancePeriod.values[i]),
                items: [
                  UgamTabItem(label: tr('finance.period_month')),
                  UgamTabItem(label: tr('finance.period_year')),
                  UgamTabItem(label: tr('finance.period_all')),
                ],
              ),
            ),
            Expanded(
              child: Obx(() {
                final firstLoading =
                    _finance.isLoading.value && !_finance.loadedOnce.value;
                if (firstLoading) {
                  // The SHARED money skeleton — the four sibling money screens
                  // already shimmer this exact shape, so the first load no
                  // longer reflows differently on Finance alone.
                  return const MoneyLoadingSkeleton();
                }
                if (_finance.loadFailed.value && !_finance.loadedOnce.value) {
                  return UgamEmpty.error(onRetry: _finance.reload);
                }

                final tours = _finance.financesFor(_period);
                final totals = FinanceTotals.from(tours);
                final state = _stateFor(totals);
                final hasFigures = state.hasFigures;

                final ledgerEmpty = _finance.ledgerEmpty;
                // The coaching card and the broken-ledger notice answer the
                // same ₹0 with opposite explanations ("record your first
                // entry" vs "the records exist, the ledger lost them"), so
                // only one of them is ever allowed on screen. The notice wins:
                // it is the more specific diagnosis.
                final showZeroCard =
                    !hasFigures &&
                    !(ledgerEmpty && state == _ReportState.noMoney);

                return RefreshIndicator(
                  // Chrome, not ownership — the pull spinner is neutral ink2
                  // in every screen, so it never changes hue between tabs.
                  //
                  // This used to pass nothing and call itself "theme-driven",
                  // but RefreshIndicator falls back to
                  // `Theme.colorScheme.primary`, which this app seeds with the
                  // accent — so the money screens were painting the same amber
                  // as the screens that named it, just implicitly. Explicit
                  // now: there is no theme hook for a refresh spinner.
                  color: c.ink2,
                  onRefresh: _finance.reload,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.xs,
                      UgamSpacing.gutter,
                      UgamSpacing.xxl,
                    ),
                    children: [
                      // A silent ₹0 is the one thing this report must never
                      // show: it reads as "you made nothing", not "I could not
                      // find out". See FinanceController.ledgerEmpty.
                      if (ledgerEmpty) ...[
                        const _LedgerEmptyNotice(),
                        const SizedBox(height: UgamSpacing.md),
                      ],
                      _HeroCard(totals: totals, state: state, c: c),
                      // Three tiles reading `0 / — / —` under a headline that
                      // already says "no figures yet" is the same nothing said
                      // twice. They come back the moment a trip exists.
                      if (totals.tourCount > 0) ...[
                        const SizedBox(height: UgamSpacing.md),
                        _StatTriple(totals: totals),
                      ],
                      const SizedBox(height: UgamSpacing.lg),
                      if (showZeroCard) ...[
                        _ZeroStateCard(
                          state: state,
                          onShowAllTime: () =>
                              setState(() => _period = FinancePeriod.allTime),
                          onCreateTour: _createTour,
                          onOpenMoney: tours.isEmpty
                              ? null
                              : () => _openMoney(tours.first),
                        ),
                        if (tours.isNotEmpty)
                          const SizedBox(height: UgamSpacing.lg),
                      ],
                      if (tours.isNotEmpty) ...[
                        Text(
                          tr('finance.per_tour'),
                          style: UgamText.micro.copyWith(color: c.ink3),
                        ),
                        const SizedBox(height: UgamSpacing.sm),
                        for (final tf in tours)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: UgamSpacing.md,
                            ),
                            child: _TourFinanceRow(
                              tf: tf,
                              onTap: () => _openTour(tf),
                              onLongPress: () => _confirmDelete(tf),
                              c: c,
                            ),
                          ),
                      ],
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Money formatting ─────────────────────────────────────────────────────────
// All rupee grouping is delegated to the shared [Formatters]; these thin
// wrappers only add the explicit +/− sign presentation the report needs.

/// The "there is no figure here" glyph. A dash is NOT ₹0 — it is the report
/// saying it has nothing to report, which is the whole distinction this screen
/// used to lose.
const String _noFigure = '—';

/// Unsigned amount, e.g. `₹1,72,000`.
String _inr(num v) => Formatters.formatMoneyInr(v.abs());

/// Signed amount with explicit +/-, e.g. `+₹38,200` / `-₹4,100` / `₹0`.
///
/// The sign uses the ASCII hyphen [Formatters.formatMoneyInr] emits, not a
/// typographic U+2212 — a negative figure has to be glyph-identical to the same
/// figure on the money board / P&L, which the agent compares side by side.
String _signedInr(num v) {
  final r = v.round();
  if (r == 0) return Formatters.formatMoneyInr(0);
  final body = Formatters.formatMoneyInr(r.abs());
  return r > 0 ? '+$body' : '-$body';
}

/// Compact amount for tight stat columns, e.g. `₹1.7L`, `₹38K`, signed.
String _compactSigned(num v) {
  if (v.round() == 0) return Formatters.formatMoneyInrCompact(0);
  final body = Formatters.formatMoneyInrCompact(v.abs());
  return v < 0 ? '-$body' : '+$body';
}

String _dateLabel(BuildContext context, DateTime d) =>
    Formatters.formatDateMedium(d, locale: context.locale.languageCode);

// The first-load skeleton and the load-failure state are the SHARED
// `MoneyLoadingSkeleton` / `UgamEmpty.error` used by the four sibling money
// screens. The private `_Loading` / `_ErrorState` copies that used to live here
// had already drifted from them (three stat boxes vs two, a tonal retry vs the
// shared solid one) and were deleted.
//
// The private `_Empty` that used to sit here is gone too: a centred icon over
// "No trips with money yet" is a statement, and what this screen owed the agent
// was an explanation plus a way out. That is `_ZeroStateCard`. The
// `finance.empty_title` / `finance.empty_body` strings are left in the
// translation files rather than deleted.
