import 'package:flutter/foundation.dart';

/// What a remote content block is allowed to do when tapped.
///
/// A CLOSED set, deliberately. A remotely-supplied document must not be able
/// to navigate anywhere in the app or invoke anything arbitrary — that is the
/// difference between server-driven content and a remote code execution
/// primitive. Anything unrecognised parses to [none] and renders as inert.
enum BlockAction {
  /// No tap target at all.
  none,

  /// Open an external https URL in the browser. Never an app scheme, never a
  /// deep link back into the app.
  url,

  /// Navigate to one of a handful of whitelisted in-app destinations.
  /// See `ContentBlockView` for the whitelist — the NAME is remote, the
  /// destination it resolves to is compiled in.
  route,
}

/// One server-driven content block.
///
/// SCOPE, AND WHY IT IS NARROW
/// This exists for the customer surface's content areas — notices, promos, a
/// link to something. It is explicitly NOT a UI language: the seat chart,
/// every money surface and the whole handler flow stay as native code, because
/// they carry logic and correctness that a JSON document cannot express and no
/// test can cover.
///
/// The server composes blocks from a registry of types that ALREADY EXIST in
/// the binary. It cannot introduce a widget, a layout or an interaction. That
/// constraint is what keeps this testable, offline-safe, and clearly inside
/// App Store guideline 2.5.2 — nothing here changes the app's primary purpose.
@immutable
class ContentBlock {
  /// Registry key. Unknown values are dropped at parse time so an old build
  /// silently ignores a block type it was never taught, rather than failing.
  final String type;

  final String? title;
  final String? body;

  /// Remote image, https only. Null renders text-only.
  final String? imageUrl;

  final BlockAction action;

  /// For [BlockAction.url] the https target; for [BlockAction.route] the
  /// whitelisted route key.
  final String? actionTarget;

  final String? actionLabel;

  /// Visual weight. Unknown tones fall back to neutral.
  final String tone;

  const ContentBlock({
    required this.type,
    this.title,
    this.body,
    this.imageUrl,
    this.action = BlockAction.none,
    this.actionTarget,
    this.actionLabel,
    this.tone = 'neutral',
  });

  /// Every block type the binary can render. A document naming anything else
  /// is not an error — it is a newer document than this build, and the block
  /// is skipped.
  static const Set<String> knownTypes = {'notice', 'banner', 'link'};

  static const Set<String> knownTones = {'neutral', 'info', 'warn'};

  /// Tolerant by design: a malformed block is dropped, never thrown on. One
  /// bad entry must not cost the user the rest of the document.
  static ContentBlock? tryParse(Object? raw) {
    if (raw is! Map) return null;

    final type = _str(raw['type']);
    if (type == null || !knownTypes.contains(type)) return null;

    final action = _parseAction(_str(raw['action']));
    var target = _str(raw['action_target']);

    // A url action must carry an https target. http and app schemes are
    // refused outright — a remote document must not be able to point the user
    // at an unencrypted host or hand a payload to another app.
    if (action == BlockAction.url) {
      final uri = target == null ? null : Uri.tryParse(target);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
        return null;
      }
    }
    if (action == BlockAction.route && (target == null || target.isEmpty)) {
      return null;
    }
    if (action == BlockAction.none) target = null;

    // Same rule for imagery.
    final image = _str(raw['image_url']);
    final imageUri = image == null ? null : Uri.tryParse(image);
    final safeImage =
        (imageUri != null && imageUri.scheme == 'https' && imageUri.host.isNotEmpty)
            ? image
            : null;

    final block = ContentBlock(
      type: type,
      title: _str(raw['title']),
      body: _str(raw['body']),
      imageUrl: safeImage,
      action: action,
      actionTarget: target,
      actionLabel: _str(raw['action_label']),
      tone: knownTones.contains(_str(raw['tone'])) ? _str(raw['tone'])! : 'neutral',
    );

    // A block with nothing to show is noise, not content.
    if (block.title == null && block.body == null && block.imageUrl == null) {
      return null;
    }
    return block;
  }

  /// Parses a whole document. Never throws; returns an empty list on anything
  /// it cannot make sense of.
  static List<ContentBlock> parseDocument(Object? decoded) {
    if (decoded is! Map) return const [];
    final blocks = decoded['blocks'];
    if (blocks is! List) return const [];
    return [
      for (final b in blocks) ?tryParse(b),
    ];
  }

  static BlockAction _parseAction(String? s) {
    switch (s) {
      case 'url':
        return BlockAction.url;
      case 'route':
        return BlockAction.route;
      default:
        return BlockAction.none;
    }
  }

  /// Trims, and treats blank as absent so a document full of empty strings
  /// does not render a wall of empty rows.
  static String? _str(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  @override
  String toString() => 'ContentBlock($type, title=$title, action=$action)';
}
