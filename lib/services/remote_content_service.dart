import 'dart:async';

import 'package:get/get.dart';

import '../config/remote_content_config.dart';
import '../models/content_block.dart';
import 'cached_remote_document.dart';

/// Server-driven content for the customer surface's content slots.
///
/// Narrow on purpose. This drives notices, promos and links — nothing that
/// carries logic. The seat chart, every money surface and the whole handler
/// flow remain native code, because they encode correctness a JSON document
/// cannot express and no test could cover.
///
/// Blocks are composed from a registry that already exists in the binary
/// ([ContentBlock.knownTypes]); the server cannot introduce a widget, a layout
/// or an interaction. That is what keeps this offline-safe, testable, and
/// plainly within App Store guideline 2.5.2.
///
/// DORMANT BY DEFAULT. With no URL configured this yields an empty list
/// forever, no network call is made, and the screens render exactly as they do
/// today. Switching it on is a build-time define, not a code change.
class RemoteContentService extends GetxService {
  RemoteContentService({CachedRemoteDocument? document})
      : _doc = document ??
            CachedRemoteDocument(
              name: 'content',
              url: RemoteContentConfig.url,
              maxBytes: RemoteContentConfig.maxBytes,
              timeout: RemoteContentConfig.fetchTimeout,
            );

  final CachedRemoteDocument _doc;

  /// Blocks for the customer content slot. Empty is the normal, safe state.
  final RxList<ContentBlock> blocks = <ContentBlock>[].obs;

  /// Reads the cache, then refreshes in the background.
  ///
  /// Awaiting this is safe — the cache read does no network I/O — but the
  /// refresh it starts is deliberately not awaited. Nothing on a UI path may
  /// wait for content.
  Future<void> warm() async {
    final cached = await _doc.load();
    if (cached != null) blocks.value = ContentBlock.parseDocument(cached);

    if (!_doc.enabled) return;
    unawaited(
      _doc.refresh().then((fresh) {
        if (fresh != null) blocks.value = ContentBlock.parseDocument(fresh);
      }),
    );
  }

  /// Force a check now, ignoring the interval — for pull-to-refresh.
  Future<void> refreshNow() async {
    final fresh = await _doc.refresh(force: true);
    if (fresh != null) blocks.value = ContentBlock.parseDocument(fresh);
  }

  /// Drop everything and render nothing. The escape hatch if a bad document
  /// ever ships; also reachable remotely by publishing `{"blocks": []}`.
  Future<void> clear() async {
    await _doc.clear();
    blocks.clear();
  }
}
