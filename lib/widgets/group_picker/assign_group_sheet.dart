part of '../group_picker.dart';

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
    try {
      await _ctrl.setPassengerGroup(tourId, passengerId, g.id);
    } catch (_) {
      // The controller's _write already rolled back and showed the error
      // toast; swallow the rethrow so it is not an unhandled async error, and
      // keep the sheet open so the agent can retry.
      return;
    }
    if (context.mounted) Navigator.of(context).pop();
    AppSnackBar.success(tr('tour_groups.assigned',
        namedArgs: {'name': _displayName(p), 'group': _label(g)}));
  }

  Future<void> _remove(BuildContext context, Passenger p) async {
    try {
      await _ctrl.setPassengerGroup(tourId, passengerId, null);
    } catch (_) {
      return; // Error already surfaced by the controller (see _assign).
    }
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

      final children = <Widget>[
        // Current group (if any), with a remove affordance.
        if (current != null) ...[
          _CurrentGroupRow(
            label: _label(current),
            colorIndex: current.colorIndex,
            onRemove: () => _remove(context, p),
            c: c,
          ),
          const SizedBox(height: UgamSpacing.md),
        ],
        if (groups.isEmpty)
          // No groups exist yet — point to the single manager to create one.
          _ManagerLink(
            text: tr('tour_groups.no_groups_note'),
            c: c,
            onTap: () => _openManager(context),
          )
        else if (others.isEmpty)
          // Already in the only group there is.
          _ManagerLink(
            text: tr('tour_groups.only_group'),
            c: c,
            onTap: () => _openManager(context),
          )
        else ...[
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              physics: const BouncingScrollPhysics(),
              itemCount: others.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: UgamSpacing.sm),
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
          ),
          const SizedBox(height: UgamSpacing.md),
          _ManagerLink(
            text: tr('tour_groups.open_manager'),
            c: c,
            onTap: () => _openManager(context),
            leading: Icons.open_in_new_rounded,
          ),
        ],
      ];

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
    return _OptionRowFrame(
      leading: GroupDot(colorIndex: colorIndex, size: 12),
      title: label,
      subtitle: fit.hasBus
          ? tr('tour_groups.seats_summary', namedArgs: {
              'used': '${fit.used}',
              'cap': '${fit.capacity}',
            })
          : tr('tour_groups.seats_plain', namedArgs: {'n': '${fit.used}'}),
      enabled: enabled,
      blockedReason: blockedReason,
      onTap: onTap,
      c: c,
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
