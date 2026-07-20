import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/group_color.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/passenger_group.dart';
import '../models/tour.dart';
import '../routes/app_routes.dart';
import '../utils/app_snackbar.dart';

/// Small colour dot for a cross-booking group. Uses the app-wide golden-angle
/// [groupColor] so a group reads as the SAME hue here as on every seat chart.
class GroupDot extends StatelessWidget {
  final int colorIndex;
  final double size;
  const GroupDot({super.key, required this.colorIndex, this.size = 9});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: groupColor(colorIndex),
      shape: BoxShape.circle,
    ),
  );
}

/// Rounded-square numbered badge in the group's golden-angle colour. [number]
/// is the group's 1-based order on the tour (so the colour reads as "group #1"),
/// and the hue matches the SAME group on every seat chart. Used as the group
/// card's avatar and, shrunk down, inside [GroupTag].
class GroupNumberBadge extends StatelessWidget {
  final int number;
  final int colorIndex;
  final double size;
  final double radius;
  final double fontSize;

  const GroupNumberBadge({
    super.key,
    required this.number,
    required this.colorIndex,
    this.size = 28,
    this.radius = 9,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: groupColor(colorIndex),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        '$number',
        style: UgamText.bodyStrong.copyWith(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Compact group tag for a passenger row: a tiny numbered colour square + the
/// group label in one pill, meant to sit BESIDE the passenger's name. Reads the
/// same number + colour as the group's card, so the two never drift.
class GroupTag extends StatelessWidget {
  final int number;
  final int colorIndex;
  final String label;

  const GroupTag({
    super.key,
    required this.number,
    required this.colorIndex,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(3, 3, 8, 3),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          GroupNumberBadge(
            number: number,
            colorIndex: colorIndex,
            size: 16,
            radius: 5,
            fontSize: 9,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: UgamText.caption.copyWith(
                color: c.ink2,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Capacity facts for a cross-booking group measured against ONE bus. A group
/// must ride a single bus, so its berths are sized against the tour's largest
/// bus ([Tour.biggestBusSeats]). [capacity] is 0 when the tour has no buses,
/// in which case sizing can't be enforced ([hasBus] is false).
class GroupFit {
  final int used;
  final int capacity;
  const GroupFit(this.used, this.capacity);

  factory GroupFit.of(Tour tour, String groupId) =>
      GroupFit(tour.groupSeatBerths(groupId), tour.biggestBusSeats);

  bool get hasBus => capacity > 0;
  int get remaining => capacity - used;
  bool get isFull => hasBus && used >= capacity;
  bool get isOver => hasBus && used > capacity;

  /// Whether [extra] more berths still fit on one bus.
  bool fits(int extra) => !hasBus || used + extra <= capacity;
}

String _displayName(Passenger p) =>
    p.name.trim().isEmpty ? tr('tour_groups.unnamed') : p.name.trim();

// ───────────────────────────────────────────────────────────────────────────
// Sheet 2 — add an ungrouped passenger TO a group (from a group card).
// ───────────────────────────────────────────────────────────────────────────

/// Bottom sheet that adds ungrouped passengers into [groupId]. Carries a search
/// bar over the ungrouped roster; candidates that would push the group past one
/// bus are shown disabled. Stays open after each add so several can be added in
/// a row (the list refreshes reactively).
class AddMemberToGroupSheet extends StatefulWidget {
  final String tourId;
  final String groupId;

  const AddMemberToGroupSheet({
    super.key,
    required this.tourId,
    required this.groupId,
  });

  static Future<void> show(
    BuildContext context, {
    required Tour tour,
    required PassengerGroup group,
  }) {
    return UgamSheet.show<void>(
      context,
      title: tr('tour_groups.add_member_title',
          namedArgs: {'group': group.label}),
      builder: (_) =>
          AddMemberToGroupSheet(tourId: tour.id, groupId: group.id),
    );
  }

  @override
  State<AddMemberToGroupSheet> createState() => _AddMemberToGroupSheetState();
}

class _AddMemberToGroupSheetState extends State<AddMemberToGroupSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  TourController get _ctrl => Get.find<TourController>();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _add(Passenger p) async {
    await _ctrl.setPassengerGroup(widget.tourId, p.id, widget.groupId);
    AppSnackBar.success(
      tr('tour_groups.member_added', namedArgs: {'name': _displayName(p)}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Obx(() {
      final tour = _ctrl.getTour(widget.tourId);
      final group = tour?.groups.firstWhereOrNull((g) => g.id == widget.groupId);
      if (tour == null || group == null) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
          child: Text(
            tr('tour_groups.tour_not_found'),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
        );
      }

      final fit = GroupFit.of(tour, group.id);
      final q = _query.toLowerCase();
      final ungrouped = tour.passengers
          .where((p) => p.groupId == null)
          .where((p) =>
              q.isEmpty ||
              p.name.toLowerCase().contains(q) ||
              p.phone.toLowerCase().contains(q))
          .toList();

      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CapacityLine(fit: fit, c: c),
            const SizedBox(height: UgamSpacing.md),
            _SheetSearchField(
              controller: _searchCtrl,
              hint: tr('tour_groups.search_hint'),
              onChanged: (v) => setState(() => _query = v.trim()),
              c: c,
            ),
            const SizedBox(height: UgamSpacing.md),
            Flexible(
              child: ungrouped.isEmpty
                  ? Padding(
                      padding:
                          const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
                      child: Center(
                        child: Text(
                          _query.isEmpty
                              ? tr('tour_groups.add_member_empty')
                              : tr('tour_groups.no_search_results',
                                  namedArgs: {'q': _query}),
                          style: UgamText.body.copyWith(color: c.ink3),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      physics: const BouncingScrollPhysics(),
                      itemCount: ungrouped.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: UgamSpacing.sm),
                      itemBuilder: (_, i) {
                        final p = ungrouped[i];
                        final canAdd = fit.fits(p.seatBerths);
                        return _PassengerOptionRow(
                          passenger: p,
                          enabled: canAdd,
                          blockedReason:
                              canAdd ? null : tr('tour_groups.member_wont_fit'),
                          onTap: () => _add(p),
                          c: c,
                        );
                      },
                    ),
            ),
          ],
        ),
      );
    });
  }
}

// ─── Shared rows ───────────────────────────────────────────────────────────

class _PassengerOptionRow extends StatelessWidget {
  final Passenger passenger;
  final bool enabled;
  final String? blockedReason;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _PassengerOptionRow({
    required this.passenger,
    required this.enabled,
    required this.blockedReason,
    required this.onTap,
    required this.c,
  });

  String get _initial {
    final t = passenger.name.trim();
    return t.isEmpty ? '?' : t.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.row),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration:
                    BoxDecoration(color: c.card, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text(
                  _initial,
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
                      _displayName(passenger),
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
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              if (blockedReason != null)
                UgamReqChip(
                  label: blockedReason!.toUpperCase(),
                  variant: UgamChipVariant.warm,
                )
              else
                Icon(Icons.add_circle_outline_rounded,
                    size: 20, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapacityLine extends StatelessWidget {
  final GroupFit fit;
  final UgamColorSet c;
  const _CapacityLine({required this.fit, required this.c});

  @override
  Widget build(BuildContext context) {
    if (!fit.hasBus) {
      return _InfoNote(text: tr('requests.group.no_bus'), c: c);
    }
    final tone = fit.isOver
        ? c.danger
        : fit.isFull
            ? c.warm
            : c.good;
    return Row(
      children: [
        Icon(Icons.event_seat_outlined, size: 16, color: tone),
        const SizedBox(width: UgamSpacing.sm),
        Text(
          tr('tour_groups.seats_summary',
              namedArgs: {'used': '${fit.used}', 'cap': '${fit.capacity}'}),
          style: UgamText.bodyStrong.copyWith(color: tone, fontSize: 13),
        ),
        const SizedBox(width: UgamSpacing.sm),
        if (fit.remaining > 0)
          Text(
            tr('tour_groups.seats_left', namedArgs: {'n': '${fit.remaining}'}),
            style: UgamText.caption.copyWith(color: c.ink3),
          )
        else
          Text(
            tr('tour_groups.full_for_bus'),
            style: UgamText.caption.copyWith(color: c.warm),
          ),
      ],
    );
  }
}

class _InfoNote extends StatelessWidget {
  final String text;
  final UgamColorSet c;
  const _InfoNote({required this.text, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.warmFill,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: c.warm),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: UgamText.caption.copyWith(color: c.warm, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final UgamColorSet c;

  const _SheetSearchField({
    required this.controller,
    required this.hint,
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
                hintText: hint,
                hintStyle: UgamText.body.copyWith(color: c.ink3, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Sheet 3 — assign ONE passenger to an EXISTING group (from a request card).
//
// Group CREATION stays in the Groups & Priority manager (its single home);
// this sheet only ATTACHES an existing group to the passenger, or removes
// their current one. That keeps group-management logic in one place — no
// duplicated create flow on the requests screen.
// ───────────────────────────────────────────────────────────────────────────

class AssignGroupSheet extends StatelessWidget {
  final String tourId;
  final String passengerId;

  const AssignGroupSheet({
    super.key,
    required this.tourId,
    required this.passengerId,
  });

  static Future<void> show(
    BuildContext context, {
    required Tour tour,
    required Passenger passenger,
  }) {
    return UgamSheet.show<void>(
      context,
      title: tr('tour_groups.assign_title',
          namedArgs: {'name': _displayName(passenger)}),
      builder: (_) =>
          AssignGroupSheet(tourId: tour.id, passengerId: passenger.id),
    );
  }

  TourController get _ctrl => Get.find<TourController>();

  static String _label(PassengerGroup g) =>
      g.label.trim().isEmpty ? tr('tour_groups.group') : g.label.trim();

  Future<void> _assign(
      BuildContext context, PassengerGroup g, Passenger p) async {
    await _ctrl.setPassengerGroup(tourId, passengerId, g.id);
    if (context.mounted) Navigator.of(context).pop();
    AppSnackBar.success(tr('tour_groups.assigned',
        namedArgs: {'name': _displayName(p), 'group': _label(g)}));
  }

  Future<void> _remove(BuildContext context, Passenger p) async {
    await _ctrl.setPassengerGroup(tourId, passengerId, null);
    if (context.mounted) Navigator.of(context).pop();
    AppSnackBar.success(
        tr('tour_groups.removed', namedArgs: {'name': _displayName(p)}));
  }

  void _openManager(BuildContext context) {
    Navigator.of(context).pop();
    Get.toNamed(AppRoutes.tourGroups, arguments: {'tourId': tourId});
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Obx(() {
      final tour = _ctrl.getTour(tourId);
      final p = tour?.passengers.firstWhereOrNull((x) => x.id == passengerId);
      if (tour == null || p == null) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
          child: Text(tr('tour_groups.tour_not_found'),
              style: UgamText.body.copyWith(color: c.ink2)),
        );
      }

      final groups = tour.groups;
      final currentId = p.groupId;
      final current = groups.firstWhereOrNull((g) => g.id == currentId);
      final others = groups.where((g) => g.id != currentId).toList();

      final children = <Widget>[];

      // Current group (if any), with a remove affordance.
      if (current != null) {
        children.add(_CurrentGroupRow(
          label: _label(current),
          colorIndex: current.colorIndex,
          onRemove: () => _remove(context, p),
          c: c,
        ));
        children.add(const SizedBox(height: UgamSpacing.md));
      }

      if (groups.isEmpty) {
        // No groups exist yet — point to the single manager to create one.
        children.add(_ManagerLink(
          text: tr('tour_groups.no_groups_note'),
          c: c,
          onTap: () => _openManager(context),
        ));
      } else if (others.isEmpty) {
        // Already in the only group there is.
        children.add(_ManagerLink(
          text: tr('tour_groups.only_group'),
          c: c,
          onTap: () => _openManager(context),
        ));
      } else {
        children.add(Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            physics: const BouncingScrollPhysics(),
            itemCount: others.length,
            separatorBuilder: (_, _) => const SizedBox(height: UgamSpacing.sm),
            itemBuilder: (_, i) {
              final g = others[i];
              final fit = GroupFit.of(tour, g.id);
              final canAdd = fit.fits(p.seatBerths);
              return _GroupOptionRow(
                label: _label(g),
                colorIndex: g.colorIndex,
                fit: fit,
                enabled: canAdd,
                blockedReason:
                    canAdd ? null : tr('tour_groups.member_wont_fit'),
                onTap: () => _assign(context, g, p),
                c: c,
              );
            },
          ),
        ));
        children.add(const SizedBox(height: UgamSpacing.md));
        children.add(_ManagerLink(
          text: tr('tour_groups.open_manager'),
          c: c,
          onTap: () => _openManager(context),
          leading: Icons.open_in_new_rounded,
        ));
      }

      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    });
  }
}

/// A selectable existing-group row in [AssignGroupSheet]: colour dot + label +
/// one-bus capacity line. Disabled (with a "won't fit" chip) when adding this
/// passenger would push the group past its largest bus.
class _GroupOptionRow extends StatelessWidget {
  final String label;
  final int colorIndex;
  final GroupFit fit;
  final bool enabled;
  final String? blockedReason;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _GroupOptionRow({
    required this.label,
    required this.colorIndex,
    required this.fit,
    required this.enabled,
    required this.blockedReason,
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
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.row),
          ),
          child: Row(
            children: [
              GroupDot(colorIndex: colorIndex, size: 12),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        style: UgamText.titleS.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      fit.hasBus
                          ? tr('tour_groups.seats_summary', namedArgs: {
                              'used': '${fit.used}',
                              'cap': '${fit.capacity}',
                            })
                          : tr('tour_groups.seats_plain',
                              namedArgs: {'n': '${fit.used}'}),
                      style: UgamText.caption.copyWith(color: c.ink3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              if (blockedReason != null)
                UgamReqChip(
                  label: blockedReason!.toUpperCase(),
                  variant: UgamChipVariant.warm,
                )
              else
                Icon(Icons.add_circle_outline_rounded,
                    size: 20, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }
}

/// The passenger's current group, shown at the top of [AssignGroupSheet] with a
/// "Remove from group" action (ungroups via `setPassengerGroup(.., null)`).
class _CurrentGroupRow extends StatelessWidget {
  final String label;
  final int colorIndex;
  final VoidCallback onRemove;
  final UgamColorSet c;

  const _CurrentGroupRow({
    required this.label,
    required this.colorIndex,
    required this.onRemove,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
          UgamSpacing.lg, UgamSpacing.md, UgamSpacing.sm, UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(color: c.accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          GroupDot(colorIndex: colorIndex, size: 12),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr('tour_groups.current_group'),
                    style: UgamText.micro.copyWith(color: c.ink3)),
                const SizedBox(height: 2),
                Text(label,
                    style: UgamText.titleS.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          UgamButton(
            label: tr('tour_groups.remove_from_group'),
            icon: Icons.close_rounded,
            kind: UgamButtonKind.dangerTonal,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// A tappable link to the single Groups & Priority manager — used for the
/// empty/only-group states and as a "create more / open manager" footer so the
/// sheet never dead-ends.
class _ManagerLink extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  final UgamColorSet c;
  final IconData leading;

  const _ManagerLink({
    required this.text,
    required this.onTap,
    required this.c,
    this.leading = Icons.groups_rounded,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md, vertical: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          children: [
            Icon(leading, size: 16, color: c.accent),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(text,
                  style:
                      UgamText.caption.copyWith(color: c.ink2, fontSize: 12)),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
