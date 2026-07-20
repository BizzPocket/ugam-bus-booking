import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/passenger_group.dart';
import '../utils/app_snackbar.dart';
import '../widgets/group_picker.dart';

/// TASK B of the smart-seat UI: the GROUPS & PRIORITY management screen.
///
/// Two jobs, one screen, reading the live tour from
/// [TourController.getTour] / [TourController.groupsForTour]:
///
///   1. PRIORITY — every passenger row carries a star toggle. Filled WARM
///      when [Passenger.isPriorityApproved] (warm = attention, the one
///      sanctioned use of amber on this screen), hollow ink3 otherwise.
///      Tapping flips it through [TourController.setPassengerPriority].
///
///   2. GROUPS (cross-booking) — the agent links DIFFERENT passenger rows
///      that must ride one bus. A "New group" action enters a multi-select
///      mode; the rows grow a checkbox. Once 2+ are selected, a sticky
///      bottom CTA "Create group (N)" prompts for a label and then calls
///      [TourController.createGroup] + [TourController.setPassengerGroup]
///      for each member onto the new group id.
///
///   * EXISTING GROUPS render in their own section: each group shows its
///     label, a colored dot, its member names (each with a per-member
///     remove that ungroups via `setPassengerGroup(.., null)`), and a
///     delete action that drops the whole group via
///     [TourController.deleteGroup].
///
/// All colour comes from [UgamColors.of] — nothing hardcoded — and the
/// screen is dark-first per the locked design DNA. Groups use NEUTRAL /
/// palette-indexed chips (never warm); warm is reserved for the priority
/// star. The list is reactive: an Obx on the controller's `tours`
/// repaints whenever a priority flag or group membership changes.
class TourGroupsScreen extends StatefulWidget {
  const TourGroupsScreen({super.key, required this.tourId});

  final String tourId;

  @override
  State<TourGroupsScreen> createState() => _TourGroupsScreenState();
}

class _TourGroupsScreenState extends State<TourGroupsScreen> {
  /// True while the agent is picking passengers for a NEW group. Rows show
  /// a checkbox; the sticky CTA flips to "Create group (N)".
  bool _selecting = false;

  /// Ids of the passengers ticked in the current select session.
  final Set<String> _selected = <String>{};

  /// Inline progress flag while the create-group write runs.
  bool _creating = false;

  /// Free-text filter over the passenger roster (search by name / phone).
  final _searchCtrl = TextEditingController();
  String _query = '';

  /// Whether the search pill is revealed under the app bar. Search lives in
  /// the app-bar chrome (a toggle action) — same pattern as the Requests
  /// screen — instead of floating in the middle of the scroll list.
  bool _searchVisible = false;

  TourController get _ctrl => Get.find<TourController>();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchCtrl.clear();
        _query = '';
      }
    });
  }

  void _enterSelect() {
    setState(() {
      _selecting = true;
      _selected.clear();
    });
  }

  void _cancelSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelected(String passengerId) {
    setState(() {
      if (!_selected.add(passengerId)) _selected.remove(passengerId);
    });
  }

  Future<void> _togglePriority(Passenger p) async {
    // Turning priority ON is a deliberate promise (reserve a lower berth where
    // possible), so we confirm first. Turning it OFF is a direct toggle.
    if (!p.isPriorityApproved) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('priority.alert_title'),
        message: tr('priority.alert_msg'),
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: tr('priority.alert_confirm'),
        confirmIcon: Icons.star_rounded,
      );
      if (!ok) return;
    }
    await _ctrl.setPassengerPriority(
      widget.tourId,
      p.id,
      !p.isPriorityApproved,
    );
  }

  /// Prompt for a label, then create the group and attach every selected
  /// passenger to the returned group id. A cross-booking group must ride ONE
  /// bus, so a selection needing more berths than the biggest bus is blocked.
  Future<void> _createGroup() async {
    if (_selected.length < 2 || _creating) return;
    final tour = _ctrl.getTour(widget.tourId);
    if (tour != null && tour.biggestBusSeats > 0) {
      final berths = tour.passengers
          .where((p) => _selected.contains(p.id))
          .fold(0, (sum, p) => sum + p.seatBerths);
      if (berths > tour.biggestBusSeats) {
        AppSnackBar.error(tr('tour_groups.create_too_big', namedArgs: {
          'seats': '$berths',
          'cap': '${tour.biggestBusSeats}',
        }));
        return;
      }
    }
    final label = await _promptLabel();
    if (label == null || label.trim().isEmpty) return;

    setState(() => _creating = true);
    try {
      final ids = _selected.toList();
      final groupId = await _ctrl.createGroup(
        widget.tourId,
        label.trim(),
        // Distinct golden-angle colour per group (matches the seat charts);
        // without this every manually-created group shared colorIndex 0.
        colorIndex: _ctrl.groupsForTour(widget.tourId).length,
      );
      for (final pid in ids) {
        await _ctrl.setPassengerGroup(widget.tourId, pid, groupId);
      }
      if (mounted) {
        setState(() {
          _selecting = false;
          _selected.clear();
        });
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  /// Simple text dialog for the new group's label. Returns null on cancel.
  ///
  /// Pre-fills "Group N" (N = next group number) so the agent can accept a
  /// sensible default with one tap and still rename inline. Uses only the
  /// existing group count — no new logic or persistence.
  Future<String?> _promptLabel() {
    final next = _ctrl.groupsForTour(widget.tourId).length + 1;
    final textCtrl = TextEditingController(
      text: tr('tour_groups.default_group_name', namedArgs: {'n': '$next'}),
    );
    return UgamDialog.show<String>(
      context,
      title: tr('tour_groups.name_this_group'),
      content: UgamInput(
        controller: textCtrl,
        hint: tr('tour_groups.name_hint'),
        autofocus: true,
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: (dialogCtx) => [
        UgamButton(
          label: tr('app.action.cancel'),
          kind: UgamButtonKind.ghost,
          onPressed: () => Navigator.of(dialogCtx).pop(),
        ),
        UgamButton(
          label: tr('tour_groups.create'),
          onPressed: () => Navigator.of(dialogCtx).pop(textCtrl.text),
        ),
      ],
    );
  }

  /// One-tap accept of a remembered-companions suggestion.
  Future<void> _applySuggestion(List<Passenger> members) async {
    if (_creating) return;
    setState(() => _creating = true);
    try {
      await _ctrl.recreateCompanionGroup(widget.tourId, members);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _removeMember(String passengerId) =>
      _ctrl.setPassengerGroup(widget.tourId, passengerId, null);

  /// Delete the whole group after a confirm. Deleting only ungroups the
  /// members (they are NOT removed from the tour), so the copy says so.
  Future<void> _deleteGroup(PassengerGroup group) async {
    final label =
        group.label.trim().isEmpty ? tr('tour_groups.group') : group.label.trim();
    final memberCount =
        _ctrl.getTour(widget.tourId)?.passengers.where((p) => p.groupId == group.id).length ?? 0;
    final ok = await UgamDialog.confirm(
      context,
      title: tr('tour_groups.delete_group_title', namedArgs: {'name': label}),
      message: tr('tour_groups.delete_group_body', namedArgs: {'n': '$memberCount'}),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('tour_groups.delete_group'),
      destructive: true,
      confirmIcon: Icons.delete_outline_rounded,
    );
    if (!ok) return;
    await _ctrl.deleteGroup(widget.tourId, group.id);
  }

  /// Open the add-member picker for [group] — an ungrouped-passenger roster
  /// with search; candidates that would overflow one bus are blocked there.
  void _openAddMember(PassengerGroup group) {
    final tour = _ctrl.getTour(widget.tourId);
    if (tour == null) return;
    AddMemberToGroupSheet.show(context, tour: tour, group: group);
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              title: _selecting
                  ? tr('tour_groups.select_passengers')
                  : tr('tour_groups.title'),
              actions: [
                if (!_selecting)
                  UgamAppBarAction(
                    icon: _searchVisible
                        ? Icons.search_off_rounded
                        : Icons.search_rounded,
                    active: _searchVisible,
                    onTap: _toggleSearch,
                    tooltip: tr('tour_groups.search_hint'),
                  ),
                UgamAppBarAction(
                  icon: _selecting
                      ? Icons.close_rounded
                      : Icons.group_add_rounded,
                  active: !_selecting,
                  onTap: _selecting ? _cancelSelect : _enterSelect,
                  tooltip: _selecting
                      ? tr('app.action.cancel')
                      : tr('tour_groups.new_group'),
                ),
              ],
            ),
            // Search lives in the app-bar chrome: revealed as a pinned pill
            // right below the bar, never scrolling away inside the list.
            AnimatedSize(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              child: (_searchVisible && !_selecting)
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.gutter,
                        0,
                        UgamSpacing.gutter,
                        UgamSpacing.sm,
                      ),
                      child: UgamSearchField(
                        controller: _searchCtrl,
                        hint: tr('tour_groups.search_hint'),
                        autofocus: true,
                        onChanged: (v) => setState(() => _query = v.trim()),
                        onClear: () => setState(() => _query = ''),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: Obx(() {
                final tour = _ctrl.getTour(widget.tourId);
                if (tour == null) {
                  return Center(
                    child: Text(
                      tr('tour_groups.tour_not_found'),
                      style: UgamText.body.copyWith(color: c.ink2),
                    ),
                  );
                }

                final groups = _ctrl.groupsForTour(widget.tourId);
                // Quick lookup: group id → group, for the per-row tag.
                final groupById = <String, PassengerGroup>{
                  for (final g in groups) g.id: g,
                };
                // Group id → 1-based order, so a passenger's tag shows the SAME
                // number as that group's card badge.
                final groupNumberById = <String, int>{
                  for (var i = 0; i < groups.length; i++) groups[i].id: i + 1,
                };

                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                    UgamSpacing.gutter,
                    UgamSpacing.xl,
                  ),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // ── Suggested groups (remembered companions) ─────────
                    // Surfaces clusters of returning customers who travelled
                    // together on a past (now-deleted) tour and are all still
                    // ungrouped here. Hidden during select mode.
                    if (!_selecting) ...[
                      for (final cluster
                          in _ctrl.suggestedCompanionGroups(widget.tourId)) ...[
                        _SuggestionCard(
                          members: cluster,
                          busy: _creating,
                          onApply: () => _applySuggestion(cluster),
                          c: c,
                        ),
                        const SizedBox(height: UgamSpacing.sm),
                      ],
                    ],

                    // ── Existing groups ──────────────────────────────────
                    if (groups.isNotEmpty) ...[
                      _SectionHeader(
                        label: tr('tour_groups.section_groups'),
                        count: groups.length,
                        c: c,
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      for (var i = 0; i < groups.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.sm,
                          ),
                          child: _GroupCard(
                            group: groups[i],
                            number: i + 1,
                            members: tour.passengers
                                .where((p) => p.groupId == groups[i].id)
                                .toList(),
                            fit: GroupFit.of(tour, groups[i].id),
                            onDelete: () => _deleteGroup(groups[i]),
                            onRemoveMember: _removeMember,
                            onAddMember: () => _openAddMember(groups[i]),
                            c: c,
                          ),
                        ),
                      const SizedBox(height: UgamSpacing.xl),
                    ],

                    // ── Passenger roster ─────────────────────────────────
                    _SectionHeader(
                      label: tr('tour_groups.section_passengers'),
                      count: tour.passengers.length,
                      c: c,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    if (tour.passengers.isEmpty)
                      const _NoPassengers()
                    else ...[
                      ...() {
                        final q = _query.toLowerCase();
                        final roster = q.isEmpty
                            ? tour.passengers
                            : tour.passengers
                                .where((p) =>
                                    p.name.toLowerCase().contains(q) ||
                                    p.phone.toLowerCase().contains(q))
                                .toList();
                        if (roster.isEmpty) {
                          return <Widget>[
                            _NoSearchResults(query: _query),
                          ];
                        }
                        return roster
                            .map<Widget>(
                              (p) => Padding(
                                padding: const EdgeInsets.only(
                                  bottom: UgamSpacing.xs + 2,
                                ),
                                child: _PassengerRow(
                                  passenger: p,
                                  group: p.groupId != null
                                      ? groupById[p.groupId]
                                      : null,
                                  groupNumber: p.groupId != null
                                      ? groupNumberById[p.groupId]
                                      : null,
                                  selecting: _selecting,
                                  selected: _selected.contains(p.id),
                                  onSelectToggle: () => _toggleSelected(p.id),
                                  onPriorityToggle: () => _togglePriority(p),
                                  c: c,
                                ),
                              ),
                            )
                            .toList();
                      }(),
                    ],
                  ],
                );
              }),
            ),

            // Sticky CTA only while building a new group. Shows the running
            // seat count and blocks creation when the selection can't ride one
            // bus (the "41 in a 36-seat bus" rule).
            if (_selecting)
              Obx(() {
                final tour = _ctrl.getTour(widget.tourId);
                final berths = tour == null
                    ? 0
                    : tour.passengers
                        .where((p) => _selected.contains(p.id))
                        .fold(0, (sum, p) => sum + p.seatBerths);
                final biggest = tour?.biggestBusSeats ?? 0;
                final tooBig = biggest > 0 && berths > biggest;
                final enough = _selected.length >= 2;
                final label = !enough
                    ? tr('tour_groups.pick_two_or_more')
                    : tooBig
                        ? tr('tour_groups.create_too_big', namedArgs: {
                            'seats': '$berths',
                            'cap': '$biggest',
                          })
                        : tr('tour_groups.create_group_seats', namedArgs: {
                            'n': '${_selected.length}',
                            'seats': '$berths',
                          });
                return UgamStickyCTA(
                  child: UgamCTA(
                    label: label,
                    leadingIcon: Icons.group_add_rounded,
                    loading: _creating,
                    onPressed: (enough && !tooBig) ? _createGroup : null,
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

// ─── Section header ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  const _SectionHeader({
    required this.label,
    required this.count,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            '$count',
            style: UgamText.tabular(UgamText.micro.copyWith(color: c.ink2)),
          ),
        ],
      ),
    );
  }
}

// ─── Passenger row ─────────────────────────────────────────────────────────

class _PassengerRow extends StatelessWidget {
  final Passenger passenger;
  final PassengerGroup? group;
  final int? groupNumber;
  final bool selecting;
  final bool selected;
  final VoidCallback onSelectToggle;
  final VoidCallback onPriorityToggle;
  final UgamColorSet c;

  const _PassengerRow({
    required this.passenger,
    required this.group,
    required this.groupNumber,
    required this.selecting,
    required this.selected,
    required this.onSelectToggle,
    required this.onPriorityToggle,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final approved = passenger.isPriorityApproved;
    return UgamCard.plain(
      // In select mode the whole row toggles selection; otherwise it is a
      // passive row (the star is the only action).
      onTap: selecting ? onSelectToggle : null,
      radius: UgamRadius.row,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      child: Row(
        children: [
          if (selecting) ...[
            _Checkbox(checked: selected, c: c),
            const SizedBox(width: UgamSpacing.sm),
          ],
          // Avatar with the passenger's initial.
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initial(passenger.name),
              style: UgamText.bodyStrong.copyWith(color: c.ink2),
            ),
          ),
          const SizedBox(width: UgamSpacing.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Name + group tag share one line (tag sits BESIDE the name).
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        passenger.name.isEmpty
                            ? tr('tour_groups.unnamed')
                            : passenger.name,
                        style: UgamText.titleS.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (group != null && groupNumber != null) ...[
                      const SizedBox(width: UgamSpacing.sm),
                      GroupTag(
                        number: groupNumber!,
                        colorIndex: group!.colorIndex,
                        label: group!.label.isEmpty
                            ? tr('tour_groups.group')
                            : group!.label,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  passenger.requestSummary,
                  style: UgamText.caption.copyWith(color: c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.xs),
          // Priority star — warm is the sanctioned attention colour here.
          if (!selecting)
            GestureDetector(
              onTap: onPriorityToggle,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: approved ? c.warmFill : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  approved ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 22,
                  color: approved ? c.warm : c.ink3,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _initial(String name) {
    final t = name.trim();
    return t.isEmpty ? '?' : t.characters.first.toUpperCase();
  }
}

class _Checkbox extends StatelessWidget {
  final bool checked;
  final UgamColorSet c;

  const _Checkbox({required this.checked, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: checked ? c.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: checked ? c.accent : c.border, width: 1.6),
      ),
      alignment: Alignment.center,
      child: checked
          ? Icon(Icons.check_rounded, size: 15, color: c.onAccent)
          : null,
    );
  }
}

// ─── Suggested-group card (remembered companions) ──────────────────────────

class _SuggestionCard extends StatelessWidget {
  final List<Passenger> members;
  final bool busy;
  final VoidCallback onApply;
  final UgamColorSet c;

  const _SuggestionCard({
    required this.members,
    required this.busy,
    required this.onApply,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final names = members
        .map((m) =>
            m.name.trim().isEmpty ? tr('tour_groups.unnamed') : m.name.trim())
        .join(' · ');
    return UgamCard.plain(
      tone: UgamCardTone.accent,
      radius: UgamRadius.row,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.history_rounded, size: 18, color: c.accent),
          ),
          const SizedBox(width: UgamSpacing.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('tour_groups.usually_travel_together'),
                  style: UgamText.micro.copyWith(color: c.accent),
                ),
                const SizedBox(height: 2),
                Text(
                  names,
                  style: UgamText.body.copyWith(color: c.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          UgamButton(
            label: tr('tour_groups.group'),
            icon: Icons.group_add_rounded,
            kind: UgamButtonKind.tonal,
            loading: busy,
            onPressed: busy ? null : onApply,
          ),
        ],
      ),
    );
  }
}

// ─── Existing-group card ───────────────────────────────────────────────────

class _GroupCard extends StatelessWidget {
  final PassengerGroup group;
  final int number;
  final List<Passenger> members;
  final GroupFit fit;
  final VoidCallback onDelete;
  final Future<void> Function(String passengerId) onRemoveMember;
  final VoidCallback onAddMember;
  final UgamColorSet c;

  const _GroupCard({
    required this.group,
    required this.number,
    required this.members,
    required this.fit,
    required this.onDelete,
    required this.onRemoveMember,
    required this.onAddMember,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // Capacity tone: green with room, warm when exactly full, red when over.
    final tone = fit.isOver
        ? c.danger
        : fit.isFull
            ? c.warm
            : c.good;
    final seatsText = fit.hasBus
        ? tr('tour_groups.seats_summary', namedArgs: {
            'used': '${fit.used}',
            'cap': '${fit.capacity}',
          })
        : tr('tour_groups.seats_plain', namedArgs: {'n': '${fit.used}'});
    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Header: numbered colour badge · name · seats · delete ────────
          Row(
            children: [
              GroupNumberBadge(
                number: number,
                colorIndex: group.colorIndex,
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Text(
                  group.label.isEmpty ? tr('tour_groups.group') : group.label,
                  style: UgamText.titleS.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // Capacity readout: group berths vs the biggest single bus.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
                child: Text(
                  seatsText,
                  style: UgamText.micro.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.xs),
              // Delete the whole group — compact danger button (confirms first).
              UgamIconButton(
                icon: Icons.delete_outline_rounded,
                tone: UgamIconButtonTone.danger,
                size: 32,
                iconSize: 17,
                onTap: onDelete,
                semanticLabel: tr('tour_groups.delete_group'),
              ),
            ],
          ),
          // Over-capacity warning only — a compact inline note, no banner slab.
          if (fit.isOver) ...[
            const SizedBox(height: UgamSpacing.xs + 2),
            Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 13, color: c.danger),
                const SizedBox(width: UgamSpacing.xs),
                Expanded(
                  child: Text(
                    tr('tour_groups.wont_fit', namedArgs: {
                      'used': '${fit.used}',
                      'cap': '${fit.capacity}',
                    }),
                    style:
                        UgamText.micro.copyWith(color: c.danger, height: 1.2),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: UgamSpacing.sm + 2),
          // ── Members as removable chips + an inline add chip ──────────────
          Wrap(
            spacing: UgamSpacing.sm,
            runSpacing: UgamSpacing.sm,
            children: [
              for (final m in members)
                _MemberChip(
                  name: m.name.isEmpty ? tr('tour_groups.unnamed') : m.name,
                  onRemove: () => onRemoveMember(m.id),
                  c: c,
                ),
              _AddChip(
                enabled: !fit.isFull,
                onTap: onAddMember,
                c: c,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A single group member rendered as a compact removable pill: name + a small
/// × that ungroups it. Replaces the old full-width member row with its giant
/// circular delete button.
class _MemberChip extends StatelessWidget {
  final String name;
  final VoidCallback onRemove;
  final UgamColorSet c;

  const _MemberChip({
    required this.name,
    required this.onRemove,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: UgamSpacing.md, right: UgamSpacing.xs),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              name,
              style: UgamText.caption.copyWith(
                color: c.ink2,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onRemove,
            child: Semantics(
              button: true,
              label: tr('tour_groups.remove_member'),
              child: Padding(
                padding: const EdgeInsets.all(UgamSpacing.xs + 1),
                child: Icon(Icons.close_rounded, size: 14, color: c.ink3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tonal "+ Add" chip that sits inline at the end of the member chips.
/// Disabled (and relabelled) when the group already fills the biggest bus —
/// the capacity block from the user's "41 in a 36-seat bus" rule.
class _AddChip extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _AddChip({
    required this.enabled,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? c.accent : c.ink3;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Semantics(
        button: true,
        enabled: enabled,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
          decoration: BoxDecoration(
            color: enabled ? c.accentFill : c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                enabled ? Icons.person_add_alt_rounded : Icons.block_rounded,
                size: 15,
                color: fg,
              ),
              const SizedBox(width: UgamSpacing.xs + 2),
              Text(
                enabled
                    ? tr('tour_groups.add_member')
                    : tr('tour_groups.full_for_bus'),
                style: UgamText.caption.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Empty states ─────────────────────────────────────────────────────────

class _NoSearchResults extends StatelessWidget {
  final String query;

  const _NoSearchResults({required this.query});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
      child: UgamEmpty(
        icon: Icons.search_off_rounded,
        title: tr('tour_groups.no_search_results', namedArgs: {'q': query}),
      ),
    );
  }
}

class _NoPassengers extends StatelessWidget {
  const _NoPassengers();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
      child: UgamEmpty(
        icon: Icons.people_outline_rounded,
        title: tr('tour_groups.no_passengers_yet'),
      ),
    );
  }
}
