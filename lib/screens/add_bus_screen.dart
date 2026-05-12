import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../controllers/tour_controller.dart';
import '../models/bus_details.dart';
import '../models/bus_type.dart';
import '../models/seat_layout.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';

/// Form for adding a bus to a tour. Mirrors the Pencil "Add Bus" screen:
/// bus number / driver / driver phone / AC toggle / total seats stepper /
/// bus type chips. For Mixed buses, an extra sleeper-vs-seater split row
/// appears so the auto-layout knows what mix to generate.
class AddBusScreen extends StatefulWidget {
  final String tourId;

  const AddBusScreen({super.key, required this.tourId});

  @override
  State<AddBusScreen> createState() => _AddBusScreenState();
}

class _AddBusScreenState extends State<AddBusScreen> {
  final _slotLabel = TextEditingController();
  final _busNumber = TextEditingController();
  final _driverName = TextEditingController();
  final _driverPhone = TextEditingController();
  final _price = TextEditingController();
  bool _isAC = true;
  int _totalSeats = 40;
  BusType _busType = BusType.sleeper;
  int _seaterCountForMixed = 6;
  // How many sleeper berths should be Single Sofa (1-person). The rest of
  // the sleeper seats become Double Sofa. 0 means "all double" — matches
  // the pre-existing behaviour.
  int _singleSofaCount = 0;
  bool _saving = false;
  bool _priceInitialized = false;
  bool _slotLabelInitialized = false;

  TourController get _tourCtrl => Get.find<TourController>();

  Tour? get _tour => _tourCtrl.getTour(widget.tourId);

  /// Default slot label suggested for this bus, e.g. "Bus 1", "Bus 2".
  /// Agents can override this in the text field — each bus in a tour can
  /// carry whatever label is useful (e.g. "Express", "Bus A").
  String get _defaultSlotLabel {
    final tour = _tour;
    if (tour == null) return 'Bus 1';
    return 'Bus ${tour.buses.length + 1}';
  }

  /// Sleeper seats currently configured on this form. Used to clamp the
  /// Single Sofa stepper and to gate the Mixed-mode seater split.
  int get _sleeperSeats => switch (_busType) {
        BusType.sleeper => _totalSeats,
        BusType.mixed => _totalSeats - _seaterCountForMixed,
        BusType.seater => 0,
      };

  String get _subtitle {
    final tour = _tour;
    if (tour == null) return '';
    final label = _slotLabel.text.trim().isEmpty
        ? _defaultSlotLabel
        : _slotLabel.text.trim();
    return '${tour.title} · $label';
  }

  String get _capacityHint {
    final tour = _tour;
    if (tour == null) return '';
    final busCount = tour.buses.length;
    final existingTotal = tour.buses.fold<int>(0, (s, b) => s + b.totalSeats);
    if (busCount == 0) return tr('add_bus.info.first_bus');
    final seatsLabel = existingTotal == 1
        ? tr('add_bus.info.seat')
        : tr('add_bus.info.seats');
    final key = busCount == 1
        ? 'add_bus.info.existing_buses_one'
        : 'add_bus.info.existing_buses_other';
    return tr(key, namedArgs: {
      'count': '$busCount',
      'seats': '$existingTotal',
      'seats_label': seatsLabel,
    });
  }

  @override
  void dispose() {
    _slotLabel.dispose();
    _busNumber.dispose();
    _driverName.dispose();
    _driverPhone.dispose();
    _price.dispose();
    super.dispose();
  }

  /// Seed the price input with the tour-level default the first time we
  /// have access to the tour (Obx may rebuild before tour is loaded).
  void _maybeSeedPrice() {
    if (_priceInitialized) return;
    final tour = _tour;
    if (tour == null) return;
    if (tour.pricePerSeat > 0) {
      _price.text = tour.pricePerSeat.toStringAsFixed(0);
    }
    _priceInitialized = true;
  }

  /// Seed the slot label once we know the tour's current bus count, so
  /// the suggested "Bus N" appears in the field but the agent can edit it.
  void _maybeSeedSlotLabel() {
    if (_slotLabelInitialized) return;
    final tour = _tour;
    if (tour == null) return;
    _slotLabel.text = _defaultSlotLabel;
    _slotLabelInitialized = true;
  }

  Future<void> _save() async {
    if (_busType == BusType.mixed && _seaterCountForMixed >= _totalSeats) {
      AppSnackBar.error(tr('add_bus.snackbar.error_seater_count'));
      return;
    }
    if (_singleSofaCount > _sleeperSeats) {
      AppSnackBar.error(tr('add_bus.snackbar.error_single_sofa'));
      return;
    }

    final tour = _tour;
    if (tour == null) {
      AppSnackBar.error(tr('add_bus.snackbar.error_tour_not_found'));
      return;
    }

    final layout = BusLayout.generate(
      busType: _busType,
      totalSeats: _totalSeats,
      seaterCount: _busType == BusType.mixed ? _seaterCountForMixed : 0,
      singleSofaCount: _singleSofaCount,
    );

    final priceText = _price.text.trim();
    final pricePerSeat = priceText.isEmpty
        ? tour.pricePerSeat
        : (double.tryParse(priceText) ?? tour.pricePerSeat);

    final slotLabel = _slotLabel.text.trim().isEmpty
        ? _defaultSlotLabel
        : _slotLabel.text.trim();

    final bus = Bus(
      name: slotLabel,
      busNumber: _busNumber.text.trim(),
      driverName: _driverName.text.trim(),
      driverPhone: _driverPhone.text.trim(),
      isAC: _isAC,
      busType: _busType.displayName,
      totalSeatsLegacy: _totalSeats,
      pricePerSeat: pricePerSeat,
      layout: layout,
    );

    setState(() => _saving = true);
    try {
      await _tourCtrl.addBus(widget.tourId, bus);
      if (!mounted) return;
      AppSnackBar.success(
        tr('add_bus.snackbar.added', namedArgs: {'name': bus.name}),
      );
      Get.back();
    } catch (e) {
      AppSnackBar.error(tr('add_bus.snackbar.error_save'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String get _mixedSummary {
    final sleeperCount = _totalSeats - _seaterCountForMixed;
    final sleeperKey = sleeperCount == 1
        ? 'add_bus.summary.mixed_one_sleeper'
        : 'add_bus.summary.mixed_many_sleeper';
    final seaterLabel = _seaterCountForMixed == 1
        ? tr('add_bus.summary.seater')
        : tr('add_bus.summary.seaters');
    return tr(sleeperKey, namedArgs: {
      'sleeper': '$sleeperCount',
      'seater': '$_seaterCountForMixed',
      'seater_label': seaterLabel,
    });
  }

  String get _singleSofaSummary {
    final doubleCount = _sleeperSeats - _singleSofaCount;
    final summaryKey = _singleSofaCount == 1
        ? 'add_bus.summary.single_sofa_summary_one'
        : 'add_bus.summary.single_sofa_summary_other';
    final doubleLabel = doubleCount == 1
        ? tr('add_bus.summary.double_sofa')
        : tr('add_bus.summary.double_sofas');
    return tr(summaryKey, namedArgs: {
      'single': '$_singleSofaCount',
      'double': '$doubleCount',
      'double_label': doubleLabel,
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    _maybeSeedPrice();
    _maybeSeedSlotLabel();

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            _Header(subtitle: _subtitle),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                physics: const BouncingScrollPhysics(),
                children: [
                  // Editable slot label. Each bus on a tour can carry a
                  // custom name (e.g. "Bus 1", "Bus A", "Express"). Pre-filled
                  // with an auto-numbered suggestion so the common case is
                  // zero-typing.
                  _FieldLabel(tr('add_bus.label.slot_label')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _slotLabel,
                    textCapitalization: TextCapitalization.words,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: _defaultSlotLabel,
                    ),
                  ),
                  const SizedBox(height: 18),

                  if (_capacityHint.isNotEmpty)
                    _InfoBanner(
                      text:
                          '${tr('add_bus.info.optional_fields')}'
                          '\n\n$_capacityHint',
                      isDark: isDark,
                    ),
                  const SizedBox(height: 16),

                  _OptionalLabel(tr('add_bus.label.bus_number')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _busNumber,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: tr('add_bus.hint.bus_number'),
                    ),
                  ),
                  const SizedBox(height: 18),

                  _OptionalLabel(tr('add_bus.label.driver_name')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _driverName,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(
                      hintText: tr('add_bus.hint.driver_name'),
                    ),
                  ),
                  const SizedBox(height: 18),

                  _OptionalLabel(tr('add_bus.label.driver_phone')),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: isDark
                              ? AppTheme.cardDark
                              : AppTheme.bgLight,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isDark
                                ? AppTheme.borderDark
                                : AppTheme.borderLight,
                          ),
                        ),
                        child: Text(
                          '+91',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _driverPhone,
                          keyboardType: TextInputType.phone,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(10),
                          ],
                          decoration: const InputDecoration(
                            hintText: '98765 43210',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  _ToggleRow(
                    label: tr('add_bus.label.ac_bus'),
                    value: _isAC,
                    onChanged: (v) => setState(() => _isAC = v),
                  ),
                  const SizedBox(height: 18),

                  _FieldLabel(tr('add_bus.label.total_seats')),
                  const SizedBox(height: 8),
                  _Stepper(
                    value: _totalSeats,
                    min: 1,
                    max: 100,
                    onChanged: (v) => setState(() {
                      _totalSeats = v;
                      if (_seaterCountForMixed >= v) {
                        _seaterCountForMixed = (v - 1).clamp(0, v);
                      }
                      if (_singleSofaCount > _sleeperSeats) {
                        _singleSofaCount = _sleeperSeats;
                      }
                    }),
                  ),
                  const SizedBox(height: 18),

                  _FieldLabel(tr('add_bus.label.price_per_seat')),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _price,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    decoration: InputDecoration(
                      prefixText: '₹ ',
                      hintText: _tour != null && _tour!.pricePerSeat > 0
                          ? tr(
                              'add_bus.hint.price_default',
                              namedArgs: {
                                'price': _tour!.pricePerSeat
                                    .toStringAsFixed(0),
                              },
                            )
                          : tr('add_bus.hint.price_plain'),
                    ),
                  ),
                  const SizedBox(height: 18),

                  _FieldLabel(tr('add_bus.label.bus_type')),
                  const SizedBox(height: 8),
                  _BusTypeChips(
                    value: _busType,
                    onChanged: (t) => setState(() => _busType = t),
                  ),

                  if (_busType == BusType.mixed) ...[
                    const SizedBox(height: 18),
                    _FieldLabel(tr('add_bus.label.seater_count')),
                    const SizedBox(height: 8),
                    _Stepper(
                      value: _seaterCountForMixed,
                      min: 1,
                      max: _totalSeats - 1,
                      onChanged: (v) => setState(() {
                        _seaterCountForMixed = v;
                        if (_singleSofaCount > _sleeperSeats) {
                          _singleSofaCount = _sleeperSeats;
                        }
                      }),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _mixedSummary,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],

                  // Single vs Double Sofa split — only meaningful when the
                  // bus actually has sleeper berths. Without this, every
                  // sleeper seat defaults to Double Sofa and customers
                  // requesting a Single Sofa have nothing to be assigned to.
                  if (_sleeperSeats > 0) ...[
                    const SizedBox(height: 18),
                    _FieldLabel(tr('add_bus.label.single_sofa_count')),
                    const SizedBox(height: 8),
                    _Stepper(
                      value: _singleSofaCount,
                      min: 0,
                      max: _sleeperSeats,
                      onChanged: (v) =>
                          setState(() => _singleSofaCount = v),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _singleSofaSummary,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],

                  const SizedBox(height: 28),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: isDark
                        ? AppTheme.borderDark
                        : AppTheme.borderLight,
                  ),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.add_rounded, size: 20),
                  label: Text(
                    _saving
                        ? tr('add_bus.action.saving')
                        : tr('add_bus.action.save'),
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String subtitle;

  const _Header({required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 20, 8),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back, color: theme.colorScheme.onSurface),
            onPressed: () => Get.back(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('add_bus.title'),
                  style: GoogleFonts.inter(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final String text;
  final bool isDark;

  const _InfoBanner({required this.text, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.brandLight,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.brand.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 16, color: AppTheme.brand),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                color: AppTheme.brandDark,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;
  const _FieldLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label,
      style: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurface,
      ),
    );
  }
}

class _OptionalLabel extends StatelessWidget {
  final String label;
  const _OptionalLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          tr('add_bus.label.optional'),
          style: GoogleFonts.inter(
            fontSize: 11,
            fontStyle: FontStyle.italic,
            color: AppTheme.textMuted,
          ),
        ),
      ],
    );
  }
}


class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? AppTheme.borderDark : AppTheme.borderLight,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _Stepper({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDark ? AppTheme.borderDark : AppTheme.borderLight,
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: value > min ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_rounded),
          ),
          Expanded(
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          IconButton(
            onPressed: value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }
}

class _BusTypeChips extends StatelessWidget {
  final BusType value;
  final ValueChanged<BusType> onChanged;

  const _BusTypeChips({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: BusType.values.map((type) {
        final isLast = type == BusType.values.last;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: isLast ? 0 : 8),
            child: _Chip(
              label: type.displayName,
              selected: type == value,
              onTap: () => onChanged(type),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.brand
              : (isDark ? AppTheme.cardDark : Colors.white),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? AppTheme.brand
                : (isDark ? AppTheme.borderDark : AppTheme.borderLight),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
