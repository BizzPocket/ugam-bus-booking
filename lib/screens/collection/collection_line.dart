part of '../collection_screen.dart';

class _SeatCollectionLine {
  final Passenger passenger;
  final String seatId;

  /// LIVE fare for this seat on THIS bus, from `Bus.amountDueForSeat`.
  final double due;

  final Collection? col;

  /// Unverified UPI assertion — show as warm hint; never treat as paid.
  final PaymentClaim? pendingClaim;

  const _SeatCollectionLine({
    required this.passenger,
    required this.seatId,
    required this.due,
    required this.col,
    this.pendingClaim,
  });

  /// Cash actually held for this seat (`received − refunded`).
  double get net => netCollectedOf(col);

  /// Paid-vs-owed against the LIVE fare rather than the stored `amount_due`
  /// snapshot — see [liveBalanceOf], which the handler's seat dots share, so
  /// the two surfaces can never disagree about who still owes.
  double get liveBalance => liveBalanceOf(due, col);

  bool get isReturnDue => liveBalance > Collection.kMoneyEpsilon;
  bool get isShortfall => liveBalance < -Collection.kMoneyEpsilon;

  /// True when this seat has a collection row carrying real cash (received or
  /// handed back) — the rows an "undo payment" can reverse.
  bool get hasRecordedMoney =>
      col != null &&
      ((col!.amountReceived).abs() > Collection.kMoneyEpsilon ||
          (col!.amountRefunded).abs() > Collection.kMoneyEpsilon);

  double get changeToReturn => isReturnDue ? liveBalance : 0;
  double get stillToCollect => isShortfall ? -liveBalance : 0;
}
