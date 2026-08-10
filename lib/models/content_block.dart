import 'package:flutter/foundation.dart';

/// Every place in the app a server-driven block may appear.
///
/// A CLOSED set. A document naming an unknown slot is not an error — it is a
/// newer document than this build — and its blocks are simply not rendered.
/// That is what lets you publish for the next release without breaking the
/// current one.
///
/// Naming is `surface.screen.position` so a document is readable without
/// consulting this file.
class ContentSlots {
  const ContentSlots._();

  // ── Customer ───────────────────────────────────────────────
  static const customerTourListTop = 'customer.tour_list.top';
  static const customerTourListEmpty = 'customer.tour_list.empty';
  static const customerTourDetailTop = 'customer.tour_detail.top';
  static const customerMyRequestsTop = 'customer.my_requests.top';
  static const customerMyRequestsEmpty = 'customer.my_requests.empty';
  static const customerMoreTop = 'customer.more.top';

  // ── Handler ────────────────────────────────────────────────
  // Content only. The chart geometry, the collect sheet and the handover form
  // stay native: handlers work offline on moving buses, and a surface that
  // must be fetched cannot render at all without signal.
  static const handlerChartTop = 'handler.chart.top';

  // ── Admin / operator ───────────────────────────────────────
  static const adminHomeTop = 'admin.home.top';
  static const adminTourDetailTop = 'admin.tour_detail.top';
  static const adminMoneyTop = 'admin.money.top';

  static const Set<String> all = {
    customerTourListTop,
    customerTourListEmpty,
    customerTourDetailTop,
    customerMyRequestsTop,
    customerMyRequestsEmpty,
    customerMoreTop,
    handlerChartTop,
    adminHomeTop,
    adminTourDetailTop,
    adminMoneyTop,
  };
}

/// What a block may do when tapped.
///
/// A CLOSED set. A remotely-supplied document must not be able to navigate
/// anywhere in the app or invoke anything arbitrary — that is the difference
/// between server-driven content and a remote execution primitive. Anything
/// unrecognised parses to [none] and renders inert.
enum BlockAction { none, url, route }

/// When a block is eligible to render.
///
/// Everything is optional and an omitted field means "no restriction", so the
/// common case — show this to everyone — stays a document with no `when` at
/// all. Every condition is evaluated on-device against values the app already
/// knows, so targeting costs no extra round trip and works offline.
@immutable
class BlockTargeting {
  /// `android`, `ios`. Empty = every platform.
  final Set<String> platforms;

  /// Inclusive build-number window. Lets a notice explain a bug to exactly the
  /// builds that have it, and disappear for everyone who has updated.
  final int? minBuild;
  final int? maxBuild;

  /// Language codes. Empty = every locale.
  final Set<String> locales;

  /// `customer`, `handler`, `admin`. Empty = every role.
  final Set<String> roles;

  /// UTC window. This is what makes a promo schedulable — publish once on
  /// Monday, it appears Friday and stops on Sunday with no further action.
  final DateTime? from;
  final DateTime? to;

  const BlockTargeting({
    this.platforms = const {},
    this.minBuild,
    this.maxBuild,
    this.locales = const {},
    this.roles = const {},
    this.from,
    this.to,
  });

  static const BlockTargeting always = BlockTargeting();

  bool get isUnrestricted =>
      platforms.isEmpty &&
      minBuild == null &&
      maxBuild == null &&
      locales.isEmpty &&
      roles.isEmpty &&
      from == null &&
      to == null;

  /// [build] is null when PackageInfo failed — AppInfo leaves an empty string
  /// in that case. An unreadable build must not silently hide content, so a
  /// null build passes any build window rather than failing it.
  bool matches({
    required String platform,
    required int? build,
    required String locale,
    required String role,
    required DateTime nowUtc,
  }) {
    if (platforms.isNotEmpty && !platforms.contains(platform)) return false;
    if (locales.isNotEmpty && !locales.contains(locale)) return false;
    if (roles.isNotEmpty && !roles.contains(role)) return false;

    if (build != null) {
      if (minBuild != null && build < minBuild!) return false;
      if (maxBuild != null && build > maxBuild!) return false;
    }

    if (from != null && nowUtc.isBefore(from!)) return false;
    if (to != null && !nowUtc.isBefore(to!)) return false;

    return true;
  }

  static BlockTargeting parse(Object? raw) {
    if (raw is! Map) return always;
    return BlockTargeting(
      platforms: _strSet(raw['platforms']),
      minBuild: _int(raw['min_build']),
      maxBuild: _int(raw['max_build']),
      locales: _strSet(raw['locales']),
      roles: _strSet(raw['roles']),
      from: _date(raw['from']),
      to: _date(raw['to']),
    );
  }

  static Set<String> _strSet(Object? v) {
    if (v is! List) return const {};
    return {
      for (final e in v)
        if (e is String && e.trim().isNotEmpty) e.trim().toLowerCase(),
    };
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  static DateTime? _date(Object? v) {
    if (v is! String) return null;
    return DateTime.tryParse(v.trim())?.toUtc();
  }
}

/// One server-driven content block.
///
/// SCOPE. Blocks are composed from a registry of types that ALREADY EXIST in
/// the binary, dropped into named slots that already exist on real screens.
/// The server chooses WHICH compiled-in component appears WHERE, and what text
/// goes in it. It cannot introduce a widget, describe a layout, or define an
/// interaction.
///
/// That boundary is deliberate and it is what makes this safe to run on the
/// handler and admin surfaces too: the content is remote, the machinery is
/// native, so an offline handler still gets a working seat chart and a cash
/// form, and no test coverage is lost on anything that touches money.
@immutable
class ContentBlock {
  /// Stable identity, for dedup and for talking about a block in an incident.
  /// Generated from the content when a document omits it.
  final String id;

  /// Which slot this belongs in. Unknown slots are dropped at parse time.
  final String slot;

  /// Registry key. Unknown types are dropped at parse time.
  final String type;

  /// Ascending sort within a slot. Ties fall back to document order.
  final int order;

  final String? title;
  final String? body;

  /// For [stat]: the large figure. Ignored by other types.
  final String? value;

  /// https only.
  final String? imageUrl;

  final BlockAction action;
  final String? actionTarget;
  final String? actionLabel;

  final String tone;
  final BlockTargeting when;

  const ContentBlock({
    required this.id,
    required this.slot,
    required this.type,
    this.order = 0,
    this.title,
    this.body,
    this.value,
    this.imageUrl,
    this.action = BlockAction.none,
    this.actionTarget,
    this.actionLabel,
    this.tone = 'neutral',
    this.when = BlockTargeting.always,
  });

  /// Every block type this binary can render, and the widget behind each:
  ///   notice   — bordered card              (inline)
  ///   banner   — 16:9 image + text          (inline)
  ///   link     — tappable row with chevron  (inline)
  ///   cta      — primary button             (UgamCTA)
  ///   faq      — expander                   (UgamExpander)
  ///   stat     — large figure + label       (UgamHeroStat)
  ///   divider  — a rule                     (inline)
  static const Set<String> knownTypes = {
    'notice',
    'banner',
    'link',
    'cta',
    'faq',
    'stat',
    'divider',
  };

  static const Set<String> knownTones = {'neutral', 'info', 'warn', 'danger'};

  /// The slot a document gets when it does not name one.
  ///
  /// Keeps documents written before slots existed working unchanged, which
  /// matters because a published document outlives the build that read it.
  static const String defaultSlot = ContentSlots.customerTourListTop;

  /// Tolerant by design: a malformed block is dropped, never thrown on. One
  /// bad entry must not cost the user the rest of the document.
  static ContentBlock? tryParse(Object? raw, {int index = 0}) {
    if (raw is! Map) return null;

    final type = _str(raw['type']);
    if (type == null || !knownTypes.contains(type)) return null;

    final slot = _str(raw['slot']) ?? defaultSlot;
    if (!ContentSlots.all.contains(slot)) return null;

    final action = _parseAction(_str(raw['action']));
    var target = _str(raw['action_target']);

    // A url action must carry an https target. http and app schemes are
    // refused outright — a remote document must not point a user at an
    // unencrypted host or hand a payload to another app.
    if (action == BlockAction.url) {
      final uri = target == null ? null : Uri.tryParse(target);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    }
    if (action == BlockAction.route && (target == null || target.isEmpty)) {
      return null;
    }
    if (action == BlockAction.none) target = null;

    final image = _str(raw['image_url']);
    final imageUri = image == null ? null : Uri.tryParse(image);
    final safeImage = (imageUri != null &&
            imageUri.scheme == 'https' &&
            imageUri.host.isNotEmpty)
        ? image
        : null;

    final title = _str(raw['title']);
    final body = _str(raw['body']);
    final value = _str(raw['value']);

    // A block with nothing to show is noise. A divider is the one type that
    // legitimately carries no content.
    if (type != 'divider' &&
        title == null &&
        body == null &&
        value == null &&
        safeImage == null) {
      return null;
    }
    // A stat with no figure is just a label.
    if (type == 'stat' && value == null) return null;
    // A cta with no label is an unlabelled button.
    if (type == 'cta' && title == null) return null;

    final toneRaw = _str(raw['tone']);
    return ContentBlock(
      id: _str(raw['id']) ??
          'auto-$slot-$type-$index-${(title ?? body ?? value ?? '').hashCode}',
      slot: slot,
      type: type,
      order: BlockTargeting._int(raw['order']) ?? 0,
      title: title,
      body: body,
      value: value,
      imageUrl: safeImage,
      action: action,
      actionTarget: target,
      actionLabel: _str(raw['action_label']),
      tone: knownTones.contains(toneRaw) ? toneRaw! : 'neutral',
      when: BlockTargeting.parse(raw['when']),
    );
  }

  /// Parses a whole document. Never throws; empty on anything unusable.
  ///
  /// Sorted by [order] then document position, so a publisher controls
  /// sequence without having to reorder the file.
  static List<ContentBlock> parseDocument(Object? decoded) {
    if (decoded is! Map) return const [];
    final blocks = decoded['blocks'];
    if (blocks is! List) return const [];

    final out = <ContentBlock>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = tryParse(blocks[i], index: i);
      if (b != null) out.add(b);
    }
    // Stable: equal orders keep document sequence.
    final indexed = [for (var i = 0; i < out.length; i++) (i, out[i])];
    indexed.sort((a, b) {
      final byOrder = a.$2.order.compareTo(b.$2.order);
      return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  static BlockAction _parseAction(String? s) => switch (s) {
        'url' => BlockAction.url,
        'route' => BlockAction.route,
        _ => BlockAction.none,
      };

  /// Trims, and treats blank as absent so a document full of empty strings
  /// does not render a wall of empty rows.
  static String? _str(Object? v) {
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  @override
  String toString() => 'ContentBlock($type @ $slot, id=$id, order=$order)';
}
