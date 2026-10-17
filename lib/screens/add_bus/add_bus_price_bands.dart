part of '../add_bus_screen.dart';

/// Step 3's "Price bands" body and its add/edit sheet, split out of
/// [_Step3PriceState]. Behaviour is unchanged.
extension _PriceBandsEditor on _Step3PriceState {
  /// Price-bands body: the editable list of named row-range bands.
  Widget _buildBandsBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          tr('add_bus.price_mode.bands_body'),
          style: UgamText.caption.copyWith(color: c.ink3, height: 1.4),
        ),
        const SizedBox(height: UgamSpacing.lg),
        for (var i = 0; i < _bands.length; i++) ...[
          _BandRow(
            c: c,
            band: _bands[i],
            onEdit: () => _openBandSheet(index: i),
            onRemove: () => _removeBand(i),
          ),
          const SizedBox(height: UgamSpacing.sm),
        ],
        const SizedBox(height: UgamSpacing.xs),
        UgamButton(
          label: tr('add_bus.bands.add'),
          kind: UgamButtonKind.tonal,
          icon: Icons.add_rounded,
          expand: true,
          onPressed: () => _openBandSheet(),
        ),
        if (_uncoveredRowsLabel() case final gaps?) ...[
          const SizedBox(height: UgamSpacing.md),
          UgamCaveat(
            tone: UgamCaveatTone.warm,
            message: tr('add_bus.bands.uncovered', namedArgs: {'rows': gaps}),
          ),
        ],
        if (_rowCount == null) ...[
          const SizedBox(height: UgamSpacing.sm),
          Text(
            tr('add_bus.bands.rows_clamped_note'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
        ],
      ],
    );
  }

  /// 1-based "3, 7–9" list of rows NO band covers, or null when every row is
  /// banded (or the bus has no layout yet / no bands at all). Those rows fall
  /// back to the uniform per-seat price, which bands mode no longer shows.
  String? _uncoveredRowsLabel() {
    final rows = _rowCount;
    if (rows == null || rows <= 0 || _bands.isEmpty) return null;
    final covered = List<bool>.filled(rows, false);
    for (final b in _bands) {
      for (var r = b.fromRow; r <= b.toRow; r++) {
        if (r >= 0 && r < rows) covered[r] = true;
      }
    }
    final parts = <String>[];
    var r = 0;
    while (r < rows) {
      if (covered[r]) {
        r++;
        continue;
      }
      final start = r;
      while (r < rows && !covered[r]) {
        r++;
      }
      final end = r - 1;
      parts.add(start == end ? '${start + 1}' : '${start + 1}–${end + 1}');
    }
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// Open the add/edit sheet for a band. [index] null = adding a new band.
  void _openBandSheet({int? index}) {
    final existing = index != null ? _bands[index] : null;
    final rowCount = _rowCount;
    final maxRow = rowCount == null ? null : rowCount - 1;

    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    // Display rows 1-based to the agent; store 0-based.
    final fromCtrl = TextEditingController(
      text: existing != null ? '${existing.fromRow + 1}' : '',
    );
    final toCtrl = TextEditingController(
      text: existing != null ? '${existing.toRow + 1}' : '',
    );
    final priceCtrl = TextEditingController(
      text: existing != null && existing.price > 0
          ? existing.price.toStringAsFixed(0)
          : '',
    );

    // Four controllers per open, and the sheet can be opened once per band per
    // visit — none of them were ever disposed, so every trip through the band
    // editor leaked a TextEditingController (and its listeners) for the life of
    // the screen. Tear them down when the sheet route is gone.
    UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('add_bus.band_sheet.title_add')
          : tr('add_bus.band_sheet.title_edit'),
      builder: (sheetCtx) {
        final sc = UgamColors.of(sheetCtx);
        return SingleChildScrollView(
          child: StatefulBuilder(
            builder: (innerCtx, setSheetState) {
              int? parseRow(TextEditingController ctl) {
                final raw = int.tryParse(ctl.text.trim());
                if (raw == null) return null;
                return raw - 1; // back to 0-based
              }

              final from = parseRow(fromCtrl);
              // Blank "To row" → a single-row band (just the From row), so
              // pricing one seat/row (e.g. row 5) is "From 5", To left empty.
              final to = toCtrl.text.trim().isEmpty ? from : parseRow(toCtrl);
              final price = double.tryParse(priceCtrl.text.trim()) ?? 0;

              // Out-of-range rows used to sail through: the CTA stayed live and
              // the commit below silently clamped "rows 12–20" to the bus's real
              // last row, so the range the agent typed changed by itself the
              // moment the sheet closed. Say it in the field instead — cause
              // ("this bus has 7 rows") and fix ("use 1 to 7") in one line — and
              // hold the CTA until it is true.
              String? rowError(int? v, String raw) {
                if (raw.trim().isEmpty || v == null) return null;
                if (v < 0) return tr('add_bus.band_sheet.err_row_min');
                if (maxRow != null && v > maxRow) {
                  return tr(
                    'add_bus.band_sheet.err_row_range',
                    namedArgs: {'max': '${maxRow + 1}'},
                  );
                }
                return null;
              }

              final fromError = rowError(from, fromCtrl.text);
              final toError = rowError(
                toCtrl.text.trim().isEmpty ? null : to,
                toCtrl.text,
              );
              final priceError = priceCtrl.text.trim().isEmpty || price > 0
                  ? null
                  : tr('add_bus.band_sheet.err_price');

              final valid =
                  from != null &&
                  to != null &&
                  from >= 0 &&
                  to >= 0 &&
                  price > 0 &&
                  fromError == null &&
                  toError == null &&
                  priceError == null;

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UgamInput(
                    label: tr('add_bus.band_sheet.label'),
                    controller: labelCtrl,
                    hint: tr('add_bus.band_sheet.label_hint'),
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: UgamInput(
                          label: tr('add_bus.band_sheet.from_row'),
                          controller: fromCtrl,
                          hint: '1',
                          errorText: fromError,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: false,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                          ],
                          onChanged: (_) => setSheetState(() {}),
                        ),
                      ),
                      const SizedBox(width: UgamSpacing.md),
                      Expanded(
                        child: UgamInput(
                          label: tr('add_bus.band_sheet.to_row'),
                          controller: toCtrl,
                          hint: tr('add_bus.band_sheet.to_row_hint'),
                          errorText: toError,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: false,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                          ],
                          onChanged: (_) => setSheetState(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  Text(
                    maxRow == null
                        ? tr('add_bus.band_sheet.rows_help')
                        : tr(
                            'add_bus.band_sheet.rows_help_max',
                            namedArgs: {'max': '${maxRow + 1}'},
                          ),
                    style: UgamText.micro.copyWith(color: sc.ink3),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  _moneyInput(
                    sc,
                    label: tr('add_bus.band_sheet.price_per_person'),
                    controller: priceCtrl,
                    hint: tr('add_bus.band_sheet.price_hint'),
                    errorText: priceError,
                    onChanged: (_) => setSheetState(() {}),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  UgamCTA(
                    label: existing == null
                        ? tr('add_bus.band_sheet.cta_add')
                        : tr('add_bus.band_sheet.cta_save'),
                    onPressed: valid
                        ? () {
                            // `valid` promotes both from/to to non-null here.
                            final f = from;
                            final t = to;
                            var lo = f <= t ? f : t;
                            var hi = f <= t ? t : f;
                            if (maxRow != null) {
                              lo = lo.clamp(0, maxRow);
                              hi = hi.clamp(0, maxRow);
                            }
                            final label = labelCtrl.text.trim().isEmpty
                                ? tr('add_bus.band_sheet.default_label')
                                : labelCtrl.text.trim();
                            final band = PriceBand(
                              label: label,
                              fromRow: lo,
                              toRow: hi,
                              price: price,
                            );
                            if (index == null) {
                              _addBand(band);
                            } else {
                              _updateBand(index, band);
                            }
                            Navigator.of(sheetCtx).pop();
                          }
                        : null,
                  ),
                ],
              );
            },
          ),
        );
      },
    ).whenComplete(() {
      labelCtrl.dispose();
      fromCtrl.dispose();
      toCtrl.dispose();
      priceCtrl.dispose();
    });
  }
}

/// One row in the "Price bands" list: the band's label, its 1-based row range,
/// and its per-person price, with edit + remove affordances. Tapping the row
/// opens the edit sheet; the trash icon removes it.
class _BandRow extends StatelessWidget {
  final UgamColorSet c;
  final PriceBand band;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const _BandRow({
    required this.c,
    required this.band,
    required this.onEdit,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final rangeLabel = band.fromRow == band.toRow
        ? tr(
            'add_bus.band_row.single',
            namedArgs: {'row': '${band.fromRow + 1}'},
          )
        : tr(
            'add_bus.band_row.range',
            namedArgs: {
              'from': '${band.fromRow + 1}',
              'to': '${band.toRow + 1}',
            },
          );
    final name = band.label.trim();
    final untitled =
        name.isEmpty || name == tr('add_bus.band_sheet.default_label');
    return UgamTappable(
      onTap: onEdit,
      semanticLabel: tr('add_bus.band_sheet.title_edit'),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // An unnamed band (blank, or the generic "Band" the sheet
                  // stores for blank) is titled by its rows — "Rows 1–6" —
                  // so a list of them is not three identical "Band" rows.
                  Text(
                    untitled ? rangeLabel : band.label,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  if (!untitled) ...[
                    const SizedBox(height: 2),
                    Text(
                      rangeLabel,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              // Grouped like every other money figure in the app (₹12,500),
              // and inked `ink` not `accent`: one copper number per band row
              // turned the band list into a column of coppers competing with
              // the Save CTA. The label/range in ink2 carry the hierarchy.
              Formatters.formatMoneyInr(band.price),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            // Was a 26pt hit box nested inside the row's own edit tap, so a
            // near-miss on "remove band" opened the edit sheet instead.
            UgamIconButton(
              icon: Icons.close_rounded,
              onTap: onRemove,
              semanticLabel: tr('add_bus.bands.remove_semantic'),
            ),
          ],
        ),
      ),
    );
  }
}
