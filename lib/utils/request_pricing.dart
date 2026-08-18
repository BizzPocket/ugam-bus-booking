import '../models/request_band.dart';
import '../models/request_line.dart';

/// What a booking request costs UP FRONT, in integer paise.
///
/// *** THE RULE THIS MODULE ENCODES ***
/// Only a FULL-TRIP line is charged. A Go-only or Return-only line is free and
/// joins the waiting list instead — the organiser admits those by hand and
/// collects on the bus, exactly as today.
///
/// That is not an arbitrary split. A full-trip rider consumes BOTH legs of a
/// berth and, once paid, cannot be cancelled; a one-leg rider consumes one leg
/// and stays cancellable. Charging only the irreversible half is what keeps the
/// waiting list serviceable.
///
/// An UNBANDED full-trip line is also free — two cases reach it and both must
/// behave the same way:
///   * a legacy request written before bands existed; and
///   * a sold-out request, where no band could be offered because capacity had
///     run out, so the rider joins the list unpaid rather than being refused.
/// In both, nothing was ever quoted, so nothing may be collected.
///
/// Pure — no Flutter, no I/O — so the form, the checkout total and the server
/// reconciliation can all share one definition of the price.

/// Paise owed for ONE line. Zero whenever the line is not chargeable.
///
/// A band price is per BERTH regardless of seat type (mirrors
/// `Bus.berthPriceFor`), so a whole Double Sofa unit costs two of them.
int requestLineChargePaise(RequestLine line) {
  final band = line.band;
  if (band == null) return 0;
  if (line.leg.isOneWay) return 0;
  if (line.qty <= 0) return 0;
  return band.pricePaise * line.qty * line.seatType.berthsPerUnit;
}

/// Paise owed for a whole request — the number on the Pay button.
int requestChargePaise(Iterable<RequestLine> lines) =>
    lines.fold<int>(0, (sum, l) => sum + requestLineChargePaise(l));

/// True when this line joins the WAITING LIST instead of being paid for.
///
/// The exact complement of [requestLineChargePaise] being non-zero for a
/// non-empty line, stated positively so callers read as intent rather than as
/// "price == 0".
bool isWaitlistLine(RequestLine line) =>
    line.band == null || line.leg.isOneWay;

/// True when any part of this request has to be paid before it is submitted.
bool requestNeedsPayment(Iterable<RequestLine> lines) =>
    requestChargePaise(lines) > 0;

/// True when EVERY line joins the waiting list — the CTA says "Join waiting
/// list" rather than "Pay".
bool requestIsAllWaitlist(Iterable<RequestLine> lines) =>
    lines.isNotEmpty && lines.every(isWaitlistLine);

/// What the ORGANISER quotes a waitlisted rider, once they have picked which
/// band to seat them in.
///
/// *** WHY THIS IS NOT [requestLineChargePaise] ***
/// That function answers "what does the CUSTOMER owe at submit time", and for a
/// one-leg line the answer is deliberately nothing: they were never shown a
/// band, so they cannot be charged for one. This answers a later, different
/// question — the organiser has now chosen a band, paired the rider with
/// someone going the other way, and is sending them a QR.
///
/// A one-leg rider uses ONE of the berth's two leg-slots, so they pay half the
/// band price; that is `Bus.tripFactor`, the same 0.5 the fare engine and
/// `bus_berth_price_paise` already apply, so the quote agrees with what the
/// ledger will later post. A round-trip line among their lines is charged in
/// full — half price buys one leg, not a discount.
///
/// Any band already sitting on a line is IGNORED. A waitlisted rider never
/// chose one; the organiser's pick is the price.
///
/// Rounds half away from zero, matching Dart's `round()` and Postgres's
/// `round(numeric)`, so an odd band price lands on the same paise on both
/// sides.
int waitlistQuotePaise({
  required RequestBand band,
  required Iterable<RequestLine> lines,
}) {
  var total = 0;
  for (final l in lines) {
    if (l.qty <= 0) continue;
    final berths = l.qty * l.seatType.berthsPerUnit;
    final full = band.pricePaise * berths;
    total += l.leg.isOneWay ? (full / 2).round() : full;
  }
  return total;
}
