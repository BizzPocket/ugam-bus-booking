part of '../booking_capture_form.dart';

// ─── CONTACT PICKER SHEET (self-contained) ──────────────────────────────────

/// Searchable device-contacts picker. Reads the phone directory on open (via
/// [ContactSyncService], which handles the permission prompt) and pops the
/// chosen [DeviceContactEntry]. Inlined here so [BookingCaptureForm] depends on
/// no screen — only the public contact service. Mirrors the admin requests
/// screen's picker so behaviour stays identical across surfaces.
class _ContactPickerSheet extends StatefulWidget {
  const _ContactPickerSheet();

  @override
  State<_ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<_ContactPickerSheet> {
  final _search = TextEditingController();
  List<DeviceContactEntry> _all = const [];
  bool _loading = true;
  bool _denied = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = ContactSyncService();
    final list = await svc.pullDeviceContacts();
    // pullDeviceContacts returns [] for BOTH "denied" and "no contacts" — only
    // call it denied when permission truly isn't granted.
    final granted = list.isNotEmpty || await svc.hasPermission();
    if (!mounted) return;
    setState(() {
      _all = [...list]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _loading = false;
      _denied = !granted;
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts.first.isNotEmpty && parts.last.isNotEmpty) {
      return '${parts.first.characters.first}${parts.last.characters.first}'.toUpperCase();
    }
    return name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    if (_loading) {
      return SizedBox(
        height: 160,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                ),
              ),
              const SizedBox(height: UgamSpacing.md),
              Text(
                tr('booking_form.contacts_loading'),
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ],
          ),
        ),
      );
    }

    if (_denied) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.contacts_outlined, size: 34, color: c.ink3),
            const SizedBox(height: UgamSpacing.md),
            Text(
              tr('booking_form.contacts_denied'),
              style: UgamText.body.copyWith(color: c.ink2),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _all
        : _all
              .where(
                (e) => e.name.toLowerCase().contains(q) || e.phone.contains(q),
              )
              .toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UgamInput(
          hint: tr('booking_form.contacts_search_hint'),
          controller: _search,
          prefix: Icon(Icons.search_rounded, size: 18, color: c.ink3),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: UgamSpacing.md),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
            child: Center(
              child: Text(
                tr('booking_form.contacts_empty'),
                style: UgamText.body.copyWith(color: c.ink2),
              ),
            ),
          )
        else
          // Flexible (not a bare ConstrainedBox) so the list YIELDS to the
          // space the sheet actually has: on shorter screens the fixed 360
          // height + search field + sheet chrome overflowed the bottom. It
          // still caps at 360 and scrolls internally when there's room.
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: filtered.length,
                itemBuilder: (_, i) {
                  final e = filtered[i];
                  return InkWell(
                    onTap: () => Navigator.of(context).pop(e),
                    borderRadius: BorderRadius.circular(UgamRadius.input),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UgamSpacing.sm + 2,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: c.accentFill,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              _initials(e.name),
                              style: UgamText.bodyStrong.copyWith(
                                color: c.accent,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: UgamSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  e.name,
                                  style: UgamText.body.copyWith(color: c.ink),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  e.phone,
                                  style: UgamText.caption.copyWith(
                                    color: c.ink2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 20,
                            color: c.ink3,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

// ─── PICKUP PICKER SHEET (self-contained, single-select) ────────────────────

/// Sentinel popped by the "clear" row so the caller can tell an explicit
/// "No pickup point" apart from a dismissed sheet (which pops null). No real
/// pickup id (a uuid) can ever equal it.
const String _kPickupClear = '__pickup_clear__';

/// Single-select list of ACTIVE pickup points, with a top "clear" row. Pops the
/// chosen point's id, [_kPickupClear] for clear, or null when dismissed. The
/// currently-selected row shows a check. Mirrors the contact picker's row idiom.
class _PickupPickerSheet extends StatelessWidget {
  final List<PickupLocation> options;
  final String? selectedId;

  /// Whether to show the top "No pickup point" clear row. Off when pickup is
  /// mandatory so the customer can't re-empty a required field.
  final bool allowClear;

  const _PickupPickerSheet({
    required this.options,
    required this.selectedId,
    this.allowClear = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 400),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: options.length + (allowClear ? 1 : 0),
        itemBuilder: (_, i) {
          if (allowClear && i == 0) {
            return _PickupOptionRow(
              c: c,
              icon: Icons.not_interested_rounded,
              label: tr('pickup.clear'),
              selected: selectedId == null,
              onTap: () => Navigator.of(context).pop(_kPickupClear),
            );
          }
          final p = options[allowClear ? i - 1 : i];
          return _PickupOptionRow(
            c: c,
            icon: Icons.place_rounded,
            label: p.name,
            selected: p.id == selectedId,
            onTap: () => Navigator.of(context).pop(p.id),
          );
        },
      ),
    );
  }
}

class _PickupOptionRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PickupOptionRow({
    required this.c,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(UgamRadius.input),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm + 2),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? c.accentFill : c.cardElev,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: selected ? c.accent : c.ink2),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: UgamText.body.copyWith(color: c.ink),
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 20, color: c.accent),
          ],
        ),
      ),
    );
  }
}
