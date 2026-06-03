String normalisePhone(String phone) {
  final cleaned = phone.replaceAll(RegExp(r'[^\d]'), '');
  return cleaned.length >= 10
      ? cleaned.substring(cleaned.length - 10)
      : cleaned;
}

/// True when [phone] (any format) looks like a real Indian mobile number:
/// exactly 10 significant digits, starting 6–9, not all-identical, and not a
/// trivial ascending/descending run (e.g. 9999999999, 9876543210).
///
/// This is deterrence against junk/typo entries — NOT phone ownership
/// verification (which would need an SMS/WhatsApp provider).
bool isPlausibleIndianMobile(String phone) {
  final d = normalisePhone(phone);
  if (d.length != 10) return false;
  final first = d.codeUnitAt(0) - 0x30; // '0' == 0x30
  if (first < 6 || first > 9) return false;
  if (RegExp(r'^(\d)\1{9}$').hasMatch(d)) return false; // all same digit
  const ascending = '0123456789';
  const descending = '9876543210';
  if (ascending.contains(d) || descending.contains(d)) return false;
  return true;
}
