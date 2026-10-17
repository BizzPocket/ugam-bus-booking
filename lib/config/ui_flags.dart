/// Screen-level visibility switches.
///
/// These are NOT remote flags (see `remote_flags_config.dart` for those) — they
/// are local, compile-time-ish switches for whole UI blocks the agent asked to
/// take off the screen. Keeping the block behind a named switch rather than
/// deleting it means the data-helpers that feed it stay live and tested, and
/// turning one back on is a one-line change instead of an archaeology dig.
///
/// Deliberately mutable statics so a widget test can flip one for a single
/// case; nothing in the app writes to them at runtime.
class UiFlags {
  UiFlags._();

  /// The "Needs attention" blocker lists — the dashboard section (with its
  /// "All caught up" counterpart) and the tour Overview tab's equivalent block,
  /// including their "Review" CTA chips.
  ///
  /// Off: the agent works from the Requests / Money screens and the trip hero's
  /// next action instead, and does not want the same blockers re-listed as a
  /// standing nag on two more surfaces.
  static bool showAttentionSections = false;
}
