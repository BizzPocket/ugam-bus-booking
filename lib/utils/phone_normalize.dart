String normalisePhone(String phone) {
  final cleaned = phone.replaceAll(RegExp(r'[^\d]'), '');
  return cleaned.length >= 10
      ? cleaned.substring(cleaned.length - 10)
      : cleaned;
}
