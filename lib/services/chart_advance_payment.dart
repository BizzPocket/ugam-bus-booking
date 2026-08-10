import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../utils/upi_uri.dart';
import '../widgets/upi_payment_sheet.dart';
import 'customer_requests_store.dart';

/// Shows the advance UPI sheet and records the customer's claim.
///
/// *** WHY THIS IS A SERVICE AND NOT A METHOD ON THE CHECKOUT SCREEN ***
/// It used to live privately inside `SeatBookingConfirmScreen`, which meant the
/// ONLY moment a customer could ever pay was the single sheet shown
/// immediately after their seats were held. Dismiss it — fumble the UPI app,
/// take a call, misread it as optional — and:
///
///   * the hold stayed alive, so their berths stayed blocked for everyone else;
///   * "Seats held" was announced and the screen popped;
///   * and no surface anywhere offered to pay. The booking was unrecoverable
///     from the customer's side until the hold silently lapsed.
///
/// Both the checkout sheet and the "Pay advance" retry in My Requests now drive
/// this one path, so the two cannot drift apart.
class ChartAdvancePayment {
  const ChartAdvancePayment._();

  /// Returns true when the customer asserted a payment and the claim was
  /// recorded. False covers both "they closed the sheet" and "recording
  /// failed" — neither of which should ever release the hold, because the
  /// seats stay theirs until the hold's own deadline.
  static Future<bool> collect({
    required BuildContext context,
    required String requestId,
    required String payeeVpa,
    required String payeeName,
    required int amountPaise,
    required String note,
    String? holdId,
    String? subtitle,
  }) async {
    if (amountPaise <= 0) return false;

    final claim = await showUpiPaymentSheet(
      context,
      request: collectPayment(
        vpa: payeeVpa,
        payeeName: payeeName,
        amountPaise: amountPaise,
        note: note,
        bookingRef: requestId,
      ),
      title: tr('seat_confirm.advance_title'),
      subtitle: subtitle,
      askConfirmation: true,
    );

    // Dismissed. The hold deliberately survives — see the countdown and retry
    // on My Requests. Releasing here would punish a customer who simply wants
    // to try their UPI app again.
    if (claim == null) return false;

    final store = CustomerRequestsStore();
    final claimId = holdId != null
        ? await store.claimUpiAdvanceForHold(
            holdId: holdId,
            amountPaise: amountPaise,
            reference: claim.reference,
          )
        : await store.claimUpiAdvance(
            requestId: requestId,
            amountPaise: amountPaise,
            reference: claim.reference,
          );

    if (!context.mounted) return claimId != null;
    if (claimId == null) {
      AppSnackBar.error(tr('upi.claim_failed'));
      return false;
    }
    AppSnackBar.success(tr('upi.claim_saved'));
    return true;
  }

  /// Re-open the advance sheet for a ticket already sitting on a live hold.
  ///
  /// Everything it needs was captured on the ticket when the hold was created,
  /// so this works offline-first and cannot silently re-quote if the organiser
  /// edits the tour's advance after the seats were held.
  static Future<bool> retry({
    required BuildContext context,
    required CustomerRequestEntry entry,
  }) {
    return collect(
      context: context,
      requestId: entry.id,
      holdId: entry.holdId,
      payeeVpa: entry.collectVpa!,
      payeeName: (entry.collectPayeeName?.trim().isNotEmpty ?? false)
          ? entry.collectPayeeName!
          : entry.tourTitle,
      amountPaise: entry.advancePaise,
      note: '${entry.tourFromCity}-${entry.tourToCity} · ${entry.customerName}',
      subtitle: tr(
        'seat_confirm.advance_note',
        namedArgs: {
          'total': Formatters.formatMoneyInr(
            entry.tourPricePerSeat * entry.partySize,
          ),
        },
      ),
    );
  }
}
