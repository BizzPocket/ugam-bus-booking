import 'dart:async';

import 'package:flutter/foundation.dart';

/// Debounces a list's search-as-you-type filter — but ONLY for big lists.
///
/// Each keystroke on a long roster re-filters and re-lays-out every row; on a
/// 2–3 GB phone typing a name into a 70-row list drops frames on every letter.
/// Holding the filter until typing pauses ([delay]) costs one re-filter per
/// burst instead of one per key.
///
/// Small lists ([threshold] rows or fewer) filter on every keystroke exactly as
/// before, so their feel is unchanged. Clearing the query (empty text) always
/// applies at once — an emptied box must never keep showing filtered results.
/// The query that finally applies is always the latest one typed, so results
/// are identical to the undebounced filter.
class SearchDebouncer {
  SearchDebouncer({
    this.delay = const Duration(milliseconds: 250),
    this.threshold = 50,
  });

  final Duration delay;
  final int threshold;
  Timer? _timer;

  /// True while a debounced apply is waiting.
  @visibleForTesting
  bool get isPending => _timer?.isActive ?? false;

  /// Applies [query] via [apply] — immediately for a list of [rowCount] ≤
  /// [threshold] rows or an empty [query], else after [delay] of quiet.
  void run(String query, int rowCount, void Function(String query) apply) {
    _timer?.cancel();
    _timer = null;
    if (rowCount <= threshold || query.trim().isEmpty) {
      apply(query);
      return;
    }
    _timer = Timer(delay, () {
      _timer = null;
      apply(query);
    });
  }

  /// Drops a pending apply (e.g. the search box was closed and cleared).
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}
