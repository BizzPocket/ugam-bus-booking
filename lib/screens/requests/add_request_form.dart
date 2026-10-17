part of '../requests_screen.dart';

// ─── Add request sheet ────────────────────────────────────────────────

/// Bottom-sheet wrapper for the agent-side direct-add flow. The inputs are the
/// shared [BookingCaptureForm] (with admin contact picker + autocomplete);
/// this wrapper only owns the intro line, the Save CTA, and persistence via
/// [TourController.addPassenger].
class _AddRequestForm extends StatefulWidget {
  final Tour tour;

  const _AddRequestForm({required this.tour});

  @override
  State<_AddRequestForm> createState() => _AddRequestFormState();
}

class _AddRequestFormState extends State<_AddRequestForm> {
  // GlobalKey-style contract: the form is a pure collector, this wrapper reads
  // its validated result and owns the submit button + persistence.
  final _formKey = GlobalKey<BookingCaptureFormState>();
  final _userCtrl = Get.find<UserController>();

  bool _saving = false;

  // Live seat count for the Save CTA chip — updated via the form's onChanged.
  int _seatCount = 0;

  Future<void> _submit() async {
    final data = _formKey.currentState?.collect();
    if (data == null) return; // invalid — the form already showed inline errors.

    setState(() => _saving = true);
    try {
      final passenger = Passenger(
        tourId: widget.tour.id,
        name: data.name,
        phone: data.normalisedPhone,
        requestLines: data.lines,
        note: data.note,
        tripType: data.tripType,
        pickupLocationId: data.pickupLocationId,
        pickupLocationName: data.pickupLocationName,
      );
      await Get.find<TourController>().addPassenger(
        widget.tour.id,
        passenger,
        // The organiser is adding a rider by hand — bypass the acceptsBookings
        // gate so a locked tour can still take a late walk-in/phone booking.
        // Customers stay blocked at the submit_booking_request RPC (026/030).
        overrideLock: true,
      );
      // Remember this customer in the admin's directory so the name
      // autocompletes next time — covers people who aren't in the phonebook.
      // rememberContact wants the RAW 10-digit phone.
      // ignore: unawaited_futures
      _userCtrl.rememberContact(name: data.name, phone: data.phone);
      if (!mounted) return;
      Get.back();
      final total = data.totalSeats;
      AppSnackBar.success(
        total == 1
            ? tr('requests.snack.added_one', namedArgs: {'name': data.name})
            : tr(
                'requests.snack.added_many',
                namedArgs: {'name': data.name, 'count': '$total'},
              ),
      );
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('requests.snack.add_error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // Tapping empty space unfocuses the name field, which dismisses the
    // contact-autocomplete dropdown (opaque so gaps between fields count as
    // taps; the scroll view still wins drags and fields still take their taps).
    //
    // The PopScope guards the accidental dismiss: once the agent has entered
    // seats there is unsaved work and no draft persistence, so a scrim tap or
    // system back asks before throwing the booking away. `_seatCount > 0` is
    // the only dirty signal this wrapper owns — the form's own field state is
    // private to BookingCaptureFormState.
    return PopScope(
      canPop: _seatCount == 0,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _seatCount == 0) return;
        final discard = await UgamDialog.confirm(
          context,
          title: tr('requests.discard_dialog.title'),
          message: tr('requests.discard_dialog.body'),
          cancelLabel: tr('app.action.cancel'),
          confirmLabel: tr('requests.discard_dialog.confirm'),
          destructive: true,
          confirmIcon: Icons.close_rounded,
        );
        if (discard && context.mounted) Navigator.of(context).pop();
      },
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.opaque,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                tr(
                  'requests.sheet.subtitle',
                  namedArgs: {'tourTitle': widget.tour.title},
                ),
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
              const SizedBox(height: UgamSpacing.lg),
              BookingCaptureForm(
                key: _formKey,
                fromCity: widget.tour.fromCity,
                toCity: widget.tour.toCity,
                enableContacts: true,
                maxPerType: 10,
                onChanged: () {
                  final n = _formKey.currentState?.totalSeats ?? 0;
                  if (n != _seatCount) setState(() => _seatCount = n);
                },
              ),
              const SizedBox(height: UgamSpacing.lg),
              UgamCTA(
                label: _saving
                    ? tr('requests.sheet.saving')
                    : tr('requests.sheet.save'),
                leadingIcon: Icons.check_rounded,
                trailingValue: _seatCount > 0 ? '$_seatCount' : null,
                loading: _saving,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
