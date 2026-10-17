import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../components/bus_message_composer_field.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../services/wa_template_params.dart';
import '../services/whatsapp_cloud_service.dart';
import '../services/whatsapp_outbound.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
// `displayPhone` — the shared "strip to a dialable 10 digits" rule, so the
// number the organiser is told to call reads the same here as on every chart.
import '../utils/seat_grid_placement.dart' show displayPhone;
import '../utils/time_format.dart' show formatHhMm;
import '../utils/wa_error_text.dart';
import '../utils/wa_param_error_text.dart';

part 'notify/notify_sections.dart';
part 'notify/notify_send_flow.dart';
part 'notify/notify_cards.dart';
part 'notify/notify_rows.dart';
part 'notify/notify_bus_composer.dart';

/// Notify tab — lock gate + post-lock notification tracker.
///
/// Two distinct modes, switched by `tour.status`:
///   * NOT LOCKED → lock gate (checklist + sticky "Lock tour" CTA)
///   * LOCKED → tracker (hero summary card, progress bar, filter pills,
///     collapsible search, flat passenger list, bulk send CTA)
class NotifyScreen extends StatefulWidget {
  /// When set, the screen is locked to this one tour (tour-first workspace
  /// entry) — the internal tour selector is hidden and a back button appears.
  /// Null is the legacy global mode (no longer used by the nav, kept harmless).
  final String? tourId;

  const NotifyScreen({super.key, this.tourId});

  @override
  State<NotifyScreen> createState() => _NotifyScreenState();
}

enum _NotifyFilter { all, pending, notified }

// ─── Pure decision logic ──────────────────────────────────────────────
//
// Everything below decides WHO gets a paid WhatsApp message and WHEN they are
// considered done. It is deliberately pure + top-level so each rule can be
// pinned by a unit test rather than only by driving the widget — see
// test/screens/notify_decisions_test.dart.

/// Why the Notify screen has (or has not) a tour to work on.
@visibleForTesting
enum NotifyTourState {
  /// A tour is resolved and can be notified.
  ok,

  /// Legacy global mode with no active tour to fall back to.
  noActiveTours,

  /// The requested tour exists, but the trip is over — nothing is sent from a
  /// finished tour.
  completed,

  /// The requested tour is not in the roster at all (deleted, or not loaded).
  missing,
}

/// Which tour the Notify screen is about, given every tour the controller holds
/// and the currently [selectedId] — the tour this screen was scoped to, or the
/// one the in-screen selector picked. Null [selectedId] is the legacy global
/// mode, which may pick the newest active tour for itself.
///
/// *** WHY THERE IS NO FALLBACK ***
/// This used to end in `selected ?? activeTours.first`. Completed tours are
/// filtered out of the candidate list, and the tour-detail "Lock / Send" row
/// pushes this screen for a COMPLETED tour — so opening Notify from a finished
/// trip silently RETARGETED whichever active tour happened to sort first, and
/// the next tap would have messaged that tour's passengers. Quietly swapping
/// one set of real people for another is not a recoverable mistake, so an
/// unresolvable request yields null and the screen says so out loud.
@visibleForTesting
({Tour? tour, NotifyTourState state, List<Tour> active}) resolveNotifyTour({
  required List<Tour> allTours,
  required String? selectedId,
}) {
  final active =
      allTours.where((t) => t.status != TourStatus.completed).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  if (selectedId == null) {
    return active.isEmpty
        ? (tour: null, state: NotifyTourState.noActiveTours, active: active)
        : (tour: active.first, state: NotifyTourState.ok, active: active);
  }
  for (final t in active) {
    if (t.id == selectedId) {
      return (tour: t, state: NotifyTourState.ok, active: active);
    }
  }
  return (
    tour: null,
    state: allTours.any((t) => t.id == selectedId)
        ? NotifyTourState.completed
        : NotifyTourState.missing,
    active: active,
  );
}

/// The passenger ids a completed send may stamp as notified.
///
/// *** WHY NOT PHONE NUMBERS ***
/// This used to collect the phone numbers that succeeded and mark every rider
/// in the batch whose number matched. A family booked under ONE handset is
/// several passenger rows sharing that number, so a single success stamped the
/// whole family — including rows whose message was never composed, and rows
/// that were in the batch and FAILED. A rider wrongly stamped notified vanishes
/// from every later "needs notifying" surface and is never contacted again.
///
/// Identity is the passenger id, which each result already carries
/// ([WaRecipientResult.passengerId], set index-aligned by
/// [WhatsAppCloudService.send]). Two rules keep this biased toward surfacing:
///   * a result with no attributable id stamps nobody;
///   * a rider recorded BOTH ok and failed (a duplicate row, a retry folded
///     into one batch) stays pending.
/// A rider messaged twice is a nuisance; a rider silently marked done never
/// hears from us at all.
@visibleForTesting
Set<String> notifiedPassengerIds({
  required WaSendResult result,
  required Set<String> requested,
}) {
  final ok = <String>{};
  final bad = <String>{};
  for (final r in result.results) {
    final id = r.passengerId;
    if (id == null || !requested.contains(id)) continue;
    (r.ok ? ok : bad).add(id);
  }
  return ok.difference(bad);
}

/// How one rider reads in the post-lock tracker.
@visibleForTesting
enum NotifyRowState {
  /// Holds seats their last notification did not cover — send them the chart.
  pending,

  /// Holds seats and has been told about exactly these ones.
  notified,

  /// Was told about seats that have since been TAKEN AWAY. No WhatsApp
  /// template fits this, so it is a call-them task, never an automatic send.
  seatRemoved,
}

/// Classify one rider for the tracker. Pure, so the three-way rule can be
/// pinned without a widget.
@visibleForTesting
NotifyRowState notifyRowState(Passenger p) {
  if (p.seatsRemovedSinceNotified) return NotifyRowState.seatRemoved;
  return p.seatsChangedSinceNotified
      ? NotifyRowState.pending
      : NotifyRowState.notified;
}

/// Everyone the post-lock tracker must show for [tour], in roster order.
///
/// Riders holding a seat, PLUS riders whose seat was withdrawn AFTER they were
/// notified. That second group used to be filtered out of every notify surface
/// by `assignedSeats.isNotEmpty`: they hold a WhatsApp message naming a berth
/// that no longer exists, nothing would ever correct it, and they turn up on
/// the day expecting to travel.
@visibleForTesting
List<Passenger> notifyRoster(Tour tour) => [
      for (final p in tour.passengers)
        if (p.assignedSeats.isNotEmpty || p.seatsRemovedSinceNotified) p,
    ];

class _NotifyScreenState extends State<NotifyScreen> {
  /// Whether this rider's CURRENT seats have been sent to them.
  ///
  /// *** WHY NOT A SESSION SET ***
  /// This used to be a `Set<String> _sentIds` populated as messages went out
  /// and cleared on restart or tour switch. After any reload the whole roster
  /// read "Pending" and the counts read 0-sent — while the CTA, which already
  /// read the persisted signature, correctly said there was nothing to send.
  /// An organiser trusting the list would re-broadcast PAID WhatsApp messages
  /// to riders who had already received them.
  ///
  /// `seatsChangedSinceNotified` is persisted, survives a restart, and flips
  /// back on the moment a locked tour's seats are edited. `markSeatsNotified`
  /// writes it optimistically, so a just-sent row updates without waiting for
  /// the server — which is the only thing the session set was still buying.
  ///
  /// Routed through [notifyRowState] so a rider whose seat was WITHDRAWN after
  /// notifying can never read "Sent": their signature no longer matches
  /// anything they hold, and they still need a phone call.
  bool _isSent(Passenger p) => notifyRowState(p) == NotifyRowState.notified;

  final TextEditingController _searchCtrl = TextEditingController();
  bool _searchVisible = false;
  String _query = '';

  String? _selectedTourId;
  _NotifyFilter _filter = _NotifyFilter.all;

  /// True when launched as a tour-scoped, pushed screen (vs the old tab).
  bool get _scoped => widget.tourId != null;

  @override
  void initState() {
    super.initState();
    _selectedTourId = widget.tourId;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// `setState` for the part-file extensions (it is @protected).
  void _update(VoidCallback fn) => setState(fn);

  void _toggleSearch() {
    HapticFeedback.selectionClick();
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchCtrl.clear();
        _query = '';
      }
    });
  }

  // ── Build ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tourCtrl = Get.find<TourController>();

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final resolved = resolveNotifyTour(
            allTours: tourCtrl.tours,
            selectedId: _selectedTourId,
          );
          final activeTours = resolved.active;
          final Tour? tour = resolved.tour;

          if (tour == null) {
            return Column(
              children: [
                UgamAppBar(
                  title: tr('notify.title'),
                  showBack: Navigator.canPop(context),
                  onBack: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: _unresolvedEmpty(resolved.state, activeTours),
                ),
              ],
            );
          }

          final isLocked = tour.status == TourStatus.locked;
          // Riders holding a seat AND riders whose seat was withdrawn after
          // they were notified — the second group used to be dropped here.
          final roster = notifyRoster(tour);
          final stranded =
              roster.where((p) => p.seatsRemovedSinceNotified).toList();
          final sentCount = roster.where(_isSent).length;
          final pendingCount = roster.length - sentCount;

          final busInfo = _resolveBusInfo(tour);

          return Column(
            children: [
              UgamAppBar(
                title: tr('notify.title'),
                showBack: Navigator.canPop(context),
                onBack: () => Navigator.of(context).maybePop(),
                actions: [
                  // The "reset sent" action is gone with the session set it
                  // reset. Re-broadcasting is the "Resend all" CTA, which does
                  // it for real rather than by forgetting.
                  if (isLocked)
                    UgamAppBarAction(
                      icon: _searchVisible
                          ? Icons.close_rounded
                          : Icons.search_rounded,
                      onTap: _toggleSearch,
                      active: _searchVisible,
                    ),
                ],
              ),
              if (isLocked)
                AnimatedSize(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
                  child: _searchVisible
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(
                            UgamSpacing.gutter,
                            0,
                            UgamSpacing.gutter,
                            UgamSpacing.md,
                          ),
                          child: UgamSearchField(
                            controller: _searchCtrl,
                            hint: tr('notify.search_hint'),
                            autofocus: true,
                            onChanged: (v) =>
                                setState(() => _query = v.trim()),
                            onClear: () => setState(() => _query = ''),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              if (!_scoped && activeTours.length > 1)
                _TourSelector(
                  tours: activeTours,
                  selectedId: tour.id,
                  onSelect: (id) => setState(() {
                    _selectedTourId = id;
                    _filter = _NotifyFilter.all;
                  }),
                ),
              const SizedBox(height: UgamSpacing.md),
              Expanded(
                child: isLocked
                    ? _buildTracker(
                        tour: tour,
                        roster: roster,
                        stranded: stranded,
                        sentCount: sentCount,
                        pendingCount: pendingCount,
                        busInfo: busInfo,
                        c: c,
                      )
                    : _buildLockGate(tour: tour, c: c),
              ),
            ],
          );
        }),
      ),
      // CTA lives in the bottomNavigationBar slot (not a Stack overlay) so it
      // behaves like every other action screen and respects the keyboard inset.
      // Its own Obx mirrors the body's derived state.
      bottomNavigationBar: Obx(() {
        // Same resolution as the body — including its refusal to substitute a
        // different tour — so the CTA can never target a tour the list above is
        // not showing.
        final Tour? tour = resolveNotifyTour(
          allTours: tourCtrl.tours,
          selectedId: _selectedTourId,
        ).tour;
        // Not SizedBox.shrink: a non-null zero-height bar still strips the
        // body's bottom inset (Scaffold checks for non-null, not for height),
        // so reserve the system inset whenever the CTA is absent.
        if (tour == null) {
          return SizedBox(height: MediaQuery.paddingOf(context).bottom);
        }

        final isLocked = tour.status == TourStatus.locked;
        if (isLocked) {
          // Seated riders only. A rider whose seat was WITHDRAWN has no chart
          // to build, so no bulk send can reach them — the tracker gives them
          // their own row and a call-them action instead.
          final seated = tour.passengers
              .where((p) => p.assignedSeats.isNotEmpty)
              .toList();
          // No seated riders → nothing to send at all. Still reserve the
          // system inset; see the note on the tour == null branch above.
          if (seated.isEmpty) {
            return SizedBox(height: MediaQuery.paddingOf(context).bottom);
          }
          // Riders whose CURRENT seats have NOT been notified — a fresh lock
          // (never sent) OR an organiser edit AFTER lock. Persistent, so it
          // survives a reload/restart (unlike the session-only _sentIds tracker),
          // and it re-appears the moment a locked tour's seats are edited.
          final changed =
              seated.where((p) => p.seatsChangedSinceNotified).toList();
          if (changed.isNotEmpty) {
            // "Notify N" when nobody's been sent yet (fresh lock / all changed);
            // "Re-notify N" when only a few moved after an earlier full send.
            final firstSend = changed.length == seated.length;
            return UgamStickyCTA(
              child: UgamCTA(
                label: firstSend
                    ? tr('notify.send_all_pending')
                    : tr('notify.resend_changed'),
                leadingIcon: Icons.chat_rounded,
                trailingValue: '${changed.length}',
                onPressed: () => _sendChangedAllocations(
                  tour,
                  changed.map((p) => p.id).toSet(),
                ),
              ),
            );
          }
          // Everyone's current seats have been notified — keep a full re-send
          // available so the organiser can always re-broadcast the chart.
          return UgamStickyCTA(
            child: UgamCTA(
              label: tr('notify.resend_all'),
              leadingIcon: Icons.send_rounded,
              onPressed: () => _sendSeatAllocations(tour),
            ),
          );
        }
        return _LockStickyCTA(tour: tour, c: c, onLock: _lockTour);
      }),
    );
  }

  // ── Unresolved-tour empty state ────────────────────────────────
  /// What to show when [resolveNotifyTour] could not produce a tour. Each state
  /// is named explicitly — the screen used to paper over "this tour is
  /// finished" by quietly switching to a different tour entirely.
  Widget _unresolvedEmpty(NotifyTourState state, List<Tour> active) {
    final (String title, String body) = switch (state) {
      NotifyTourState.completed => (
          tr('notify.tour_completed_title'),
          tr('notify.tour_completed_body'),
        ),
      NotifyTourState.missing => (
          tr('notify.tour_unavailable_title'),
          tr('notify.tour_unavailable_body'),
        ),
      _ => (
          tr('notify.no_active_tours_title'),
          tr('notify.no_active_tours_body'),
        ),
    };
    // Legacy global mode: the selector lives inside the resolved branch, so a
    // tour that completed while selected would otherwise be a dead end with no
    // way back to the tours that CAN be notified.
    final canReset = !_scoped && _selectedTourId != null && active.isNotEmpty;
    return UgamEmpty(
      icon: Icons.notifications_off_rounded,
      title: title,
      body: body,
      cta: canReset
          ? UgamCTA(
              label: tr('notify.choose_another_tour'),
              leadingIcon: Icons.list_rounded,
              onPressed: () => setState(() {
                _selectedTourId = null;
                _filter = _NotifyFilter.all;
              }),
            )
          : null,
    );
  }

  _BusInfo _resolveBusInfo(Tour tour) {
    if (tour.buses.isEmpty) {
      return _BusInfo(
        busNo: tr('notify.not_assigned'),
        driverName: tr('notify.not_assigned'),
      );
    }
    // Only REAL driver names, de-duplicated: joining every bus's raw
    // driverName printed a bare "," when none had one entered. Empty → the
    // hero hides the driver cell instead of showing punctuation.
    final drivers = <String>{
      for (final b in tour.buses)
        if (b.driverName.trim().isNotEmpty) b.driverName.trim(),
    };
    return _BusInfo(
      // One bus per line (name · plate), so a multi-bus tour names EVERY bus
      // in the header instead of ellipsising "RSR, BANSIDHAR…" mid-name.
      busNo: tour.buses.map((b) => b.displayLabel).join('\n'),
      busCount: tour.buses.length,
      driverName: drivers.join(', '),
    );
  }
}

class _BusInfo {
  final String busNo;
  final int busCount;
  final String driverName;
  _BusInfo({
    required this.busNo,
    this.busCount = 1,
    required this.driverName,
  });
}

// The search pill is the shared [UgamSearchField]. The private `_SearchField`
// that used to live here was a line-for-line copy of it minus the clear (×)
// button, so Notify was the one search bar in the app the user had to
// backspace out by hand.
