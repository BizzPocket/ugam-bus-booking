/// Meta's media rules for WhatsApp template HEADERS, checked before upload.
///
/// The app sends exactly one kind of media: the per-passenger seat chart, as a
/// PNG image header on `seat_allotment`. Meta caps an image header at **5 MB**
/// — an order of magnitude tighter than the 100 MB it allows a document — and
/// a chart that exceeds it comes back as a bare `131053 Unable to upload the
/// media used in the message`, per recipient, with nothing saying how big the
/// file actually was or what the limit is.
///
/// Checking locally turns that into "the seat chart came to 6.2 MB; the limit
/// is 5 MB", which names the problem and points at the fix.
///
/// The document limits are recorded for correctness — the Edge Functions can
/// build a document header and a future caller will need the real numbers —
/// but nothing in the app sends a document today.
///
/// Source: Meta Cloud API "Supported media types".
/// Pure (no Flutter, no network) so the rules are unit-testable.
library;

/// Why a piece of media cannot be sent.
enum WaMediaIssue {
  /// A MIME type Meta does not accept for this header format.
  unsupportedType,

  /// Within the accepted types, but over that type's size cap.
  tooLarge,

  /// Zero bytes — nothing was rendered.
  empty,
}

/// A refused piece of media, with the numbers needed to explain it.
class WaMediaViolation {
  final WaMediaIssue issue;
  final String contentType;

  /// Actual size in bytes.
  final int bytes;

  /// The cap that applies, in bytes. Zero when the type itself is refused.
  final int limitBytes;

  const WaMediaViolation({
    required this.issue,
    required this.contentType,
    required this.bytes,
    this.limitBytes = 0,
  });

  /// Size as a human would say it, e.g. "6.2 MB".
  String get sizeLabel => _mb(bytes);

  /// The applicable cap as a human would say it, e.g. "5 MB".
  String get limitLabel => _mb(limitBytes);

  static String _mb(int b) {
    final mb = b / (1024 * 1024);
    return mb >= 10 || mb == mb.roundToDouble()
        ? '${mb.round()} MB'
        : '${mb.toStringAsFixed(1)} MB';
  }

  @override
  String toString() =>
      'WaMediaViolation(${issue.name}, $contentType, $bytes/$limitBytes)';

  @override
  bool operator ==(Object other) =>
      other is WaMediaViolation &&
      other.issue == issue &&
      other.contentType == contentType &&
      other.bytes == bytes &&
      other.limitBytes == limitBytes;

  @override
  int get hashCode => Object.hash(issue, contentType, bytes, limitBytes);
}

/// Meta's supported media types and size caps, as code.
class WaMedia {
  WaMedia._();

  static const int _mb = 1024 * 1024;

  /// Image header: JPEG and PNG only, 5 MB. This is the one the app uses.
  static const int maxImageBytes = 5 * _mb;
  static const Set<String> imageTypes = {'image/jpeg', 'image/png'};

  /// Document header: 100 MB. Recorded for correctness; unused today.
  static const int maxDocumentBytes = 100 * _mb;
  static const Set<String> documentTypes = {
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'text/plain',
  };

  /// Video header: 16 MB. Recorded for correctness; unused today.
  static const int maxVideoBytes = 16 * _mb;
  static const Set<String> videoTypes = {'video/mp4', 'video/3gpp'};

  /// Why [bytes] of [contentType] cannot be an IMAGE header, or null when it
  /// can. [contentType] is matched case-insensitively and ignores any
  /// `; charset=` suffix, because that is how servers really label things.
  static WaMediaViolation? validateImage({
    required int bytes,
    required String contentType,
  }) =>
      _validate(
        bytes: bytes,
        contentType: contentType,
        allowed: imageTypes,
        limit: maxImageBytes,
      );

  /// Why [bytes] of [contentType] cannot be a DOCUMENT header, or null when it
  /// can. Unused by the app today; present so the rule is not re-derived from
  /// memory the day someone adds an attachment.
  static WaMediaViolation? validateDocument({
    required int bytes,
    required String contentType,
  }) =>
      _validate(
        bytes: bytes,
        contentType: contentType,
        allowed: documentTypes,
        limit: maxDocumentBytes,
      );

  static WaMediaViolation? _validate({
    required int bytes,
    required String contentType,
    required Set<String> allowed,
    required int limit,
  }) {
    final type = contentType.split(';').first.trim().toLowerCase();

    if (bytes <= 0) {
      return WaMediaViolation(
        issue: WaMediaIssue.empty,
        contentType: type,
        bytes: bytes,
      );
    }
    if (!allowed.contains(type)) {
      return WaMediaViolation(
        issue: WaMediaIssue.unsupportedType,
        contentType: type,
        bytes: bytes,
      );
    }
    if (bytes > limit) {
      return WaMediaViolation(
        issue: WaMediaIssue.tooLarge,
        contentType: type,
        bytes: bytes,
        limitBytes: limit,
      );
    }
    return null;
  }
}
