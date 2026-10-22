import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/passenger_group.dart';
import '../utils/app_snackbar.dart';
import '../widgets/group_picker.dart';

part 'tour_groups/passenger_row.dart';
part 'tour_groups/group_cards.dart';

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

  /// The group-name dialog's field. Owned here, not per-dialog: the dialog
  /// stays mounted through its exit transition after its future completes,
  /// so a per-dialog controller could only leak or be disposed while in use.
  final _labelCtrl = TextEditingController();

  /// Whether the search pill is revealed under the app bar. Search lives in
  /// the app-bar chrome (a toggle action) — same pattern as the Requests
  /// screen — instead of floating in the middle of the scroll list.
  bool _searchVisible = false;

  TourController get _ctrl => Get.find<TourController>();

  @override
  void dispose() {
    _searchCtrl.dispose();
    _labelCtrl.dispose();
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
    final textCtrl = _labelCtrl
      ..text = tr('tour_groups.default_group_name', namedArgs: {'n': '$next'});
    return UgamDialog.show<String>(
      context,
      title: tr('tour_groups.name_this_group'),
      // Builder: pop with a context INSIDE the dialog route — the screen's
      // context resolves the screen's navigator, not the dialog's.
      content: Builder(
        builder: (fieldCtx) => UgamInput(
          controller: textCtrl,
          hint: tr('tour_groups.name_hint'),
          autofocus: true,
          onSubmitted: (v) => Navigator.of(fieldCtx).pop(v),
        ),
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
