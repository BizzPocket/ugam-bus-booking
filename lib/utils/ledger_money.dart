/// Ledger money amounts are stored as integer minor units (paise for INR).
/// Convert only at the Dart display/controller boundary — never store floats
/// in the ledger path.
double minorToRupees(int minor) => minor / 100.0;

/// Inverse of [minorToRupees] for tests and rare write-side helpers.
int rupeesToMinor(double rupees) => (rupees * 100).round();
