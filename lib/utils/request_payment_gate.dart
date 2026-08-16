import '../models/request_line.dart';
import '../models/tour.dart';
import 'request_pricing.dart';

/// What should happen when this request is submitted.
enum RequestPaymentOutcome {
  /// Money is owed and can be taken — show the UPI sheet.
  payNow,

  /// Nothing is owed. Every line is one-leg or unbanded, so the request goes
  /// straight onto the waiting list, free, exactly as it always has.
  waitlistFree,

  /// Money IS owed but the tour has nowhere to receive it — the organiser
  /// never set a collection VPA. The request still goes through and the fare
  /// is collected on the bus.
  cannotCollect,
}

/// The payment decision for one request.
class RequestPaymentPlan {
  final RequestPaymentOutcome outcome;

  /// Paise to collect NOW. Non-zero only for [RequestPaymentOutcome.payNow].
  final int amountPaise;

  const RequestPaymentPlan({
    required this.outcome,
    required this.amountPaise,
  });

  bool get needsPayment => outcome == RequestPaymentOutcome.payNow;
}

/// Decide whether this request must be paid for before it is sent.
///
/// *** WHY A MISSING VPA DOES NOT BLOCK THE BOOKING ***
/// It is the ORGANISER who failed to configure a collection handle, not the
/// customer. Refusing the request there would lose a sale and leave the rider
/// staring at an error they cannot act on. So the request is taken and the
/// money is collected on the bus — which is precisely today's behaviour, and
/// therefore a safe floor for every case this flow does not cover.
///
/// Pure — no Flutter, no I/O.
RequestPaymentPlan planRequestPayment({
  required Tour tour,
  required List<RequestLine> lines,
}) {
  final charge = requestChargePaise(lines);
  if (charge <= 0) {
    return const RequestPaymentPlan(
      outcome: RequestPaymentOutcome.waitlistFree,
      amountPaise: 0,
    );
  }
  if (!tour.canCollectOnline) {
    return const RequestPaymentPlan(
      outcome: RequestPaymentOutcome.cannotCollect,
      amountPaise: 0,
    );
  }
  return RequestPaymentPlan(
    outcome: RequestPaymentOutcome.payNow,
    amountPaise: charge,
  );
}
