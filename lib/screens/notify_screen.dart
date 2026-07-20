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
import '../services/whatsapp_cloud_service.dart';
import '../services/whatsapp_outbound.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';

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
                      ? _SearchField(
                          c: c,
                          controller: _searchCtrl,
                          onChanged: (v) => setState(() => _query = v.trim()),
                        )
                      : const SizedBox.shrink(),
                ),
              if (!_scoped && activeTours.length > 1)
                _TourSelector(
                  c: c,
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
          final seatedCount =
              tour.passengers.where((p) => p.assignedSeats.isNotEmpty).length;
          final pendingCount = tour.passengers
              .where((p) => p.assignedSeats.isNotEmpty)
              .where((p) => !_sentIds.contains(p.id))
              .length;
          // No seated riders → nothing to send at all.
          if (seatedCount <= 0) return const SizedBox.shrink();
          // Once the lock-time send has marked everyone as sent the CTA used to
          // vanish, leaving no obvious way to re-broadcast the seat chart — the
          // "notify to send the chart again" complaint. Keep a persistent
          // re-send action instead: it re-dispatches the seat chart to EVERY
          // seated rider (_sendSeatAllocations already targets all seated).
          final resendAll = pendingCount <= 0;
          return UgamStickyCTA(
            child: UgamCTA(
              label: resendAll
                  ? tr('notify.resend_all')
                  : tr('notify.send_all_pending'),
              leadingIcon:
                  resendAll ? Icons.send_rounded : Icons.chat_rounded,
              trailingValue: resendAll ? null : '$pendingCount',
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
        24,
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
              const SizedBox(height: UgamSpacing.sm + 2),
          ],
      ],
    );
  }

  // ── Lock gate (pre-lock) ───────────────────────────────────────
  Widget _buildLockGate({required Tour tour, required UgamColorSet c}) {
    final allAssigned = tour.allSeatsAssigned;
    final hasHandler = tour.handlerId != null;
    final hasPassengers = tour.passengers.isNotEmpty;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        24,
      ),
      children: [
        _HeroSummaryCard(tour: tour, busInfo: _resolveBusInfo(tour), c: c),
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
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.lock_outline_rounded,
                      size: 19,
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
                          style: UgamText.titleM.copyWith(
                            color: c.ink,
                            fontSize: 17,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('notify.lock_gate_body'),
                          style: UgamText.caption.copyWith(
                            color: c.ink2,
                            fontSize: 12,
                          ),
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
    debugPrint('[WA] _lockTour tapped: tour=${tour.id} '
        'passengers=${tour.passengers.length}');
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('notify.lock_dialog_title'),
      message: tr(
        'notify.lock_dialog_body',
        namedArgs: {'count': tour.passengers.length.toString()},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('notify.lock_dialog_lock'),
      confirmIcon: Icons.lock_rounded,
    );
    debugPrint('[WA] _lockTour confirm dialog => $confirmed');
    if (!confirmed) return;
    await Get.find<TourController>().lockTour(tour.id);
    if (!mounted) return;
    // No green "locked" toast here — the locked status card + the sticky CTA
    // already make the new state obvious, so the toast was redundant noise.

    // Phase 8 — push each seated passenger their seat allocation via the Cloud
    // API (seat_allotment template).
    debugPrint('[WA] _lockTour: locked, now calling _sendSeatAllocations');
    await _sendSeatAllocations(tour);
  }

  Future<void> _sendSeatAllocations(Tour tour) async {
    // Use the FRESHEST tour from the controller — the passed snapshot can be
    // stale (captured before the seat plan was applied/persisted), which would
    // make the send think nobody is seated and bail out silently.
    final t = Get.find<TourController>().getTour(tour.id) ?? tour;
    final seated =
        t.passengers.where((p) => p.assignedSeats.isNotEmpty).toList();
    debugPrint('[WA] _sendSeatAllocations: tour=${t.id} '
        'passengers=${t.passengers.length} seated=${seated.length}');
    if (seated.isEmpty) {
      AppSnackBar.error(tr('notify.no_seated_passengers'));
      return;
    }

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
    debugPrint('[WA] _sendSeatAllocations confirm dialog => $ok');
    if (!ok) return;

    await _dispatchSeatAllocations(t, seated.map((p) => p.id).toSet());
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

    debugPrint('[WA] _dispatchSeatAllocations result: '
        'sent=${result.sent} failed=${result.failed} '
        'results=${result.results.map((r) => '${r.to}:${r.ok ? 'ok' : r.error}').toList()}');

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
    if (justSent.isNotEmpty) setState(() => _sentIds.addAll(justSent));

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
            })}${_firstError(result)}'
          : '${tr('notify.alloc_failed_body')}${_firstError(result)}',
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
              })}${_firstError(result)}',
              title: tr('bus_message.partial_title'),
            );
          } else if (result.results.isEmpty && result.sent == 0) {
            AppSnackBar.warning(tr('bus_message.no_recipients'));
          } else {
            AppSnackBar.error(
              '${tr('bus_message.failed_body')}${_firstError(result)}',
              title: tr('bus_message.failed_title'),
            );
          }
        },
      ),
    );
  }

  /// First Meta error reason across the batch (e.g. "(#131030) Recipient phone
  /// number not in allowed list"), prefixed with a newline — or empty if none.
  /// Surfaces the exact cause in the snackbar instead of a generic failure.
  String _firstError(WaSendResult result) {
    for (final r in result.results) {
      if (!r.ok && (r.error ?? '').isNotEmpty) return '\n${r.error}';
    }
    return '';
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

// ─── Search field ─────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final UgamColorSet c;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({
    required this.c,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 18, color: c.ink2),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                onChanged: onChanged,
                style: UgamText.body.copyWith(color: c.ink, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: tr('notify.search_hint'),
                  hintStyle: UgamText.body.copyWith(
                    color: c.ink3,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Tour selector ────────────────────────────────────────────────────

class _TourSelector extends StatelessWidget {
  final UgamColorSet c;
  final List<Tour> tours;
  final String selectedId;
  final ValueChanged<String> onSelect;

  const _TourSelector({
    required this.c,
    required this.tours,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final selectedIndex = tours.indexWhere((t) => t.id == selectedId);
    final currentIndex = selectedIndex < 0 ? 0 : selectedIndex;

    // UgamTabPills is a fixed segmented control built for 2–4 segments. When
    // there are more active tours than that, fall back to a horizontally
    // scrollable pill row so we never trip the component's assert.
    if (tours.length > 4) {
      return SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
          itemCount: tours.length,
          separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
          itemBuilder: (_, i) {
            final t = tours[i];
            final isActive = t.id == selectedId;
            return GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                onSelect(t.id);
              },
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: UgamMotion.tab,
                curve: UgamMotion.easeOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.lg,
                  vertical: UgamSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: isActive ? c.card : c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
                alignment: Alignment.center,
                child: Text(
                  t.title,
                  style: UgamText.bodyStrong.copyWith(
                    color: isActive ? c.ink : c.ink2,
                    fontSize: 12.5,
                  ),
                ),
              ),
            );
          },
        ),
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
                  style: UgamText.titleL.copyWith(color: c.ink, fontSize: 19),
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
            style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
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
        vertical: UgamSpacing.sm + 2,
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
                style: UgamText.micro.copyWith(color: c.ink3, fontSize: 9.5),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
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
                style: UgamText.micro.copyWith(color: color, fontSize: 10),
              ),
              const Spacer(),
              Text(
                '$sent / $total',
                style: UgamText.tabular(
                  UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm + 2),
          Text(
            done
                ? tr('notify.progress_done_body')
                : tr(
                    'notify.progress_count_body',
                    namedArgs: {'sent': '$sent', 'total': '$total'},
                  ),
            style: UgamText.titleM.copyWith(color: c.ink, fontSize: 18),
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
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initials(passenger.name),
              style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12),
            ),
          ),
          const SizedBox(width: UgamSpacing.md - 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        passenger.displayName,
                        style: UgamText.bodyStrong.copyWith(
                          color: c.ink,
                          fontSize: 13.5,
                        ),
                        maxLines: 1,
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
                          UgamText.caption.copyWith(
                            color: c.ink2,
                            fontSize: 11.5,
                          ),
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
          // Tonal per-row send (accentFill + coloured ink), never solid gold —
          // solid champagne is reserved for the sticky send-all CTA so ~30 rows
          // don't flood the accent. 44px hit area for comfortable tapping.
          GestureDetector(
            onTap: onSend,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isSent ? c.goodFill : c.accentFill,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.chat_rounded,
                size: 18,
                color: isSent ? c.good : c.accent,
              ),
            ),
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
                style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
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
        const SizedBox(width: UgamSpacing.md - 2),
        Expanded(
          child: Text(
            label,
            style: UgamText.body.copyWith(
              color: done ? c.ink : c.ink2,
              fontSize: 13.5,
            ),
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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.campaign_rounded, size: 19, color: c.accent),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('bus_message.card_title'),
                    style: UgamText.bodyStrong.copyWith(
                      color: c.ink,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('bus_message.card_subtitle'),
                    style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
          ],
        ),
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
  late String _busId;
  final TextEditingController _textCtrl = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _busId = widget.buses.first.id;
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  String _busLabel(Bus b) => b.displayLabel;

  Future<void> _send() async {
    if (_sending) return;
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      AppSnackBar.error(tr('bus_message.empty_text'));
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.onSend(_busId, text);
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
    final count = widget.recipientCountFor(_busId);
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
            Wrap(
              spacing: UgamSpacing.sm,
              runSpacing: UgamSpacing.sm,
              children: [
                for (final b in widget.buses)
                  GestureDetector(
                    onTap: () => setState(() => _busId = b.id),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UgamSpacing.lg,
                        vertical: UgamSpacing.sm + 2,
                      ),
                      decoration: BoxDecoration(
                        color: _busId == b.id ? c.accentFill : c.cardElev,
                        borderRadius: BorderRadius.circular(UgamRadius.chip),
                      ),
                      child: Text(
                        _busLabel(b),
                        style: UgamText.caption.copyWith(
                          color: _busId == b.id ? c.accent : c.ink2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
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
                Icon(Icons.group_rounded, size: 15, color: c.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    tr(
                      'bus_message.recipient_count',
                      namedArgs: {'count': '$count'},
                    ),
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
            vertical: UgamSpacing.xxl + UgamSpacing.sm,
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
                    height: 52,
                    width: 52,
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
