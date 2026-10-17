part of '../tour_controller.dart';

/// The on-disk last-known-good graph and the "showing saved data" signal.
mixin _TourDiskCache on _TourCapacity {
  /// Disk cache of the last graph that was confirmed against the server.
  /// Injectable so tests can point it at a temp directory.
  TourCacheStore diskCache = TourCacheStore.instance;

  /// **The data on screen did not come from a successful fetch.**
  ///
  /// The single honest signal behind the "showing saved data" indicator. A
  /// cache that can be mistaken for live data is the exact defect that got the
  /// last offline layer deleted ("masked real fetch failures as empty
  /// results"), so this is set by BOTH paths that can produce a stale render —
  /// a cold start hydrated from disk, and a fetch that failed while content was
  /// already on screen — and cleared by exactly one thing: a load that actually
  /// reached the server.
  final isShowingCachedData = false.obs;

  /// When the graph on screen was last confirmed against the server. Drives the
  /// `from <relative time>` half of the indicator; null when the content came
  /// from somewhere with no such timestamp (a test seed, an optimistic write),
  /// in which case the indicator says "saved data" with no age rather than
  /// inventing one.
  final Rxn<DateTime> dataAsOf = Rxn<DateTime>();

  /// Coalesces cache writes. A single load fires phase-2 and then N layout
  /// merges; without this each one would re-encode and re-write the WHOLE
  /// graph. Deliberately main-isolate: encoding ~100 kB of JSON costs a few ms,
  /// where spawning an isolate to do it costs tens of ms on the low-end devices
  /// this is meant to help.
  Timer? _cacheSaveDebounce;

  /// Scope key for the on-disk graph: the ADMIN's id, or null when there is no
  /// admin session.
  ///
  /// Null is a hard "do not cache". An anonymous / customer viewer is never
  /// persisted at all, which is half of why a cached tour cannot survive a
  /// logout: the moment the session goes, so does the only key that can address
  /// the file — and [AuthController] deletes the file itself as well.
  ///
  /// Waits only on the PREFS half of session restore, so an offline start finds
  /// its scope in milliseconds instead of after the admin lookup's timeout.
  ///
  /// [forWrite] tightens which admin id may name the file, and the two answers
  /// deliberately differ. A READ accepts the id persisted in prefs, because an
  /// offline cold start has no live `currentAdmin` (that comes from a network
  /// lookup) and painting the saved graph is the whole point. A WRITE demands
  /// the LIVE id — the same value [_tourFilters] filtered the query by — so a
  /// load that ran unfiltered because the admin lookup timed out cannot save
  /// the resulting list of public tours over this admin's roster.
  Future<String?> _diskCacheScope({bool forWrite = false}) async {
    if (!Get.isRegistered<AuthController>()) return null;
    final auth = Get.find<AuthController>();
    try {
      await auth.whenPrefsRestored.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      // Fall through: `cacheScopeAdminId` returns null unless prefs actually
      // restored an admin, so the worst case is no cache, never a wrong one.
    }
    final adminId =
        forWrite ? auth.writeCacheScopeAdminId : auth.cacheScopeAdminId;
    return adminId == null ? null : 'tours_admin_$adminId';
  }

  /// Paint the last known-good graph off disk.
  ///
  /// Only ever ADDITIVE to an empty list: if anything is already in `tours`,
  /// or a load started while the file was being read, the cache is dropped on
  /// the floor. Fresher data must never be painted over by older data, and the
  /// generation token is the same one [_loadTours] uses.
  @visibleForTesting
  Future<void> hydrateFromDiskCache() async {
    final gen = _loadGeneration;
    final scope = await _diskCacheScope();
    if (scope == null) return;
    final snap = await diskCache.read(scope);
    if (snap == null || snap.tours.isEmpty) return;
    if (isClosed || gen != _loadGeneration || tours.isNotEmpty) return;

    // Rebuild the layout bookkeeping the SAME WAY the network path maintains
    // it, because `layoutsLoadedFor` decides "skeleton" vs "no seat plan" on
    // every chart surface and a wrong answer here is a chart that never
    // resolves:
    //
    //  * a bus whose grid came back with the cache IS fetched — that is the
    //    whole point of caching the jsonb;
    //  * a bus the SERVER said `layout: null` for is fetched AND known-null, so
    //    the chart says "no seat plan" (the true answer) instead of spinning;
    //  * anything else is left unmarked, so the background prefetch re-asks.
    //
    // Derived rather than persisted on purpose: `_layoutFetchedBusIds` is only
    // honest when it agrees with the data beside it, and a persisted set can
    // drift out of agreement with a persisted grid. This cannot.
    _layoutKnownNullBusIds
      ..clear()
      ..addAll(snap.layoutKnownNullBusIds);
    _layoutFetchedBusIds.clear();
    for (final t in snap.tours) {
      for (final b in t.buses) {
        if (b.layout != null || _layoutKnownNullBusIds.contains(b.id)) {
          _layoutFetchedBusIds.add(b.id);
        }
      }
      // Mirror `ensureTourHydrated`'s own short-circuit: a tour that carries a
      // roster is hydrated, an empty one still pays its fetch when opened. Not
      // persisted separately, for the same "flag must agree with data" reason.
      if (t.passengers.isNotEmpty || t.buses.isNotEmpty) {
        _hydratedTourIds.add(t.id);
      }
    }

    tours.assignAll(snap.tours);
    dataAsOf.value = snap.savedAt;
    isShowingCachedData.value = true;
  }

  /// Persist the current graph as the new last-known-good, debounced.
  void _scheduleDiskCacheSave() {
    _cacheSaveDebounce?.cancel();
    _cacheSaveDebounce = Timer(const Duration(milliseconds: 1200), () {
      // ignore: unawaited_futures
      saveToDiskCache();
    });
  }

  @visibleForTesting
  Future<void> saveToDiskCache() async {
    if (isClosed) return;
    final scope = await _diskCacheScope(forWrite: true);
    if (scope == null) return;
    if (isClosed) return;
    // ignore: invalid_use_of_protected_member
    final graph = List<Tour>.from(tours.value);
    if (graph.isEmpty) return;
    await diskCache.write(
      TourGraphSnapshot(
        scopeKey: scope,
        // The age the indicator shows must be the age of the DATA, not of the
        // file, so this is when the graph was last confirmed against the
        // server — set by [_markFresh] — and only falls back to now when
        // nothing set it.
        savedAt: dataAsOf.value ?? DateTime.now(),
        tours: graph,
        layoutKnownNullBusIds: Set<String>.from(_layoutKnownNullBusIds),
      ),
    );
  }

  /// The graph on screen just came from the server. The ONLY place the cached
  /// label is taken down.
  void _markFresh() {
    dataAsOf.value = DateTime.now();
    isShowingCachedData.value = false;
  }
}
