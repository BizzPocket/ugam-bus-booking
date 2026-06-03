import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/passenger_group.dart';

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

  TourController get _ctrl => Get.find<TourController>();

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
    await _ctrl.setPassengerPriority(
      widget.tourId,
      p.id,
      !p.isPriorityApproved,
    );
  }

  /// Prompt for a label, then create the group and attach every selected
  /// passenger to the returned group id.
  Future<void> _createGroup() async {
    if (_selected.length < 2 || _creating) return;
    final label = await _promptLabel();
    if (label == null || label.trim().isEmpty) return;

    setState(() => _creating = true);
    try {
      final ids = _selected.toList();
      final groupId = await _ctrl.createGroup(widget.tourId, label.trim());
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
    final c = UgamColors.of(context);
    final textCtrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: c.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(UgamRadius.card),
          ),
          title: Text(
            'Name this group',
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          content: UgamInput(
            controller: textCtrl,
            hint: 'e.g. Patel family',
            autofocus: true,
            onSubmitted: (v) => Navigator.of(dialogCtx).pop(v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(
                'Cancel',
                style: UgamText.bodyStrong.copyWith(color: c.ink2),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(textCtrl.text),
              child: Text(
                'Create',
                style: UgamText.bodyStrong.copyWith(color: c.accent),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _removeMember(String passengerId) =>
      _ctrl.setPassengerGroup(widget.tourId, passengerId, null);

  Future<void> _deleteGroup(String groupId) =>
      _ctrl.deleteGroup(widget.tourId, groupId);

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
                      'Tour not found.',
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
                    // ── Existing groups ──────────────────────────────────
                    if (groups.isNotEmpty) ...[
                      _SectionHeader(label: 'Groups', count: groups.length, c: c),
                      const SizedBox(height: UgamSpacing.sm),
                      for (final g in groups)
                        Padding(
                          padding: const EdgeInsets.only(bottom: UgamSpacing.md),
                          child: _GroupCard(
                            group: g,
                            members: tour.passengers
                                .where((p) => p.groupId == g.id)
                                .toList(),
                            onDelete: () => _deleteGroup(g.id),
                            onRemoveMember: _removeMember,
                            c: c,
                          ),
                        ),
                      const SizedBox(height: UgamSpacing.md),
                    ],

                    // ── Passenger roster ─────────────────────────────────
                    _SectionHeader(
                      label: 'Passengers',
                      count: tour.passengers.length,
                      c: c,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    if (tour.passengers.isEmpty)
                      _NoPassengers(c: c)
                    else
                      ...tour.passengers.map(
                        (p) => Padding(
                          padding:
                              const EdgeInsets.only(bottom: UgamSpacing.sm),
                          child: _PassengerRow(
                            passenger: p,
                            group:
                                p.groupId != null ? groupById[p.groupId] : null,
                            selecting: _selecting,
                            selected: _selected.contains(p.id),
                            onSelectToggle: () => _toggleSelected(p.id),
                            onPriorityToggle: () => _togglePriority(p),
                            c: c,
                          ),
                        ),
                      ),
                  ],
                );
              }),
            ),

            // Sticky CTA only while building a new group.
            if (_selecting)
              UgamStickyCTA(
                child: UgamCTA(
                  label: _selected.length < 2
                      ? 'Pick 2 or more'
                      : 'Create group (${_selected.length})',
                  leadingIcon: Icons.group_add_rounded,
                  loading: _creating,
                  onPressed: _selected.length >= 2 ? _createGroup : null,
                ),
              ),
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
              selecting ? 'Select passengers' : 'Groups & priority',
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
                    selecting
                        ? Icons.close_rounded
                        : Icons.group_add_rounded,
                    size: 16,
                    color: selecting ? c.ink2 : c.accent,
                  ),
                  const SizedBox(width: UgamSpacing.xs + 2),
                  Text(
                    selecting ? 'Cancel' : 'New group',
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
            style: UgamText.tabular(
              UgamText.micro.copyWith(color: c.ink2),
            ),
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
                  passenger.name.isEmpty ? 'Unnamed' : passenger.name,
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
        border: Border.all(
          color: checked ? c.accent : c.border,
          width: 1.6,
        ),
      ),
      alignment: Alignment.center,
      child: checked
          ? Icon(Icons.check_rounded, size: 15, color: c.onAccent)
          : null,
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
          _GroupDot(colorIndex: group.colorIndex, c: c),
          const SizedBox(width: UgamSpacing.xs + 2),
          Text(
            group.label.isEmpty ? 'Group' : group.label,
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

/// Deterministic palette dot for a group, indexed by [PassengerGroup.colorIndex].
/// These hues are decorative grouping cues (NOT status semantics), so they are
/// intentionally distinct from the warm/good/danger token roles.
class _GroupDot extends StatelessWidget {
  final int colorIndex;
  final UgamColorSet c;

  const _GroupDot({required this.colorIndex, required this.c});

  static const List<Color> _palette = [
    Color(0xFF6366F1), // indigo
    Color(0xFF14B8A6), // teal
    Color(0xFFEC4899), // pink
    Color(0xFF8B5CF6), // violet
    Color(0xFF0EA5E9), // sky
    Color(0xFF84CC16), // lime
  ];

  @override
  Widget build(BuildContext context) {
    final color = _palette[colorIndex.abs() % _palette.length];
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

// ─── Existing-group card ───────────────────────────────────────────────────

class _GroupCard extends StatelessWidget {
  final PassengerGroup group;
  final List<Passenger> members;
  final VoidCallback onDelete;
  final Future<void> Function(String passengerId) onRemoveMember;
  final UgamColorSet c;

  const _GroupCard({
    required this.group,
    required this.members,
    required this.onDelete,
    required this.onRemoveMember,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _GroupDot(colorIndex: group.colorIndex, c: c),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  group.label.isEmpty ? 'Group' : group.label,
                  style: UgamText.titleS.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
          const SizedBox(height: UgamSpacing.md),
          if (members.isEmpty)
            Text(
              'No members yet.',
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
                        m.name.isEmpty ? 'Unnamed' : m.name,
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
        ],
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
              'No passengers on this tour yet.',
              style: UgamText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
