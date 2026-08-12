import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cached_remote_document.dart';
import 'wa_template_params.dart';

/// One approved Meta template, as Meta actually has it.
///
/// The field that matters most is [bodyStaticChars]: Meta's 1024-character
/// limit applies to the RENDERED body, so a free-text `{{1}}` may only be
/// `1024 - bodyStaticChars` long. Without this number the composer was
/// measuring the typed text alone and passing messages Meta then refused with
/// `132005`.
@immutable
class WaTemplateSpec {
  final String name;
  final String language;

  /// APPROVED / PENDING / REJECTED / PAUSED / DISABLED, upper-cased.
  final String status;
  final String category;

  /// NONE / TEXT / IMAGE / DOCUMENT / VIDEO / LOCATION.
  final String headerFormat;
  final int headerVarCount;

  /// The approved body with every `{{n}}` removed, in grapheme clusters.
  final int bodyStaticChars;
  final int bodyVarCount;
  final int footerChars;

  const WaTemplateSpec({
    required this.name,
    required this.language,
    this.status = '',
    this.category = '',
    this.headerFormat = 'NONE',
    this.headerVarCount = 0,
    this.bodyStaticChars = WaTemplateParams.conservativeStaticChars,
    this.bodyVarCount = 0,
    this.footerChars = 0,
  });

  factory WaTemplateSpec.fromMap(Map<String, dynamic> m) => WaTemplateSpec(
        name: (m['name'] ?? '').toString(),
        language: (m['language'] ?? '').toString(),
        status: (m['status'] ?? '').toString().toUpperCase(),
        category: (m['category'] ?? '').toString().toUpperCase(),
        headerFormat:
            (m['headerFormat'] ?? 'NONE').toString().toUpperCase(),
        headerVarCount: _int(m['headerVarCount']),
        bodyStaticChars: _int(
          m['bodyStaticChars'],
          fallback: WaTemplateParams.conservativeStaticChars,
        ),
        bodyVarCount: _int(m['bodyVarCount']),
        footerChars: _int(m['footerChars']),
      );

  static int _int(Object? v, {int fallback = 0}) => switch (v) {
        int i => i,
        num n => n.toInt(),
        String s => int.tryParse(s.trim()) ?? fallback,
        _ => fallback,
      };

  /// True when Meta will accept a send against this template right now.
  bool get isSendable => status == 'APPROVED';

  /// Characters left for the sender's own text.
  int get freeTextBudget => WaTemplateParams.freeTextBudget(bodyStaticChars);
}

/// What the app knows about its approved templates.
///
/// Fetched through the `wa-templates` Edge Function and cached with the same
/// discipline as every other remote document: never on the boot path, throttled,
/// last-known-good on failure, and it cannot throw.
///
/// **Unavailability is normal and must never block a send.** The catalog needs
/// a token with `whatsapp_business_management` scope — the business account id
/// itself is derived server-side from the phone number already configured for
/// sending, so no extra secret is required. Without the scope [specFor] returns
/// null and callers fall back to
/// [WaTemplateParams.conservativeStaticChars] — stricter than Meta, never
/// looser. A message the agent can send with a slightly tighter limit beats a
/// composer that refuses to open because a catalog fetch failed.
class WaTemplateCatalog {
  WaTemplateCatalog._();

  static final WaTemplateCatalog instance = WaTemplateCatalog._();

  /// The templates are edited rarely — in Business Manager, by a human, days
  /// apart. Six hours is frequent enough to notice a change well within a
  /// working day and rare enough to cost nothing.
  static const Duration _ttl = Duration(hours: 6);

  static const String functionName = 'wa-templates';

  /// Overridable for tests, which must never touch the network.
  @visibleForTesting
  static Future<String?> Function()? fetcherOverride;

  late final CachedRemoteDocument _doc = CachedRemoteDocument(
    name: 'wa_templates',
    url: '', // dormant: the injected fetcher does the work
    minFetchInterval: _ttl,
    fetcher: (_) async {
      final override = fetcherOverride;
      if (override != null) return override();
      final res = await Supabase.instance.client.functions
          .invoke(functionName, method: HttpMethod.get);
      final data = res.data;
      if (data == null) return null;
      return data is String ? data : jsonEncode(data);
    },
  );

  /// name → spec, for the language the app sends in. Empty until a fetch has
  /// succeeded at least once.
  final Map<String, WaTemplateSpec> _byName = {};
  bool _loaded = false;

  /// True once a real catalog has been read. False means every caller is on
  /// the conservative fallback — worth saying out loud in a diagnostics screen.
  bool get isAvailable => _loaded && _byName.isNotEmpty;

  /// Loads from cache, then refreshes in the background. Safe to call from a
  /// screen's initState: it awaits only the cache read.
  Future<void> warmUp() async {
    _ingest(await _doc.load());
    // Deliberately not awaited — a stale-but-present catalog is immediately
    // usable, and the refresh must never delay a composer opening.
    unawaited(_doc.refresh().then(_ingest));
  }

  /// Forces a fetch, ignoring the throttle. For a diagnostics "check now".
  Future<bool> refreshNow() async {
    _ingest(await _doc.refresh(force: true));
    return isAvailable;
  }

  void _ingest(Object? decoded) {
    if (decoded is! Map) return;
    if (decoded['available'] != true) {
      debugPrint('[WA] template catalog unavailable: ${decoded['reason']}');
      return;
    }
    final list = decoded['templates'];
    if (list is! List) return;

    _byName.clear();
    for (final row in list.whereType<Map>()) {
      final spec = WaTemplateSpec.fromMap(Map<String, dynamic>.from(row));
      if (spec.name.isEmpty) continue;
      // A template exists once per language. Keep the one we actually send in;
      // fall back to the first seen so a mis-set defaultLanguage still yields
      // something rather than nothing.
      final existing = _byName[spec.name];
      if (existing == null || spec.language == _sendLanguage) {
        _byName[spec.name] = spec;
      }
    }
    _loaded = true;
    debugPrint('[WA] template catalog: ${_byName.length} template(s)');
  }

  static String get _sendLanguage => 'gu';

  /// The approved spec for [name], or null when the catalog is unavailable.
  WaTemplateSpec? specFor(String name) => _byName[name];

  /// Characters available for free text in [name] — the real budget when the
  /// catalog is present, the conservative one when it is not.
  int freeTextBudgetFor(String name) =>
      specFor(name)?.freeTextBudget ??
      WaTemplateParams.freeTextBudget(
        WaTemplateParams.conservativeStaticChars,
      );

  /// Static-text cost of [name], for [WaTemplateParams.validateRendered].
  int staticCharsFor(String name) =>
      specFor(name)?.bodyStaticChars ??
      WaTemplateParams.conservativeStaticChars;

  /// Why [name] cannot be sent right now, or null when it can (or when the
  /// catalog cannot say, which must be treated as "go ahead").
  ///
  /// This is the preflight that turns "400 recipients each failed with 132015"
  /// into one sentence before anything is sent.
  WaTemplateBlock? blockFor(String name) {
    final spec = specFor(name);
    if (spec == null) return null; // unknown ≠ broken
    if (spec.isSendable) return null;
    return WaTemplateBlock(template: name, status: spec.status);
  }
}

/// A template that Meta will refuse for every recipient, known before sending.
@immutable
class WaTemplateBlock {
  final String template;
  final String status;

  const WaTemplateBlock({required this.template, required this.status});

  @override
  String toString() => 'WaTemplateBlock($template, $status)';

  @override
  bool operator ==(Object other) =>
      other is WaTemplateBlock &&
      other.template == template &&
      other.status == status;

  @override
  int get hashCode => Object.hash(template, status);
}
