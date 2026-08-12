import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/tour.dart';
import '../utils/app_nav.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../utils/time_format.dart';
import '../widgets/booking_settings_sheet.dart';

class EditTourScreen extends StatefulWidget {
  final String tourId;
  const EditTourScreen({super.key, required this.tourId});

  @override
  State<EditTourScreen> createState() => _EditTourScreenState();
}

class _EditTourScreenState extends State<EditTourScreen> {
  /// Hard cap on the description, mirrored by the visible counter below the
  /// field. Named so the cap and the counter can never drift apart.
  static const int _descMaxLength = 300;

  late final TextEditingController _titleCtrl;
  late final TextEditingController _fromCtrl;
  late final TextEditingController _toCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _descCtrl;
  DateTime? _departureDate;
  TimeOfDay? _departureTime;
  DateTime? _returnDate;
  TimeOfDay? _returnTime;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  Timer? _fieldDebounce;
  String? _dateError;
  String? _titleError;
  String? _fromError;
  String? _toError;

  // Originals captured at initState — used to detect dirty state and
  // to power the "Cancel changes" action.
  late final String _origTitle;
  late final String _origFrom;
  late final String _origTo;
  late final String _origPrice;
  late final String _origDesc;
  DateTime? _origDeparture;
  TimeOfDay? _origDepartureTime;
  DateTime? _origReturn;
  TimeOfDay? _origReturnTime;

  @override
  void initState() {
    super.initState();
    final tour = Get.find<TourController>().getTour(widget.tourId);
    _origTitle = tour?.title ?? '';
    _origFrom = tour?.fromCity ?? '';
    _origTo = tour?.toCity ?? '';
    _origPrice = tour != null ? tour.pricePerSeat.toStringAsFixed(0) : '';
    _origDesc = tour?.description ?? '';
    _origDeparture = tour?.departureDate;
    _origDepartureTime = timeOfDayFromHhmm(tour?.departureTime);
    _origReturn = tour?.returnDate;
    _origReturnTime = timeOfDayFromHhmm(tour?.returnTime);

    _titleCtrl = TextEditingController(text: _origTitle);
    _fromCtrl = TextEditingController(text: _origFrom);
    _toCtrl = TextEditingController(text: _origTo);
    _priceCtrl = TextEditingController(text: _origPrice);
    _descCtrl = TextEditingController(text: _origDesc);
    _departureDate = _origDeparture;
    _departureTime = _origDepartureTime;
    _returnDate = _origReturn;
    _returnTime = _origReturnTime;

    _titleCtrl.addListener(_onFieldChanged);
    _fromCtrl.addListener(_onFieldChanged);
    _toCtrl.addListener(_onFieldChanged);
    _priceCtrl.addListener(_onFieldChanged);
    _descCtrl.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    _fieldDebounce?.cancel();
    _fieldDebounce = Timer(const Duration(milliseconds: 90), () {
      if (mounted) {
        setState(() {
          // Clear a field's validation error once it has content again.
          if (_titleError != null && _titleCtrl.text.trim().isNotEmpty) {
            _titleError = null;
          }
          if (_fromError != null && _fromCtrl.text.trim().isNotEmpty) {
            _fromError = null;
          }
          if (_toError != null && _toCtrl.text.trim().isNotEmpty) {
            _toError = null;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _titleCtrl.removeListener(_onFieldChanged);
    _fromCtrl.removeListener(_onFieldChanged);
    _toCtrl.removeListener(_onFieldChanged);
    _priceCtrl.removeListener(_onFieldChanged);
    _descCtrl.removeListener(_onFieldChanged);
    _fieldDebounce?.cancel();
    _titleCtrl.dispose();
    _fromCtrl.dispose();
    _toCtrl.dispose();
    _priceCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  bool get _isDirty {
    if (_titleCtrl.text != _origTitle) return true;
    if (_fromCtrl.text != _origFrom) return true;
    if (_toCtrl.text != _origTo) return true;
    if (_priceCtrl.text != _origPrice) return true;
    if (_descCtrl.text != _origDesc) return true;
    if (_departureDate != _origDeparture) return true;
    if (_departureTime != _origDepartureTime) return true;
    if (_returnDate != _origReturn) return true;
    if (_returnTime != _origReturnTime) return true;
    return false;
  }

  /// Leave the screen, asking first when there is unsaved work.
  ///
  /// Wired to BOTH the app-bar chevron and [PopScope], because the two used to
  /// disagree: the screen computed [_isDirty] only to decide whether to SHOW a
  /// "Cancel changes" button, while the chevron and the Android back gesture
  /// both threw a fully edited tour away without a word.
  Future<void> _confirmExit() async {
    if (_isDirty) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('edit_tour.exit_confirm_title'),
        message: tr('edit_tour.exit_confirm_msg'),
        confirmLabel: tr('edit_tour.exit_confirm_cta'),
        destructive: true,
      );
      if (!ok) return;
    }
    if (!mounted) return;
    AppNav.pop(context);
  }

  /// Revert every field to the values captured in [initState].
  ///
  /// Confirmed first: this is a one-tap wipe of everything typed since the
  /// screen opened, sitting immediately beside Save, with no undo behind it.
  Future<void> _confirmCancelChanges() async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('edit_tour.cancel_confirm_title'),
      message: tr('edit_tour.cancel_confirm_msg'),
      confirmLabel: tr('edit_tour.cancel_confirm_cta'),
      destructive: true,
    );
    if (!ok || !mounted) return;
    _cancelChanges();
  }

  void _cancelChanges() {
    setState(() {
      _titleError = null;
      _fromError = null;
      _toError = null;
      _dateError = null;
      _titleCtrl.text = _origTitle;
      _fromCtrl.text = _origFrom;
      _toCtrl.text = _origTo;
      _priceCtrl.text = _origPrice;
      _descCtrl.text = _origDesc;
      _departureDate = _origDeparture;
      _departureTime = _origDepartureTime;
      _returnDate = _origReturn;
      _returnTime = _origReturnTime;
    });
  }

  Future<void> _pickDate(bool isReturn) async {
    final initial = isReturn
        ? (_returnDate ?? _departureDate ?? DateTime.now())
        : (_departureDate ?? DateTime.now());
    final first = isReturn
        ? (_departureDate ?? DateTime.now().subtract(const Duration(days: 365)))
        : DateTime.now().subtract(const Duration(days: 365));

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (picked != null) {
      setState(() {
        if (isReturn) {
          _returnDate = picked;
        } else {
          _departureDate = picked;
          _dateError = null;
          if (_returnDate != null && _returnDate!.isBefore(picked)) {
            _returnDate = null;
            _returnTime = null;
          }
        }
      });
    }
  }

  Future<void> _pickTime(bool isReturn) async {
    final current = isReturn ? _returnTime : _departureTime;
    final picked = await showTimePicker(
      context: context,
      initialTime: current ?? const TimeOfDay(hour: 9, minute: 0),
    );
    if (picked != null) {
      setState(() {
        if (isReturn) {
          _returnTime = picked;
        } else {
          _departureTime = picked;
        }
      });
    }
  }

  Future<void> _save() async {
    // UgamInput is a bare TextField with no validator, so the form's own
    // validate() is a no-op. Enforce the required fields here on the trimmed
    // values and surface per-field errors via each input's errorText slot.
    final title = _titleCtrl.text.trim();
    final fromCity = _fromCtrl.text.trim();
    final toCity = _toCtrl.text.trim();
    setState(() {
      _titleError =
          title.isEmpty ? tr('edit_tour.error_name_required') : null;
      _fromError =
          fromCity.isEmpty ? tr('edit_tour.error_from_required') : null;
      _toError = toCity.isEmpty ? tr('edit_tour.error_to_required') : null;
    });
    if (title.isEmpty || fromCity.isEmpty || toCity.isEmpty) return;
    if (_departureDate == null) {
      setState(() => _dateError = tr('edit_tour.error_select_start_date'));
      return;
    }

    setState(() => _saving = true);
    try {
      await Get.find<TourController>().editTour(
        tourId: widget.tourId,
        title: title,
        fromCity: fromCity,
        toCity: toCity,
        departureDate: _departureDate!,
        departureTime: _departureTime != null
            ? hhmmFromTimeOfDay(_departureTime!)
            : null,
        returnDate: _returnDate,
        returnTime: (_returnDate != null && _returnTime != null)
            ? hhmmFromTimeOfDay(_returnTime!)
            : null,
        pricePerSeat: double.tryParse(_priceCtrl.text) ?? 0,
        description: _descCtrl.text.trim().isEmpty
            ? null
            : _descCtrl.text.trim(),
      );
      if (!mounted) return;
      AppSnackBar.success(tr('edit_tour.snack_updated'));
      AppNav.pop(context);
    } catch (_) {
      AppSnackBar.error(tr('edit_tour.snack_save_failed'));
      // Guarded: the await above can outlive the screen, and an unguarded
      // setState on a disposed State throws instead of surfacing the failure.
      if (mounted) setState(() => _saving = false);
    }
  }

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

    setState(() => _saving = true);
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
      if (mounted) setState(() => _saving = false);
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

    setState(() => _saving = true);
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
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // One lookup for the whole build. It used to be re-run twice inline, once
    // to gate the price-sheet card and once inside a Builder, which made the
    // same read look like three different sources of truth.
    final tour = Get.find<TourController>().getTour(widget.tourId);
    if (tour == null) return _missingTour(c);
    final dirty = _isDirty;

    return PopScope(
      // Android back / iOS edge-swipe are the same intent as the chevron, and
      // they bypassed the (previously non-existent) guard entirely.
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: _form(c, tour, dirty),
    );
  }

  Widget _form(UgamColorSet c, Tour tour, bool dirty) {
    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(
              title: tr('edit_tour.title'),
              onBack: _confirmExit,
              actions: [
                // Revert-all. Only exists while there is something to revert,
                // and always asks first — it is a one-tap wipe of everything
                // typed since the screen opened.
                if (dirty)
                  UgamAppBarAction(
                    icon: Icons.undo_rounded,
                    tooltip: tr('edit_tour.cancel_changes'),
                    onTap: _saving ? () {} : _confirmCancelChanges,
                  ),
                UgamAppBarAction(
                  icon: Icons.delete_outline_rounded,
                  // Inert during a save, and now LOOKS inert: it kept full
                  // danger-red and full press feedback while wired to a no-op,
                  // so a mid-save tap read as "delete didn't work".
                  tint: _saving ? c.ink3 : c.danger,
                  tooltip: tr('app.action.delete'),
                  onTap: _saving ? () {} : _confirmAndDelete,
                ),
              ],
            ),
            Expanded(
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.sm,
                    UgamSpacing.gutter,
                    UgamSpacing.xl,
                  ),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _TourPreviewCard(
                      c: c,
                      title: _titleCtrl.text.trim(),
                      fromCity: _fromCtrl.text.trim(),
                      toCity: _toCtrl.text.trim(),
                      departureDate: _departureDate,
                      price: _priceCtrl.text.trim(),
                    ),
                    const SizedBox(height: UgamSpacing.xl),
                    UgamInput(
                      label: tr('create_tour.label.tour_name'),
                      controller: _titleCtrl,
                      errorText: _titleError,
                    ),
                    const SizedBox(height: UgamSpacing.lg),
                    // Was a hand-rolled `micro` + `.toUpperCase()`. The
                    // uppercasing is a no-op in Gujarati and Hindi (neither
                    // script has case), so the emphasis has to come from the
                    // style — which is exactly what the shared eyebrow is for.
                    UgamSectionLabel(
                      tr('create_tour.label.route'),
                      color: c.ink2,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    if (MediaQuery.of(context).size.width < 400) ...[
                      UgamInput(controller: _fromCtrl, errorText: _fromError),
                      const SizedBox(height: UgamSpacing.xs),
                      Center(child: _RouteArrow(c: c, vertical: true)),
                      const SizedBox(height: UgamSpacing.xs),
                      UgamInput(controller: _toCtrl, errorText: _toError),
                    ] else ...[
                      Row(
                        children: [
                          Expanded(
                            child: UgamInput(
                              controller: _fromCtrl,
                              errorText: _fromError,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: UgamSpacing.tight,
                            ),
                            child: _RouteArrow(c: c, vertical: false),
                          ),
                          Expanded(
                            child: UgamInput(
                              controller: _toCtrl,
                              errorText: _toError,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.lg),
                    UgamSectionLabel(
                      tr('create_tour.label.date_range'),
                      color: c.ink2,
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    // Departure date paired with its departure time.
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: UgamPickerField(
                            icon: Icons.calendar_today_rounded,
                            placeholder: tr('create_tour.hint.start_date'),
                            value: _departureDate != null
                                ? Formatters.formatDateMedium(
                                    _departureDate!,
                                    locale: context.locale.languageCode,
                                  )
                                : '',
                            onTap: () => _pickDate(false),
                          ),
                        ),
                        const SizedBox(width: UgamSpacing.sm),
                        Expanded(
                          flex: 2,
                          child: UgamPickerField(
                            icon: Icons.access_time_rounded,
                            placeholder: tr('create_tour.hint.departure_time'),
                            value: _departureTime != null
                                ? _departureTime!.format(context)
                                : '',
                            onTap: () => _pickTime(false),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    // Return date paired with its return time (both optional).
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: UgamPickerField(
                            icon: Icons.calendar_today_rounded,
                            placeholder: tr('create_tour.hint.end_date'),
                            value: _returnDate != null
                                ? Formatters.formatDateMedium(
                                    _returnDate!,
                                    locale: context.locale.languageCode,
                                  )
                                : '',
                            onTap: () => _pickDate(true),
                          ),
                        ),
                        const SizedBox(width: UgamSpacing.sm),
                        Expanded(
                          flex: 2,
                          child: UgamPickerField(
                            icon: Icons.access_time_rounded,
                            // Return time is DROPPED at save time unless a
                            // return date exists (see _save), so letting the
                            // agent pick one first was silent data loss. The
                            // field is held shut until the date is set, and the
                            // placeholder says which one to set.
                            enabled: _returnDate != null,
                            placeholder: _returnDate != null
                                ? tr('create_tour.hint.return_time')
                                : tr('edit_tour.return_time_locked'),
                            value: _returnDate != null && _returnTime != null
                                ? _returnTime!.format(context)
                                : '',
                            onTap: () => _pickTime(true),
                          ),
                        ),
                      ],
                    ),
                    if (_dateError != null) ...[
                      const SizedBox(height: UgamSpacing.xs),
                      Text(
                        _dateError!,
                        style: UgamText.caption.copyWith(color: c.danger),
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.lg),
                    UgamInput(
                      label: tr('create_tour.label.price_per_seat'),
                      controller: _priceCtrl,
                      keyboardType: TextInputType.number,
                    ),
                    if (tour.buses.length >= 2) ...[
                      const SizedBox(height: UgamSpacing.lg),
                      _ApplyPriceSheetCard(
                        c: c,
                        onTap: _saving ? null : _applyPriceSheet,
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.lg),
                    UgamInput(
                      label: tr('create_tour.label.tour_description'),
                      controller: _descCtrl,
                      maxLength: _descMaxLength,
                    ),
                    // UgamInput blanks TextField's own counter, so the 300-char
                    // cap was invisible: typing simply stopped, with nothing on
                    // screen saying why. Shown from 80% so it appears before it
                    // starts mattering, and turns danger-inked at the ceiling.
                    if (_descCtrl.text.characters.length >=
                        _descMaxLength * 0.8) ...[
                      const SizedBox(height: UgamSpacing.xs),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          tr(
                            'edit_tour.desc_counter',
                            namedArgs: {
                              'count': '${_descCtrl.text.characters.length}',
                              'max': '$_descMaxLength',
                            },
                          ),
                          style: UgamText.tabular(
                            UgamText.caption.copyWith(
                              color: _descCtrl.text.characters.length >=
                                      _descMaxLength
                                  ? c.danger
                                  : c.ink3,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.lg),
                    // Booking mode + collection details live behind their own
                    // sheet: they save immediately through a narrow column
                    // update, separate from this form's save, because those
                    // columns are deliberately outside Tour.toMap.
                    UgamPickerField(
                      label: tr('booking_settings.title'),
                      value: tour.bookingMode.displayName,
                      icon: Icons.event_seat_outlined,
                      // The sheet writes straight through to the controller,
                      // and this screen is not reactive — without the rebuild
                      // the field kept showing the OLD booking mode until the
                      // agent left and came back.
                      onTap: () async {
                        await showBookingSettingsSheet(context, tour);
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                ),
              ),
            ),
            // Save alone gets the sticky bar.
            //
            // "Cancel changes" used to sit beside it as a natural-width sibling
            // of an Expanded CTA — the exact shape that overflows here. At
            // 375pt and the 1.3× text scale this app allows, the Gujarati
            // "ફેરફાર રદ કરો" pill takes over half the row and squeezes the
            // primary action down to an ellipsis. Revert is a secondary,
            // confirmed action, so it moved to the app bar next to Delete and
            // the CTA can no longer be truncated by it.
            UgamStickyCTA(
              child: UgamCTA(
                label: _saving
                    ? tr('edit_tour.btn_saving')
                    : tr('edit_tour.btn_save_changes'),
                leadingIcon: Icons.save_rounded,
                loading: _saving,
                onPressed: _saving ? null : _save,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shown instead of the form when the tour cannot be resolved — deleted from
  /// another screen, or a list that has not finished loading. The form used to
  /// render regardless, seeded with empty strings, so it looked like a real
  /// (blank) tour that could be saved over.
  Widget _missingTour(UgamColorSet c) {
    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(title: tr('edit_tour.title')),
            Expanded(
              child: UgamEmpty(
                icon: Icons.map_outlined,
                title: tr('edit_tour.not_found.title'),
                body: tr('edit_tour.not_found.body'),
                cta: UgamButton(
                  label: tr('app.action.retry'),
                  icon: Icons.refresh_rounded,
                  kind: UgamButtonKind.neutral,
                  onPressed: () => setState(() {}),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The circle between the From and To city fields.
///
/// Was `accentFill` + `accent` in both orientations. A direction glyph is
/// decoration, not a selection or an ownership state, so per the accent rule it
/// carries no brand hue — and this screen was spending copper on it three times
/// over (here, and on both preview pills) while the actual amber signal, the
/// focused field ring, had to compete with all of it.
class _RouteArrow extends StatelessWidget {
  final UgamColorSet c;
  final bool vertical;

  const _RouteArrow({required this.c, required this.vertical});

  @override
  Widget build(BuildContext context) {
    final d = UgamScale.px(context, 30);
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(
        vertical ? Icons.arrow_downward_rounded : Icons.arrow_forward_rounded,
        size: UgamScale.px(context, 14),
        color: c.ink2,
      ),
    );
  }
}

/// One-tap entry into the "apply this price sheet to all buses" flow. Only
/// shown when the tour has two or more buses (nothing to copy with one).
class _ApplyPriceSheetCard extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback? onTap;

  const _ApplyPriceSheetCard({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return UgamCard.plain(
      onTap: onTap,
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          Container(
            // Decorative medallion — scales with the device, never a tap box
            // of its own (the whole card is the target).
            width: UgamScale.px(context, 38),
            height: UgamScale.px(context, 38),
            decoration: BoxDecoration(
              // Neutral, not accentFill: copying a price sheet is an action,
              // not something the agent owns, and this screen already spends
              // its one amber on the focused field.
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.stat),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.content_copy_rounded,
              size: UgamScale.px(context, 18),
              color: enabled ? c.ink2 : c.ink3,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('edit_tour.price_sheet.card_title'),
                  // `bodyStrong` IS 14 — the override was a no-op that made
                  // this look like a deliberate off-ladder size.
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('edit_tour.price_sheet.card_subtitle'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Icon(Icons.chevron_right_rounded, color: c.ink3),
        ],
      ),
    );
  }
}

class _TourPreviewCard extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  final String fromCity;
  final String toCity;
  final DateTime? departureDate;
  final String price;

  const _TourPreviewCard({
    required this.c,
    required this.title,
    required this.fromCity,
    required this.toCity,
    required this.departureDate,
    required this.price,
  });

  /// Route-initials monogram for the graphite backdrop, e.g. "S→M".
  String? _routeLabel() {
    final f = fromCity.trim();
    final t = toCity.trim();
    if (f.isEmpty || t.isEmpty) return null;
    return '${f[0].toUpperCase()}→${t[0].toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final shownTitle = title.isNotEmpty ? title : tr('edit_tour.preview.untitled');
    final from = fromCity.isNotEmpty ? fromCity : tr('edit_tour.hint_from_city');
    final to = toCity.isNotEmpty ? toCity : tr('edit_tour.hint_to_city');
    final route = '$from → $to';
    final dateText = departureDate != null
        ? Formatters.formatDateMedium(
            departureDate!,
            locale: context.locale.languageCode,
          )
        : tr('edit_tour.preview.pick_date');
    final setPriceLabel = tr('edit_tour.preview.set_price');
    final priceText = () {
      final n = double.tryParse(price);
      if (n == null || n <= 0) return setPriceLabel;
      return tr(
        'edit_tour.preview.per_seat',
        namedArgs: {'price': n.toStringAsFixed(0)},
      );
    }();

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.photo),
            child: SizedBox(
              // Decorative thumbnail — scales down with the device so it does
              // not eat a fixed 64pt of a 375pt-wide card.
              width: UgamScale.px(context, 64),
              height: UgamScale.px(context, 64),
              child: UgamBusBackdrop(
                seed: 'preview-${fromCity}_$toCity',
                label: _routeLabel(),
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    UgamReqChip(label: tr('edit_tour.preview.eyebrow')),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        tr('edit_tour.preview.as_customer'),
                        style: UgamText.caption.copyWith(color: c.ink3),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  shownTitle,
                  style: UgamText.titleM.copyWith(
                    color: title.isNotEmpty ? c.ink : c.ink3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  route,
                  style: UgamText.caption.copyWith(
                    color: (fromCity.isNotEmpty && toCity.isNotEmpty)
                        ? c.ink2
                        : c.ink3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: UgamSpacing.sm),
                Wrap(
                  // 6 is off-ladder (xs=4, sm=8) but is the pill gutter the
                  // rest of this card already uses; see the reported gap.
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _PreviewPill(
                      c: c,
                      icon: Icons.calendar_today_rounded,
                      label: dateText,
                      muted: departureDate == null,
                    ),
                    _PreviewPill(
                      c: c,
                      icon: Icons.currency_rupee_rounded,
                      label: priceText,
                      muted: priceText == setPriceLabel,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single fact in the customer-preview card: the departure date, the fare.
///
/// `muted` means "not set yet". That distinction used to be carried by copper
/// vs grey — two amber pills side by side on a screen whose amber is supposed
/// to mean "this is yours". It is carried by INK now (set = `ink`, unset =
/// `ink3`) on one shared neutral fill, which reads the same in both themes and
/// leaves the accent to the focused field.
class _PreviewPill extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final bool muted;

  const _PreviewPill({
    required this.c,
    required this.icon,
    required this.label,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final ink = muted ? c.ink3 : c.ink;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.sm,
        vertical: UgamSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: UgamScale.px(context, 12), color: ink),
          const SizedBox(width: UgamSpacing.xs),
          Flexible(
            child: Text(
              label,
              // Was `caption` forced down to 11 — an off-ladder size invented
              // for this one pill. `caption` (12) with the weight bumped says
              // the same thing on the scale the rest of the app uses.
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
