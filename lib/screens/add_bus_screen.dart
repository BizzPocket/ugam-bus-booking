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
  final _busNumber = TextEditingController();
  final _driverName = TextEditingController();
  final _driverPhone = TextEditingController();
  bool _isAC = true;
  int _totalSeats = 40;
  BusType _busType = BusType.sleeper;
  int _seaterCountForMixed = 6;
  bool _saving = false;

  TourController get _tourCtrl => Get.find<TourController>();

  Tour? get _tour => _tourCtrl.getTour(widget.tourId);

  String get _subtitle {
    final tour = _tour;
    if (tour == null) return '';
    final busCount = tour.buses.length;
    return '${tour.title} · Bus ${busCount + 1}';
  }

  String get _capacityHint {
    final tour = _tour;
    if (tour == null) return '';
    final busCount = tour.buses.length;
    final existingTotal = tour.buses.fold<int>(0, (s, b) => s + b.totalSeats);
    if (busCount == 0) return 'This is the first bus for this tour.';
    return 'This tour has $busCount '
        '${busCount == 1 ? 'bus' : 'buses'} with $existingTotal '
        '${existingTotal == 1 ? 'seat' : 'seats'} total. Adding this bus will '
        'increase capacity.';
  }

  @override
  void dispose() {
    _busNumber.dispose();
    _driverName.dispose();
    _driverPhone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final busNumber = _busNumber.text.trim();
    final driverName = _driverName.text.trim();
    final driverPhone = _driverPhone.text.trim();

    if (busNumber.isEmpty) {
      AppSnackBar.error('Bus number is required');
      return;
    }
    if (driverName.isEmpty) {
      AppSnackBar.error('Driver name is required');
      return;
    }
    if (_busType == BusType.mixed && _seaterCountForMixed >= _totalSeats) {
      AppSnackBar.error('Seater count must be less than total seats');
      return;
    }

    final tour = _tour;
    if (tour == null) {
      AppSnackBar.error('Tour not found');
      return;
    }

    final layout = BusLayout.generate(
      busType: _busType,
      totalSeats: _totalSeats,
      seaterCount: _busType == BusType.mixed ? _seaterCountForMixed : 0,
    );

    final bus = Bus(
      tourId: widget.tourId,
      name: 'Bus ${tour.buses.length + 1}',
      busNumber: busNumber,
      driverName: driverName,
      driverPhone: driverPhone,
      isAC: _isAC,
      busType: _busType.displayName,
      totalSeatsLegacy: _totalSeats,
      layout: layout,
    );

    setState(() => _saving = true);
    try {
      await _tourCtrl.addBus(widget.tourId, bus);
      if (!mounted) return;
      AppSnackBar.success('${bus.name} added');
      Get.back();
    } catch (e) {
      AppSnackBar.error('Could not save bus — try again');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

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
                  if (_capacityHint.isNotEmpty)
                    _InfoBanner(text: _capacityHint, isDark: isDark),
                  const SizedBox(height: 16),

                  _FieldLabel('Bus Number'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _busNumber,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: 'e.g. GJ-05-AB-1234',
                    ),
                  ),
                  const SizedBox(height: 18),

                  _FieldLabel('Driver Name'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _driverName,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      hintText: "Enter driver's full name",
                    ),
                  ),
                  const SizedBox(height: 18),

                  _FieldLabel('Driver Phone'),
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
                    label: 'AC Bus',
                    value: _isAC,
                    onChanged: (v) => setState(() => _isAC = v),
                  ),
                  const SizedBox(height: 18),

                  _FieldLabel('Total Seats'),
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
                    }),
                  ),
                  const SizedBox(height: 18),

                  _FieldLabel('Bus Type'),
                  const SizedBox(height: 8),
                  _BusTypeChips(
                    value: _busType,
                    onChanged: (t) => setState(() => _busType = t),
                  ),

                  if (_busType == BusType.mixed) ...[
                    const SizedBox(height: 18),
                    _FieldLabel('Seater Count (rest are Sleeper)'),
                    const SizedBox(height: 8),
                    _Stepper(
                      value: _seaterCountForMixed,
                      min: 1,
                      max: _totalSeats - 1,
                      onChanged: (v) =>
                          setState(() => _seaterCountForMixed = v),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${_totalSeats - _seaterCountForMixed} sleeper berth'
                      '${_totalSeats - _seaterCountForMixed == 1 ? '' : 's'}'
                      ' + $_seaterCountForMixed seater'
                      '${_seaterCountForMixed == 1 ? '' : 's'}',
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
                    _saving ? 'Saving…' : 'Save Bus',
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
                  'Add Bus',
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
