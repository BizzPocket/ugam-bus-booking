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
import '../utils/wa_param_error_text.dart';

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

class _NotifyScreenState extends State<NotifyScreen> {
  /// Passenger ids already sent in this session. Reset on app restart.
  final Set<String> _sentIds = <String>{};

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

  void _resetSent() => setState(_sentIds.clear);

  // ── Build ─────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tourCtrl = Get.find<TourController>();

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final activeTours =
              tourCtrl.tours
                  .where((t) => t.status != TourStatus.completed)
                  .toList()
                ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

          final selected = _selectedTourId != null
              ? activeTours.firstWhereOrNull((t) => t.id == _selectedTourId)
              : null;
          final Tour? tour =
              selected ?? (activeTours.isEmpty ? null : activeTours.first);

          if (tour == null) {
            return Column(
              children: [
                UgamAppBar(
                  title: tr('notify.title'),
                  showBack: Navigator.canPop(context),
                  onBack: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: UgamEmpty(
                    icon: Icons.notifications_off_rounded,
                    title: tr('notify.no_active_tours_title'),
                    body: tr('notify.no_active_tours_body'),
                  ),
                ),
              ],
            );
          }

          final isLocked = tour.status == TourStatus.locked;
          final assigned = tour.passengers
              .where((p) => p.assignedSeats.isNotEmpty)
              .toList();
          final sentCount = assigned
              .where((p) => _sentIds.contains(p.id))
              .length;
          final pendingCount = assigned.length - sentCount;

          final busInfo = _resolveBusInfo(tour);

          return Column(
            children: [
              UgamAppBar(
                title: tr('notify.title'),
                showBack: Navigator.canPop(context),
                onBack: () => Navigator.of(context).maybePop(),
                actions: [
                  if (isLocked && _sentIds.isNotEmpty)
                    UgamAppBarAction(
                      icon: Icons.refresh_rounded,
                      onTap: _resetSent,
                      tooltip: tr('notify.reset_sent'),
                    ),
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
                    _sentIds.clear();
                    _filter = _NotifyFilter.all;
                  }),
                ),
              const SizedBox(height: UgamSpacing.md),
              Expanded(
                child: isLocked
                    ? _buildTracker(
                        tour: tour,
                        assigned: assigned,
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
        final activeTours =
            tourCtrl.tours
                .where((t) => t.status != TourStatus.completed)
                .toList()
              ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final selected = _selectedTourId != null
            ? activeTours.firstWhereOrNull((t) => t.id == _selectedTourId)
            : null;
        final Tour? tour =
            selected ?? (activeTours.isEmpty ? null : activeTours.first);
        if (tour == null) return const SizedBox.shrink();

        final isLocked = tour.status == TourStatus.locked;
        if (isLocked) {
          final seated = tour.passengers
              .where((p) => p.assignedSeats.isNotEmpty)
              .toList();
          // No seated riders → nothing to send at all.
          if (seated.isEmpty) return const SizedBox.shrink();
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

  // ── Tracker (post-lock) ────────────────────────────────────────
  Widget _buildTracker({
    required Tour tour,
    required List<Passenger> assigned,
    required int sentCount,
    required int pendingCount,
    required _BusInfo busInfo,
    required UgamColorSet c,
  }) {
    if (assigned.isEmpty) {
      return UgamEmpty(
        icon: Icons.event_seat_outlined,
        title: tr('notify.empty_no_seats'),
        body: tr('notify.assign_first'),
      );
    }

    final q = _query.toLowerCase();
    final baseByFilter = switch (_filter) {
      _NotifyFilter.all => assigned,
      _NotifyFilter.pending =>
        assigned.where((p) => !_sentIds.contains(p.id)).toList(),
      _NotifyFilter.notified =>
        assigned.where((p) => _sentIds.contains(p.id)).toList(),
    };
    final filtered = q.isEmpty
        ? baseByFilter
        : baseByFilter
              .where(
                (p) =>
                    p.displayName.toLowerCase().contains(q) ||
                    p.phone.toLowerCase().contains(q),
              )
              .toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.huge,
      ),
      children: [
        _HeroSummaryCard(tour: tour, busInfo: busInfo, c: c),
        const SizedBox(height: UgamSpacing.md),
        _ProgressCard(c: c, sent: sentCount, total: assigned.length),
        if (tour.buses.isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.md),
          _BusMessageCard(c: c, onTap: () => _openBusMessageComposer(tour)),
        ],
        const SizedBox(height: UgamSpacing.md),
        UgamTabPills(
          currentIndex: _filter.index,
          onChanged: (i) => setState(() => _filter = _NotifyFilter.values[i]),
          items: [
            UgamTabItem(label: tr('notify.filter_all'), count: assigned.length),
            UgamTabItem(label: tr('notify.filter_pending'), count: pendingCount),
            UgamTabItem(label: tr('notify.filter_notified'), count: sentCount),
          ],
        ),
        const SizedBox(height: UgamSpacing.md),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
            child: Center(
              child: Text(
                _query.isNotEmpty
                    ? tr('notify.no_matches', namedArgs: {'query': _query})
                    : tr('notify.nothing_here'),
                style: UgamText.body.copyWith(color: c.ink2),
              ),
            ),
          )
        else
          for (var i = 0; i < filtered.length; i++) ...[
            _NotifyRow(
              passenger: filtered[i],
              busInfo: busInfo,
              isSent: _sentIds.contains(filtered[i].id),
              c: c,
              // Repeat the EXACT after-lock message to just this one person:
              // the `seat_allotment` Cloud API template (highlighted seat-chart
              // image header + boarding/departure/handler body) — the same
              // payload the bulk "send to all pending" CTA fires, scoped to one
              // id. Not the old "Ticket Confirmed!" deep-link/OS-share caption.
              onSend: () => _dispatchSeatAllocations(tour, {filtered[i].id}),
            ),
            if (i != filtered.length - 1)
              const SizedBox(height: UgamSpacing.tight),
          ],
      ],
    );
  }

  // ── Lock gate (pre-lock) ───────────────────────────────────────
  Widget _buildLockGate({required Tour tour, required UgamColorSet c}) {
    final allAssigned = tour.allSeatsAssigned;
    final hasHandler = tour.handlerId != null;
    final hasPassengers = tour.passengers.isNotEmpty;
    // Whole-bus announcements don't need lock — the recipient set (riders
    // seated on a bus) already exists during the assigning phase. Surface the
    // SAME composer here, but only once someone is actually seated so the card
    // is never a dead-end (the composer disables Send for a 0-rider bus anyway).
    final anySeated = tour.passengers.any((p) => p.assignedSeats.isNotEmpty);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.huge,
      ),
      children: [
        _HeroSummaryCard(tour: tour, busInfo: _resolveBusInfo(tour), c: c),
        if (tour.buses.isNotEmpty && anySeated) ...[
          const SizedBox(height: UgamSpacing.md),
          _BusMessageCard(c: c, onTap: () => _openBusMessageComposer(tour)),
        ],
        const SizedBox(height: UgamSpacing.lg),
        UgamCard.plain(
          padding: const EdgeInsets.fromLTRB(
            UgamSpacing.lg,
            UgamSpacing.lg,
            UgamSpacing.lg,
            UgamSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: UgamScale.px(context, 40),
                    height: UgamScale.px(context, 40),
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      borderRadius: BorderRadius.circular(UgamRadius.input),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.lock_outline_rounded,
                      size: UgamScale.px(context, 19),
                      color: c.accent,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr('notify.lock_gate_ready'),
                          style: UgamText.titleM.copyWith(color: c.ink),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('notify.lock_gate_body'),
                          style: UgamText.caption.copyWith(color: c.ink2),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UgamSpacing.lg),
              _Check(
                done: hasPassengers,
                label: tr('notify.check_has_passengers'),
                c: c,
              ),
              const SizedBox(height: UgamSpacing.sm),
              _Check(
                done: allAssigned,
                label: tr('notify.check_all_assigned'),
                c: c,
              ),
              const SizedBox(height: UgamSpacing.sm),
              _Check(
                done: hasHandler,
                label: tr('notify.check_has_handler'),
                c: c,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _lockTour(Tour tour) async {
    // "Lock & notify" is ONE mental action for the organiser, so the flow
    // auto-chains lock → send. It used to also cost TWO back-to-back confirms
    // ("Lock this tour?" then a fresh "Send seat allocations?" after a silent
    // gap). Collapse those into a SINGLE confirm that covers both actions;
    // count the riders who will actually receive an allocation so the message
    // is honest. (The independent post-lock "Re-send to all" path keeps its
    // own confirm — see [_sendSeatAllocations].)
    final t = Get.find<TourController>().getTour(tour.id) ?? tour;
    final seatedCount =
        t.passengers.where((p) => p.assignedSeats.isNotEmpty).length;

    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('notify.lock_send_dialog_title'),
      message: tr(
        'notify.lock_send_dialog_body',
        namedArgs: {'count': seatedCount.toString()},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('notify.lock_send_dialog_confirm'),
      confirmIcon: Icons.lock_rounded,
    );
    if (!confirmed) return;
    await Get.find<TourController>().lockTour(tour.id);
    if (!mounted) return;
    // No green "locked" toast here — the locked status card + the sticky CTA
    // already make the new state obvious, so the toast was redundant noise.

    // Phase 8 — push each seated passenger their seat allocation via the Cloud
    // API (seat_allotment template). The combined confirm above already covered
    // this send, so skip the (now redundant) second "Send seat allocations?".
    await _sendSeatAllocations(tour, skipConfirm: true);
  }

  /// Confirm + send seat charts to every seated rider on [tour].
  ///
  /// [skipConfirm] is set only on the lock→send auto-chain (see [_lockTour]),
  /// where a single combined "Lock tour & send seat allocations?" confirm has
  /// already covered this send — so this path must NOT raise a second,
  /// redundant "Send seat allocations?" dialog. Every independent entry point
  /// (the post-lock "Re-send to all" CTA) leaves it false and keeps its confirm.
  Future<void> _sendSeatAllocations(Tour tour, {bool skipConfirm = false}) async {
    // Use the FRESHEST tour from the controller — the passed snapshot can be
    // stale (captured before the seat plan was applied/persisted), which would
    // make the send think nobody is seated and bail out silently.
    final t = Get.find<TourController>().getTour(tour.id) ?? tour;
    final seated =
        t.passengers.where((p) => p.assignedSeats.isNotEmpty).toList();
    if (seated.isEmpty) {
      AppSnackBar.error(tr('notify.no_seated_passengers'));
      return;
    }

    if (!skipConfirm) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('notify.alloc_dialog_title'),
        message: tr(
          'notify.alloc_dialog_body',
          namedArgs: {'count': seated.length.toString()},
        ),
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: tr('notify.alloc_dialog_send'),
        confirmIcon: Icons.send_rounded,
      );
      if (!ok) return;
    }

    await _dispatchSeatAllocations(t, seated.map((p) => p.id).toSet());
  }

  /// Confirm + re-dispatch seat charts to a SPECIFIC set of riders (those whose
  /// seats changed since their last notification). Mirrors [_sendSeatAllocations]
  /// but targets [ids] instead of every seated rider.
  Future<void> _sendChangedAllocations(Tour tour, Set<String> ids) async {
    if (ids.isEmpty) return;
    final ok = await UgamDialog.confirm(
      context,
      title: tr('notify.alloc_dialog_title'),
      message: tr(
        'notify.alloc_dialog_body',
        namedArgs: {'count': ids.length.toString()},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('notify.alloc_dialog_send'),
      confirmIcon: Icons.send_rounded,
    );
    if (!ok) return;
    await _dispatchSeatAllocations(tour, ids);
  }

  /// Send the seat-allotment messages to [passengerIds] on [t], showing a live
  /// "preparing X of N" dialog while the charts build + upload (the slow part),
  /// then a result summary. On partial/total failure the summary offers a
  /// one-tap RETRY that re-sends only the recipients that failed.
  Future<void> _dispatchSeatAllocations(Tour t, Set<String> passengerIds) async {
    if (passengerIds.isEmpty) return;
    final progress = ValueNotifier<int>(0);
    final total = passengerIds.length;
    var dialogOpen = true;
    // Live progress dialog (non-dismissible) — updates as each chart finishes.
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SendProgressDialog(progress: progress, total: total),
    ).then((_) => dialogOpen = false));

    WaSendResult result;
    try {
      result = await WhatsAppOutbound().sendSeatAllocations(
        tour: t,
        onlyPassengerIds: passengerIds,
        onProgress: (done, _) => progress.value = done,
      );
    } catch (e) {
      if (mounted && dialogOpen) Navigator.of(context, rootNavigator: true).pop();
      progress.dispose();
      if (mounted) AppSnackBar.error(tr('notify.alloc_failed_body'));
      return;
    }
    if (mounted && dialogOpen) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();
    if (!mounted) return;

    // Mark the successfully-notified passengers so the tracker + pending count
    // update and the "Send to all pending" CTA hides once everyone's done.
    final okPhones = result.results.where((r) => r.ok).map((r) => r.to).toSet();
    final batch =
        t.passengers.where((p) => passengerIds.contains(p.id)).toList();
    final justSent = batch
        .where(
            (p) => okPhones.contains(WhatsAppCloudService.graphPhone(p.phone)))
        .map((p) => p.id)
        .toSet();
    if (justSent.isNotEmpty) {
      setState(() => _sentIds.addAll(justSent));
      // Persist the notified seat signature so a later post-lock edit re-flags
      // ONLY the changed riders for re-notify (survives reload / restart).
      unawaited(
        Get.find<TourController>().markSeatsNotified(t.id, justSent),
      );
    }

    if (result.allSent) {
      AppSnackBar.success(
        tr('notify.alloc_sent_body', namedArgs: {'count': '${result.sent}'}),
        title: tr('notify.alloc_sent_title'),
      );
      return;
    }

    // Partial or total failure → summary dialog with a retry of only the
    // recipients that didn't go through.
    final failedIds =
        batch.where((p) => !justSent.contains(p.id)).map((p) => p.id).toSet();
    final retry = await UgamDialog.confirm(
      context,
      title: result.anySent
          ? tr('notify.alloc_partial_title')
          : tr('notify.alloc_failed_title'),
      message: result.anySent
          ? '${tr('notify.alloc_partial_body', namedArgs: {
              'sent': '${result.sent}',
              'failed': '${failedIds.length}',
            })}${firstWaError(result)}'
          : '${tr('notify.alloc_failed_body')}${firstWaError(result)}',
      cancelLabel: tr('app.action.cancel'),
      confirmLabel:
          tr('notify.alloc_retry', namedArgs: {'count': '${failedIds.length}'}),
      confirmIcon: Icons.refresh_rounded,
    );
    if (retry && mounted && failedIds.isNotEmpty) {
      await _dispatchSeatAllocations(t, failedIds);
    }
  }

  /// ADMIN per-bus announcement (F4). Opens a composer where the agent picks a
  /// bus (auto-selected when there's only one) and types a free-text message,
  /// then sends it to every passenger seated on that bus via the Cloud API.
  Future<void> _openBusMessageComposer(Tour tour) async {
    final t = Get.find<TourController>().getTour(tour.id) ?? tour;
    if (t.buses.isEmpty) return;
    await UgamSheet.show<void>(
      context,
      title: tr('bus_message.composer_title'),
      builder: (sheetCtx) => _BusMessageComposer(
        buses: t.buses,
        recipientCountFor: (busId) => t.passengers
            .where((p) => p.assignedSeats.any((a) => a.busId == busId))
            .length,
        onSend: (busId, text) async {
          final result = await WhatsAppOutbound().sendBusMessage(
            tour: t,
            busId: busId,
            messageText: text,
          );
          if (!mounted) return;
          if (result.allSent) {
            AppSnackBar.success(
              tr('bus_message.sent_body', namedArgs: {'count': '${result.sent}'}),
              title: tr('bus_message.sent_title'),
            );
          } else if (result.anySent) {
            AppSnackBar.warning(
              '${tr('bus_message.partial_body', namedArgs: {
                'sent': '${result.sent}',
                'failed': '${result.failed}',
              })}${firstWaError(result)}',
              title: tr('bus_message.partial_title'),
            );
          } else if (result.results.isEmpty && result.sent == 0) {
            AppSnackBar.warning(tr('bus_message.no_recipients'));
          } else {
            AppSnackBar.error(
              '${tr('bus_message.failed_body')}${firstWaError(result)}',
              title: tr('bus_message.failed_title'),
            );
          }
        },
      ),
    );
  }

  _BusInfo _resolveBusInfo(Tour tour) {
    if (tour.buses.isEmpty) {
      return _BusInfo(
        busNo: tr('notify.not_assigned'),
        driverName: tr('notify.not_assigned'),
        driverPhone: null,
      );
    }
    return _BusInfo(
      busNo: tour.buses.map((b) => b.displayLabel).join(', '),
      driverName: tour.buses.map((b) => b.driverName).join(', '),
      driverPhone: tour.buses.first.driverPhone,
    );
  }
}

class _BusInfo {
  final String busNo;
  final String driverName;
  final String? driverPhone;
  _BusInfo({
    required this.busNo,
    required this.driverName,
    required this.driverPhone,
  });
}

// The search pill is the shared [UgamSearchField]. The private `_SearchField`
// that used to live here was a line-for-line copy of it minus the clear (×)
// button, so Notify was the one search bar in the app the user had to
// backspace out by hand.

// ─── Tour selector ────────────────────────────────────────────────────

class _TourSelector extends StatelessWidget {
  final List<Tour> tours;
  final String selectedId;
  final ValueChanged<String> onSelect;

  const _TourSelector({
    required this.tours,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final selectedIndex = tours.indexWhere((t) => t.id == selectedId);
    final currentIndex = selectedIndex < 0 ? 0 : selectedIndex;

    // UgamTabPills is a fixed segmented control built for 2–5 segments. When
    // there are more active tours than that, fall back to the shared scrolling
    // pill strip. This used to be a hand-rolled copy of [UgamSelectorPills]
    // that painted its ACTIVE pill flat `c.card` instead of the component's
    // tonal accentFill + accent ink + hairline — so past four tours the
    // selected tour lost its copper tint and stopped reading as selected.
    if (tours.length > 4) {
      return UgamSelectorPills(
        items: [for (final t in tours) UgamSelectorItem(label: t.title)],
        currentIndex: currentIndex,
        onChanged: (i) => onSelect(tours[i].id),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      child: UgamTabPills(
        currentIndex: currentIndex,
        onChanged: (i) => onSelect(tours[i].id),
        items: [for (final t in tours) UgamTabItem(label: t.title)],
      ),
    );
  }
}

// ─── Hero summary card ────────────────────────────────────────────────

class _HeroSummaryCard extends StatelessWidget {
  final Tour tour;
  final _BusInfo busInfo;
  final UgamColorSet c;

  const _HeroSummaryCard({
    required this.tour,
    required this.busInfo,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final isLocked = tour.status == TourStatus.locked;
    final handler = tour.handler;
    final locale = context.locale.toString();
    final departure = DateFormat('d MMM', locale).format(tour.departureDate);
    final departureTime =
        DateFormat('HH:mm', locale).format(tour.departureDate);
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tour.title,
                  style: UgamText.titleM.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              UgamStatusDot(
                label: isLocked ? tr('notify.status_locked') : tour.status.displayName,
                tone: isLocked ? UgamStatusTone.good : UgamStatusTone.accent,
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            '${tour.fromCity} → ${tour.toCity}',
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.event_rounded,
                  label: tr('notify.info_departure'),
                  value: '$departure · $departureTime',
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.directions_bus_rounded,
                  label: tr('notify.info_bus'),
                  value: busInfo.busNo,
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.badge_outlined,
                  label: tr('notify.info_driver'),
                  value: busInfo.driverName,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.person_pin_rounded,
                  label: tr('notify.info_handler'),
                  value: handler?.displayName ?? tr('notify.not_assigned'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoCell extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final String value;

  const _InfoCell({
    required this.c,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.tight,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: c.ink3),
              const SizedBox(width: 4),
              Text(
                label.toUpperCase(),
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: UgamText.bodyStrong.copyWith(color: c.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── Progress card ────────────────────────────────────────────────────

class _ProgressCard extends StatelessWidget {
  final UgamColorSet c;
  final int sent;
  final int total;

  const _ProgressCard({
    required this.c,
    required this.sent,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0.0 : (sent / total).clamp(0.0, 1.0);
    final done = sent >= total && total > 0;
    final color = done ? c.good : c.accent;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                done
                    ? tr('notify.progress_all_notified')
                    : tr('notify.progress_label'),
                style: UgamText.micro.copyWith(color: color),
              ),
              const Spacer(),
              Text(
                '$sent / $total',
                style: UgamText.tabular(
                  UgamText.bodyStrong.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.tight),
          Text(
            done
                ? tr('notify.progress_done_body')
                : tr(
                    'notify.progress_count_body',
                    namedArgs: {'sent': '$sent', 'total': '$total'},
                  ),
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: UgamSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: c.cardElev,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Notify passenger row ─────────────────────────────────────────────

class _NotifyRow extends StatelessWidget {
  final Passenger passenger;
  final _BusInfo busInfo;
  final bool isSent;
  final UgamColorSet c;
  final VoidCallback onSend;

  const _NotifyRow({
    required this.passenger,
    required this.busInfo,
    required this.isSent,
    required this.c,
    required this.onSend,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    final seats = passenger.assignedSeats.map((a) => a.seatId).join(', ');
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      radius: UgamRadius.row,
      child: Row(
        children: [
          // Decorative avatar — scales, so ~30 rows stop reading as a wall of
          // full-size circles while their names shrink on a small phone.
          Container(
            width: UgamScale.px(context, 40),
            height: UgamScale.px(context, 40),
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initials(passenger.name),
              style: UgamText.caption.copyWith(
                color: c.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.tight),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    // 2 lines before ellipsis — app-wide name rule, see
                    // UgamRequestRow.
                    Expanded(
                      child: Text(
                        passenger.displayName,
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    UgamStatusDot(
                      label: isSent
                          ? tr('notify.row_sent')
                          : tr('notify.row_pending'),
                      tone: isSent ? UgamStatusTone.good : UgamStatusTone.warm,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Icon(Icons.event_seat_rounded, size: 11, color: c.ink3),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        seats.isEmpty
                            ? '—'
                            : tr('notify.seat_label', namedArgs: {'seats': seats}),
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(color: c.ink2),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // Tonal per-row send, never solid gold — solid champagne is reserved
          // for the sticky send-all CTA so ~30 rows don't flood the accent.
          // The `good`/`accent` TONES on the shared [UgamIconButton] resolve to
          // exactly the goodFill/accentFill + coloured-ink pair this row used
          // to hand-roll, so the treatment is preserved and the 44pt box now
          // rides UgamScale like every other round action in the app.
          UgamIconButton(
            icon: Icons.chat_rounded,
            onTap: onSend,
            tone: isSent
                ? UgamIconButtonTone.good
                : UgamIconButtonTone.accent,
            semanticLabel: isSent
                ? tr('notify.row_sent')
                : tr('notify.row_pending'),
          ),
        ],
      ),
    );
  }
}

// ─── Sticky CTAs ──────────────────────────────────────────────────────

class _LockStickyCTA extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final Future<void> Function(Tour) onLock;
  const _LockStickyCTA({
    required this.tour,
    required this.c,
    required this.onLock,
  });

  @override
  Widget build(BuildContext context) {
    final allAssigned = tour.allSeatsAssigned;
    final hasHandler = tour.handlerId != null;
    final hasPassengers = tour.passengers.isNotEmpty;
    final canLock = allAssigned && hasHandler && hasPassengers;

    String? reason;
    if (!hasPassengers) {
      reason = tr('notify.lock_reason_no_passengers');
    } else if (!allAssigned) {
      reason = tr('notify.lock_reason_unassigned');
    } else if (!hasHandler) {
      reason = tr('notify.lock_reason_no_handler');
    }

    return UgamStickyCTA(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!canLock && reason != null)
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: Text(
                reason,
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ),
          UgamCTA(
            label: canLock
                ? tr('notify.lock_btn')
                : tr('notify.lock_btn_disabled'),
            leadingIcon: Icons.lock_rounded,
            onPressed: canLock ? () => onLock(tour) : null,
          ),
        ],
      ),
    );
  }
}

class _Check extends StatelessWidget {
  final bool done;
  final String label;
  final UgamColorSet c;

  const _Check({required this.done, required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: done ? c.goodFill : c.cardElev,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            done ? Icons.check_rounded : Icons.circle_outlined,
            size: 14,
            color: done ? c.good : c.ink3,
          ),
        ),
        const SizedBox(width: UgamSpacing.tight),
        Expanded(
          child: Text(
            label,
            style: UgamText.body.copyWith(color: done ? c.ink : c.ink2),
          ),
        ),
      ],
    );
  }
}

// ─── Message-this-bus card + composer (F4 admin path) ──────────────────

/// A tappable card in the post-lock tracker that opens the per-bus
/// announcement composer. The agent can fire a quick free-text WhatsApp to
/// everyone on one bus (e.g. "Boarding moved to Gate 3").
class _BusMessageCard extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _BusMessageCard({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // `onTap` goes THROUGH the card so it gives press feedback like the
    // equivalent card on Settings; the outer GestureDetector swallowed it.
    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          Container(
            width: UgamScale.px(context, 40),
            height: UgamScale.px(context, 40),
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.campaign_rounded,
              size: UgamScale.px(context, 19),
              color: c.accent,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('bus_message.card_title'),
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('bus_message.card_subtitle'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
        ],
      ),
    );
  }
}

/// The per-bus announcement composer sheet: a bus selector (hidden when the
/// tour has a single bus — that bus is auto-selected) and a multi-line text
/// field. On Send it routes the typed text to every seated passenger on the
/// chosen bus via [onSend] (WhatsAppOutbound.sendBusMessage) and pops.
class _BusMessageComposer extends StatefulWidget {
  final List<Bus> buses;
  final int Function(String busId) recipientCountFor;
  final Future<void> Function(String busId, String text) onSend;

  const _BusMessageComposer({
    required this.buses,
    required this.recipientCountFor,
    required this.onSend,
  });

  @override
  State<_BusMessageComposer> createState() => _BusMessageComposerState();
}

class _BusMessageComposerState extends State<_BusMessageComposer> {
  /// Null until the agent explicitly picks a bus. Deliberately NOT defaulted to
  /// `buses.first` when the tour has several: that default silently addressed a
  /// whole announcement to bus #1 whenever the agent typed one bus's text and
  /// forgot the pill, so riders on the wrong bus got the wrong bus's message.
  /// A single-bus tour has nothing to choose, so it stays auto-selected.
  String? _busId;
  final TextEditingController _textCtrl = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _busId = widget.buses.length == 1 ? widget.buses.first.id : null;
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  String _busLabel(Bus b) => b.displayLabel;

  Future<void> _send() async {
    if (_sending) return;
    final busId = _busId;
    if (busId == null) {
      AppSnackBar.error(tr('bus_message.pick_bus_first'));
      return;
    }
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      AppSnackBar.error(tr('bus_message.empty_text'));
      return;
    }

    // Meta refuses a template variable holding a line break, a tab or 5+
    // spaces — the rule that silently killed every multi-paragraph
    // announcement. Refuse it HERE, name the reason, and offer the repair,
    // rather than fanning a doomed batch out to every recipient.
    final violations = WaTemplateParams.validateOne(text);
    if (violations.isNotEmpty) {
      final fixable = WaTemplateParams.canAutoFix(text);
      final fix = await UgamDialog.confirm(
        context,
        title: tr('bus_message.invalid_title'),
        message: waViolationsText(violations),
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: fixable
            ? tr('bus_message.fix_auto')
            : tr('bus_message.invalid_edit'),
        confirmIcon: fixable ? Icons.auto_fix_high_rounded : Icons.edit_rounded,
      );
      if (fix && fixable && mounted) {
        final fixed = WaTemplateParams.sanitize(text);
        _textCtrl.value = TextEditingValue(
          text: fixed,
          selection: TextSelection.collapsed(offset: fixed.length),
        );
      }
      return;
    }

    // Name the destination bus one last time before anything leaves. The text
    // the agent types usually names a bus too, and the two can disagree — this
    // is the only place that mismatch is still recoverable.
    final busName = _busLabel(widget.buses.firstWhere((b) => b.id == busId));
    final ok = await UgamDialog.confirm(
      context,
      title: tr('bus_message.confirm_title', namedArgs: {'bus': busName}),
      message: tr('bus_message.confirm_body', namedArgs: {
        'bus': busName,
        'count': '${widget.recipientCountFor(busId)}',
      }),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('bus_message.send_btn'),
      confirmIcon: Icons.send_rounded,
    );
    if (!ok || !mounted) return;

    setState(() => _sending = true);
    try {
      await widget.onSend(busId, text);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _sending = false);
      AppSnackBar.error('${tr('bus_message.failed_body')}\n$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final multiBus = widget.buses.length > 1;
    final busId = _busId;
    final count = busId == null ? 0 : widget.recipientCountFor(busId);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('bus_message.composer_intro'),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.lg),
          if (multiBus) ...[
            Text(
              tr('bus_message.pick_bus').toUpperCase(),
              style: UgamText.micro.copyWith(color: c.ink2),
            ),
            const SizedBox(height: UgamSpacing.sm),
            // The shared pill strip — this was a THIRD hand-rolled selector in
            // one file, and its "selected" state was a faint tint with no
            // border, so on a dark screen the agent could not reliably tell
            // which bus the announcement was about to go to.
            UgamSelectorPills(
              padding: EdgeInsets.zero,
              items: [
                for (final b in widget.buses)
                  UgamSelectorItem(label: _busLabel(b)),
              ],
              currentIndex: widget.buses.indexWhere((b) => b.id == _busId),
              onChanged: (i) =>
                  setState(() => _busId = widget.buses[i].id),
            ),
            const SizedBox(height: UgamSpacing.lg),
          ],
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: UgamSpacing.md,
              vertical: UgamSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            child: Row(
              children: [
                Icon(
                  busId == null
                      ? Icons.info_outline_rounded
                      : Icons.group_rounded,
                  size: 15,
                  color: c.accent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  // Spell out WHICH bus is about to be messaged, not just how
                  // many riders: the count alone never revealed that the typed
                  // text and the selected bus disagreed.
                  child: Text(
                    busId == null
                        ? tr('bus_message.pick_bus_first')
                        : tr('bus_message.recipient_count_named', namedArgs: {
                            'bus': _busLabel(
                              widget.buses.firstWhere((b) => b.id == busId),
                            ),
                            'count': '$count',
                          }),
                    style: UgamText.caption.copyWith(color: c.accent),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.lg),
          BusMessageComposerField(controller: _textCtrl),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _sending
                ? tr('bus_message.sending')
                : tr('bus_message.send_btn'),
            leadingIcon: Icons.send_rounded,
            onPressed: (_sending || count == 0) ? null : _send,
          ),
        ],
      ),
    );
  }
}

/// Non-dismissible progress dialog shown while seat-allotment messages are
/// being prepared + sent. Tracks the chart build/upload phase (the slow part)
/// via [progress]; once it reaches [total] it shows an indeterminate spinner
/// while the batched Cloud API send finishes.
class _SendProgressDialog extends StatelessWidget {
  const _SendProgressDialog({required this.progress, required this.total});

  final ValueNotifier<int> progress;
  final int total;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return PopScope(
      canPop: false,
      child: Dialog(
        // Card surface token + grid-aligned radius/padding, matching UgamDialog
        // (this progress variant needs a non-dismissible ValueListenableBuilder
        // body, so it stays a bespoke Dialog rather than UgamDialog.show).
        backgroundColor: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.xxl,
            vertical: UgamSpacing.huge,
          ),
          child: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, _) {
              final ready = done >= total;
              final pct = total == 0 ? 0.0 : done / total;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: UgamScale.px(context, 52),
                    width: UgamScale.px(context, 52),
                    child: CircularProgressIndicator(
                      value: ready ? null : pct,
                      color: c.accent,
                      backgroundColor: c.cardElev,
                      strokeWidth: 4,
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  Text(
                    ready
                        ? tr('notify.alloc_sending_now')
                        : tr('notify.alloc_preparing', namedArgs: {
                            'done': '$done',
                            'total': '$total',
                          }),
                    textAlign: TextAlign.center,
                    style: UgamText.titleS.copyWith(color: c.ink),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
