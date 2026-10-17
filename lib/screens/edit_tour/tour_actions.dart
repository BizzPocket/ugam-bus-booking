part of '../edit_tour_screen.dart';

// Tour-level actions launched from the edit form: copy one bus's price sheet
// onto the rest, and delete the tour.
extension _EditTourActions on _EditTourScreenState {
  /// One-tap "apply this price sheet to all buses". Lets the agent pick a
  /// source bus, then copies its pricing — base price, the three per-type
  /// overrides, the rear zone, and the flexible price bands — onto every OTHER
  /// bus on this tour. Per-bus edits stay possible afterwards; this is just a
  /// fast way to make one bus the template for the rest.
  Future<void> _applyPriceSheet() async {
    final ctrl = Get.find<TourController>();
    final tour = ctrl.getTour(widget.tourId);
    if (tour == null) return;
    final buses = tour.buses;
    if (buses.length < 2) {
      AppSnackBar.warning(tr('edit_tour.price_sheet.need_two_buses'));
      return;
    }

    final source = await UgamSheet.show<Bus>(
      context,
      title: tr('edit_tour.price_sheet.sheet_title'),
      builder: (sheetCtx) {
        final sc = UgamColors.of(sheetCtx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              // Was `body` pulled down to 13 — a size that exists nowhere on
              // the ladder. `caption` (12) is the step below body and is what
              // the rest of the app uses for sheet explainers.
              tr('edit_tour.price_sheet.sheet_body'),
              style: UgamText.caption.copyWith(color: sc.ink2, height: 1.5),
            ),
            const SizedBox(height: UgamSpacing.lg),
            for (final b in buses) ...[
              UgamCard.plain(
                onTap: () => Navigator.of(sheetCtx).pop(b),
                elev: true,
                padding: const EdgeInsets.all(UgamSpacing.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            b.name,
                            // `bodyStrong` is already 14; the override was a
                            // no-op reading as an intentional off-ladder size.
                            style: UgamText.bodyStrong.copyWith(color: sc.ink),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _priceSummary(b),
                            style: UgamText.caption.copyWith(color: sc.ink2),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Icon(Icons.chevron_right_rounded, color: sc.ink3),
                  ],
                ),
              ),
              const SizedBox(height: UgamSpacing.sm),
            ],
          ],
        );
      },
    );

    if (source == null || !mounted) return;

    final targets = buses.where((b) => b.id != source.id).toList();
    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('edit_tour.price_sheet.confirm_title'),
      message: tr(
        targets.length == 1
            ? 'edit_tour.price_sheet.confirm_body_one'
            : 'edit_tour.price_sheet.confirm_body_other',
        namedArgs: {'name': source.name, 'count': '${targets.length}'},
      ),
      confirmLabel: tr('edit_tour.price_sheet.confirm_copy'),
    );
    if (!confirmed || !mounted) return;

    _update(() => _saving = true);
    try {
      for (final t in targets) {
        final updated = t.copyWith(
          pricePerSeat: source.pricePerSeat,
          singleSofaPrice: source.singleSofaPrice,
          doubleSofaPrice: source.doubleSofaPrice,
          seaterPrice: source.seaterPrice,
          rearRows: source.rearRows,
          rearPrice: source.rearPrice,
          priceBands: List<PriceBand>.from(source.priceBands),
        );
        // Pricing-only copy — the seat grid is not part of this edit.
        await ctrl.updateBus(widget.tourId, updated, layoutChanged: false);
      }
      if (!mounted) return;
      AppSnackBar.success(
        tr(
          targets.length == 1
              ? 'edit_tour.price_sheet.copied_one'
              : 'edit_tour.price_sheet.copied_other',
          namedArgs: {'name': source.name, 'count': '${targets.length}'},
        ),
      );
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('edit_tour.price_sheet.copy_failed'));
    } finally {
      if (mounted) _update(() => _saving = false);
    }
  }

  /// Short price summary for a bus row in the source picker.
  String _priceSummary(Bus b) {
    final parts = <String>[
      tr(
        'edit_tour.price_sheet.per_seat',
        namedArgs: {'price': b.pricePerSeat.toStringAsFixed(0)},
      ),
    ];
    final bands = b.priceBands.length + (b.rearRows > 0 ? 1 : 0);
    if (bands > 0) {
      parts.add(
        tr(
          bands == 1
              ? 'edit_tour.price_sheet.band_count_one'
              : 'edit_tour.price_sheet.band_count_other',
          namedArgs: {'count': '$bands'},
        ),
      );
    }
    return parts.join(' · ');
  }

  Future<void> _confirmAndDelete() async {
    final tour = Get.find<TourController>().getTour(widget.tourId);
    if (tour == null) return;

    final pCount = tour.passengers.length;
    final bCount = tour.buses.length;
    final detailParts = <String>[
      '"${tour.title}"',
      if (pCount > 0)
        tr(
          pCount == 1
              ? 'edit_tour.delete.passengers_one'
              : 'edit_tour.delete.passengers_other',
          namedArgs: {'count': '$pCount'},
        ),
      if (bCount > 0)
        tr(
          bCount == 1
              ? 'edit_tour.delete.buses_unlinked_one'
              : 'edit_tour.delete.buses_unlinked_other',
          namedArgs: {'count': '$bCount'},
        ),
    ];
    final detail = detailParts.join(' · ');

    final confirmed = await UgamDialog.confirm(
      context,
      title: tr('edit_tour.delete.title'),
      message: tr('edit_tour.delete.message', namedArgs: {'detail': detail}),
      confirmLabel: tr('app.action.delete'),
      destructive: true,
      confirmIcon: Icons.delete_outline_rounded,
    );
    if (!confirmed || !mounted) return;

    _update(() => _saving = true);
    try {
      await Get.find<TourController>().deleteTour(widget.tourId);
      if (!mounted) return;
      AppSnackBar.success(
        tr('edit_tour.delete.deleted', namedArgs: {'title': tour.title}),
      );
      // Pop the NESTED tab stack back to the tab root (tour list). The just-
      // deleted tour's Edit + Detail screens both drop away. A root-level
      // Get.until ran on the root navigator (already at its first route) → a
      // no-op that left the deleted tour's screens stranded on screen.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (_) {
      if (mounted) _update(() => _saving = false);
    }
  }
}
