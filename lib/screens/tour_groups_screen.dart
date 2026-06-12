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

  TourController get _ctrl => Get.find<TourController>();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
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
  Future<String?> _promptLabel() {
    final textCtrl = TextEditingController();
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

  Future<void> _deleteGroup(String groupId) =>
      _ctrl.deleteGroup(widget.tourId, groupId);

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
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              selecting: _selecting,
              onNewGroup: _enterSelect,
              onCancelSelect: _cancelSelect,
              c: c,
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
                // Quick lookup: group id → group, for the per-row chip.
                final groupById = <String, PassengerGroup>{
                  for (final g in groups) g.id: g,
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
                        const SizedBox(height: UgamSpacing.md),
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
                      for (final g in groups)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.md,
                          ),
                          child: _GroupCard(
                            group: g,
                            members: tour.passengers
                                .where((p) => p.groupId == g.id)
                                .toList(),
                            fit: GroupFit.of(tour, g.id),
                            onDelete: () => _deleteGroup(g.id),
                            onRemoveMember: _removeMember,
                            onAddMember: () => _openAddMember(g),
                            c: c,
                          ),
                        ),
                      const SizedBox(height: UgamSpacing.md),
                    ],

                    // ── Passenger roster ─────────────────────────────────
                    _SectionHeader(
                      label: tr('tour_groups.section_passengers'),
                      count: tour.passengers.length,
                      c: c,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    if (tour.passengers.isEmpty)
                      _NoPassengers(c: c)
                    else ...[
                      // Search the full roster by name / phone, so the agent
                      // can jump to a person on a long tour.
                      _RosterSearchField(
                        controller: _searchCtrl,
                        onChanged: (v) => setState(() => _query = v.trim()),
                        c: c,
                      ),
                      const SizedBox(height: UgamSpacing.sm),
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
                            _NoSearchResults(query: _query, c: c),
                          ];
                        }
                        return roster
                            .map<Widget>(
                              (p) => Padding(
                                padding: const EdgeInsets.only(
                                  bottom: UgamSpacing.sm,
                                ),
                                child: _PassengerRow(
                                  passenger: p,
                                  group: p.groupId != null
                                      ? groupById[p.groupId]
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

// ─── Header ────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final bool selecting;
  final VoidCallback onNewGroup;
  final VoidCallback onCancelSelect;
  final UgamColorSet c;

  const _Header({
    required this.selecting,
    required this.onNewGroup,
    required this.onCancelSelect,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.cardElev,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 19, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              selecting
                  ? tr('tour_groups.select_passengers')
                  : tr('tour_groups.title'),
              style: UgamText.titleL.copyWith(color: c.ink, fontSize: 20),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // New-group / cancel-select action.
          GestureDetector(
            onTap: selecting ? onCancelSelect : onNewGroup,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: selecting ? c.cardElev : c.accentFill,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    selecting ? Icons.close_rounded : Icons.group_add_rounded,
                    size: 16,
                    color: selecting ? c.ink2 : c.accent,
                  ),
                  const SizedBox(width: UgamSpacing.xs + 2),
                  Text(
                    selecting
                        ? tr('app.action.cancel')
                        : tr('tour_groups.new_group'),
                    style: UgamText.bodyStrong.copyWith(
                      color: selecting ? c.ink2 : c.accent,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
  final bool selecting;
  final bool selected;
  final VoidCallback onSelectToggle;
  final VoidCallback onPriorityToggle;
  final UgamColorSet c;

  const _PassengerRow({
    required this.passenger,
    required this.group,
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
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.md,
      ),
      child: Row(
        children: [
          if (selecting) ...[
            _Checkbox(checked: selected, c: c),
            const SizedBox(width: UgamSpacing.md),
          ],
          // Avatar with the passenger's initial.
          Container(
            width: 38,
            height: 38,
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
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  passenger.name.isEmpty
                      ? tr('tour_groups.unnamed')
                      : passenger.name,
                  style: UgamText.titleS.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  passenger.requestSummary,
                  style: UgamText.caption.copyWith(color: c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (group != null) ...[
                  const SizedBox(height: UgamSpacing.sm),
                  _GroupChip(group: group!, c: c),
                ],
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // Priority star — warm is the sanctioned attention colour here.
          if (!selecting)
            GestureDetector(
              onTap: onPriorityToggle,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 40,
                height: 40,
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
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(color: c.accent.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(11),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.history_rounded, size: 19, color: c.accent),
          ),
          const SizedBox(width: UgamSpacing.md),
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
                  style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          GestureDetector(
            onTap: busy ? null : onApply,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: c.accent,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: busy
                  ? SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.onAccent,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.group_add_rounded,
                            size: 15, color: c.onAccent),
                        const SizedBox(width: UgamSpacing.xs + 2),
                        Text(
                          tr('tour_groups.group'),
                          style: UgamText.bodyStrong
                              .copyWith(color: c.onAccent, fontSize: 13),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Group chip (per-row, neutral / palette dot) ───────────────────────────

class _GroupChip extends StatelessWidget {
  final PassengerGroup group;
  final UgamColorSet c;

  const _GroupChip({required this.group, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.sm + 2,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GroupDot(colorIndex: group.colorIndex),
          const SizedBox(width: UgamSpacing.xs + 2),
          Text(
            group.label.isEmpty ? tr('tour_groups.group') : group.label,
            style: UgamText.caption.copyWith(
              color: c.ink2,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── Existing-group card ───────────────────────────────────────────────────

class _GroupCard extends StatelessWidget {
  final PassengerGroup group;
  final List<Passenger> members;
  final GroupFit fit;
  final VoidCallback onDelete;
  final Future<void> Function(String passengerId) onRemoveMember;
  final VoidCallback onAddMember;
  final UgamColorSet c;

  const _GroupCard({
    required this.group,
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
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              GroupDot(colorIndex: group.colorIndex),
              const SizedBox(width: UgamSpacing.sm),
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
                  fit.hasBus
                      ? tr('tour_groups.seats_summary', namedArgs: {
                          'used': '${fit.used}',
                          'cap': '${fit.capacity}',
                        })
                      : tr('tour_groups.seats_plain',
                          namedArgs: {'n': '${fit.used}'}),
                  style: UgamText.micro.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // Delete the whole group.
              GestureDetector(
                onTap: onDelete,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: 17,
                    color: c.ink3,
                  ),
                ),
              ),
            ],
          ),
          // Over / full banner so the agent sees a group that can't ride one bus.
          if (fit.hasBus && (fit.isOver || fit.isFull)) ...[
            const SizedBox(height: UgamSpacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              child: Row(
                children: [
                  Icon(
                    fit.isOver
                        ? Icons.error_outline_rounded
                        : Icons.info_outline_rounded,
                    size: 15,
                    color: tone,
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Expanded(
                    child: Text(
                      fit.isOver
                          ? tr('tour_groups.wont_fit', namedArgs: {
                              'used': '${fit.used}',
                              'cap': '${fit.capacity}',
                            })
                          : tr('tour_groups.full_for_bus'),
                      style: UgamText.caption.copyWith(color: tone, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: UgamSpacing.md),
          if (members.isEmpty)
            Text(
              tr('tour_groups.no_members_yet'),
              style: UgamText.caption.copyWith(color: c.ink3),
            )
          else
            ...members.map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: UgamSpacing.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.name.isEmpty ? tr('tour_groups.unnamed') : m.name,
                        style: UgamText.body.copyWith(color: c.ink2),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => onRemoveMember(m.id),
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: c.ink3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: UgamSpacing.md),
          // Add a new member — disabled once the group is full for one bus.
          _AddMemberButton(
            enabled: !fit.isFull,
            onTap: onAddMember,
            c: c,
          ),
        ],
      ),
    );
  }
}

/// Tonal "Add member" action on a group card. Disabled (and relabelled) when
/// the group already fills the biggest bus — the capacity block from the
/// user's "41 in a 36-seat bus" rule.
class _AddMemberButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _AddMemberButton({
    required this.enabled,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          height: 42,
          decoration: BoxDecoration(
            color: c.accentFill,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                enabled ? Icons.person_add_alt_rounded : Icons.block_rounded,
                size: 17,
                color: enabled ? c.accent : c.ink3,
              ),
              const SizedBox(width: UgamSpacing.sm),
              Text(
                enabled
                    ? tr('tour_groups.add_member')
                    : tr('tour_groups.full_for_bus'),
                style: UgamText.bodyStrong.copyWith(
                  color: enabled ? c.accent : c.ink3,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Roster search ─────────────────────────────────────────────────────────

/// Filled search field over the full passenger roster (by name / phone). Lives
/// inline at the top of the Passengers section so the agent can jump to anyone
/// on a long tour.
class _RosterSearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final UgamColorSet c;

  const _RosterSearchField({
    required this.controller,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
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
              onChanged: onChanged,
              style: UgamText.body.copyWith(color: c.ink, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: tr('tour_groups.search_hint'),
                hintStyle: UgamText.body.copyWith(color: c.ink3, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoSearchResults extends StatelessWidget {
  final String query;
  final UgamColorSet c;

  const _NoSearchResults({required this.query, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
      child: Center(
        child: Text(
          tr('tour_groups.no_search_results', namedArgs: {'q': query}),
          style: UgamText.body.copyWith(color: c.ink3),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// ─── Empty state ──────────────────────────────────────────────────────────

class _NoPassengers extends StatelessWidget {
  final UgamColorSet c;

  const _NoPassengers({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline_rounded, size: 40, color: c.ink3),
            const SizedBox(height: UgamSpacing.md),
            Text(
              tr('tour_groups.no_passengers_yet'),
              style: UgamText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
