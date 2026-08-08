import '../utils/ledger_money.dart';

enum PaymentClaimStatus { pending, confirmed, rejected }

/// Customer UPI advance assertion (`payment_claims`). Not proof until
/// [PaymentClaimStatus.confirmed] via admin review.
class PaymentClaim {
  final String id;
  final String tourId;
  final String? bookingRequestId;
  final String? passengerId;
  final double amountRupees;
  final String? upiRef;
  final String? payerName;
  final String? payerPhone;
  final PaymentClaimStatus status;
  final DateTime claimedAt;
  final DateTime? reviewedAt;
  final String? reviewNote;
  final String? financeEntryId;
  final String? seatHoldId;

  const PaymentClaim({
    required this.id,
    required this.tourId,
    this.bookingRequestId,
    this.passengerId,
    required this.amountRupees,
    this.upiRef,
    this.payerName,
    this.payerPhone,
    required this.status,
    required this.claimedAt,
    this.reviewedAt,
    this.reviewNote,
    this.financeEntryId,
    this.seatHoldId,
  });

  bool get isPending => status == PaymentClaimStatus.pending;
  bool get isConfirmed => status == PaymentClaimStatus.confirmed;

  factory PaymentClaim.fromMap(Map<String, dynamic> map) {
    final paise = map['amount_paise'];
    final minor = paise is int
        ? paise
        : paise is num
            ? paise.round()
            : int.tryParse('$paise') ?? 0;
    return PaymentClaim(
      id: map['id'] as String? ?? '',
      tourId: map['tour_id'] as String? ?? '',
      bookingRequestId: map['booking_request_id'] as String?,
      passengerId: map['passenger_id'] as String?,
      amountRupees: minorToRupees(minor),
      upiRef: map['upi_ref'] as String?,
      payerName: map['payer_name'] as String?,
      payerPhone: map['payer_phone'] as String?,
      status: _statusOf(map['status'] as String?),
      claimedAt: DateTime.tryParse('${map['claimed_at']}') ?? DateTime.now(),
      reviewedAt: map['reviewed_at'] == null
          ? null
          : DateTime.tryParse('${map['reviewed_at']}'),
      reviewNote: map['review_note'] as String?,
      financeEntryId: map['finance_entry_id'] as String?,
      seatHoldId: map['seat_hold_id'] as String?,
    );
  }

  static PaymentClaimStatus _statusOf(String? raw) => switch (raw) {
        'confirmed' => PaymentClaimStatus.confirmed,
        'rejected' => PaymentClaimStatus.rejected,
        _ => PaymentClaimStatus.pending,
      };
}
