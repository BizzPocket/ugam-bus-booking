part of '../group_picker.dart';

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
