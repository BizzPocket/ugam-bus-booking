// Pure-Dart UPI deep-link / QR payload builder. NO Flutter imports, NO I/O.
//
// One string serves both jobs:
//   • LAUNCH it (url_launcher) → the payer's UPI app opens pre-filled. Used to
//     pay a vendor: bus owner rent, fuel, tolls, the handler's float.
//   • RENDER it as a QR → anyone scans with GPay / PhonePe / Paytm and pays.
//     Used to collect an advance from a customer.
//
// *** WHY THIS EXISTS ALONGSIDE A GATEWAY ***
// UPI paid straight from a bank account to a merchant is ZERO MDR by law
// (Payment & Settlement Systems Act s.10A + Income-tax Act s.269SU, in force
// since 1 Jan 2020). The ~2% a payment gateway charges on UPI is a PLATFORM
// fee for their software, not a cost of moving the money. So this path costs
// nothing at all.
//
// What a gateway buys you is ATTRIBUTION — knowing which passenger sent the
// money. [UpiRequest.reference] is how we get that back for free: `tr` is the
// merchant transaction reference from the NPCI URL spec, and it travels with
// the payment, so a settled amount can be matched to a booking or an expense.
//
// Spec: NPCI "UPI Linking Specifications" (common URL specification).
//   pa  payee VPA           (required)
//   pn  payee name          (required in practice; apps show it for confirmation)
//   am  amount, decimal     (STRONGLY recommended — see the note below)
//   cu  currency            (only "INR" is valid)
//   tn  transaction note    (short description)
//   tr  transaction ref     (merchant reference — our reconciliation hook)
//   mc  merchant category   (only for registered merchants)
//
// SECURITY — always set an amount. When `am` is absent the amount field is
// EDITABLE by the payer, which is the documented basis of UPI deep-link abuse
// (a shared link that looks like a fixed bill but isn't). Every request built
// here carries an amount; [UpiRequest] rejects a non-positive one.

/// A UPI payee: the VPA that receives the money, plus the name UPI apps show
/// on the confirmation screen.
class UpiPayee {
  final String vpa;
  final String name;

  const UpiPayee({required this.vpa, required this.name});

  bool get isValid => isValidVpa(vpa) && name.trim().isNotEmpty;
}

/// Whether [vpa] looks like a UPI handle (`something@bank`).
///
/// Deliberately permissive on the handle part — NPCI does not publish a closed
/// list of PSP suffixes and new ones appear regularly, so rejecting an unknown
/// bank would block real payees. What we DO enforce is the shape: a non-empty
/// account part, exactly one `@`, a non-empty handle, no whitespace, and only
/// characters the spec allows.
bool isValidVpa(String vpa) {
  final v = vpa.trim();
  if (v.isEmpty || v.length > 255) return false;
  return RegExp(r'^[a-zA-Z0-9.\-_]{2,}@[a-zA-Z][a-zA-Z0-9.\-_]*$').hasMatch(v);
}

/// A single UPI payment request — the thing that becomes a link or a QR.
class UpiRequest {
  final UpiPayee payee;

  /// Amount in PAISE. Integer throughout, matching migration 049 and Razorpay:
  /// money never touches a double on this path.
  final int amountPaise;

  /// Short description the payer sees, e.g. "Bus rent · Surat–Shirdi".
  final String? note;

  /// Merchant transaction reference (`tr`) — our booking id / expense id.
  /// This is what makes a bank-statement credit traceable back to a row
  /// without a payment gateway. Kept short; UPI apps and bank statements
  /// truncate long references.
  final String? reference;

  /// Merchant category code (`mc`). Only meaningful for a registered merchant
  /// VPA; omitted for a personal handle.
  final String? merchantCode;

  const UpiRequest({
    required this.payee,
    required this.amountPaise,
    this.note,
    this.reference,
    this.merchantCode,
  });

  bool get isValid => payee.isValid && amountPaise > 0;

  /// Rupees as UPI wants them: a plain decimal with exactly two places, no
  /// grouping separators and no currency symbol. `200000` paise → `"2000.00"`.
  String get amountString {
    final rupees = amountPaise ~/ 100;
    final paise = amountPaise % 100;
    return '$rupees.${paise.toString().padLeft(2, '0')}';
  }

  /// The `upi://pay?…` payload.
  ///
  /// Every value is percent-encoded through [Uri], which matters more here than
  /// it looks: notes and payee names in this app can carry Gujarati, and a raw
  /// `&`, space or non-ASCII byte in a hand-built query string silently
  /// truncates the payload in some UPI apps.
  ///
  /// Reference truncation is deliberate — see [reference].
  String build() {
    if (!isValid) {
      throw ArgumentError(
        'Invalid UPI request: payee=${payee.vpa} amountPaise=$amountPaise',
      );
    }
    final params = <String, String>{
      'pa': payee.vpa.trim(),
      'pn': payee.name.trim(),
      'am': amountString,
      'cu': 'INR',
      if (note != null && note!.trim().isNotEmpty)
        'tn': _clip(note!.trim(), 50),
      if (reference != null && reference!.trim().isNotEmpty)
        'tr': _clip(reference!.trim(), 35),
      if (merchantCode != null && merchantCode!.trim().isNotEmpty)
        'mc': merchantCode!.trim(),
    };
    return Uri(
      scheme: 'upi',
      host: 'pay',
      queryParameters: params,
    ).toString();
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);
}

/// Build a UPI payload for PAYING A VENDOR — bus owner rent, fuel, tolls, the
/// handler's float. Launch this; the organiser's own UPI app opens pre-filled
/// and they press send.
UpiRequest vendorPayment({
  required String vpa,
  required String vendorName,
  required int amountPaise,
  String? note,
  String? expenseId,
}) {
  return UpiRequest(
    payee: UpiPayee(vpa: vpa, name: vendorName),
    amountPaise: amountPaise,
    note: note,
    reference: expenseId,
  );
}

/// Build a UPI payload for COLLECTING from a customer — render this as a QR,
/// or send the link over WhatsApp. Costs nothing; [bookingRef] rides along as
/// `tr` so the credit can be matched back to the booking.
UpiRequest collectPayment({
  required String vpa,
  required String payeeName,
  required int amountPaise,
  String? note,
  String? bookingRef,
}) {
  return UpiRequest(
    payee: UpiPayee(vpa: vpa, name: payeeName),
    amountPaise: amountPaise,
    note: note,
    reference: bookingRef,
  );
}
