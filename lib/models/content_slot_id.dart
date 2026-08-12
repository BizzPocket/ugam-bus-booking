/// Every place in the app a server-driven block may appear.
///
/// A CLOSED registry, like the block types. A document targets a slot by name;
/// a name this build does not know is skipped. That is what lets you publish
/// for the newest release without breaking older installs, and what stops a
/// document putting content somewhere nobody designed for it.
///
/// NAMING: `<surface>.<screen>.<position>`. Keep it stable — renaming a slot
/// silently orphans every published block pointing at it.
class ContentSlotId {
  const ContentSlotId._();

  // ── Customer surface ───────────────────────────────────────
  /// Above the tour list, under the "find my seat" card. General announcements.
  static const String customerTourListTop = 'customer.tour_list.top';

  /// Shown INSTEAD of the empty state when there are no tours to browse.
  /// The highest-value slot in the app: an empty screen is a wasted one.
  static const String customerTourListEmpty = 'customer.tour_list.empty';

  /// Top of a single tour's detail page. Route notes, what to bring.
  static const String customerTourDetailTop = 'customer.tour_detail.top';

  /// Top of "my bookings".
  static const String customerRequestsTop = 'customer.my_requests.top';

  /// When the customer has no bookings yet.
  static const String customerRequestsEmpty = 'customer.my_requests.empty';

  /// Above the menu rows on the customer "more" screen. Support and policy
  /// links live naturally here.
  static const String customerMoreTop = 'customer.more.top';

  // ── Handler surface ────────────────────────────────────────
  /// Top of the handler's bus chart, above the attendance/grid tabs.
  ///
  /// Deliberately the ONLY handler slot, and content-only. Handlers work
  /// offline on moving buses and are handling cash; a block must never sit
  /// between them and the collect sheet. Use it for day-of instructions —
  /// "depot changed", "call the office before departure".
  static const String handlerChartTop = 'handler.chart.top';

  // ── Admin surface ──────────────────────────────────────────
  /// Top of the operator's tour list. Product announcements, release notes.
  static const String adminHomeTop = 'admin.home.top';

  /// Top of a tour's detail page.
  static const String adminTourDetailTop = 'admin.tour_detail.top';

  /// Top of the money board. Reconciliation guidance, month-end reminders.
  static const String adminMoneyTop = 'admin.money.top';

  /// Every slot this build can render. A document naming anything else is a
  /// newer document, not an error.
  static const Set<String> known = {
    customerTourListTop,
    customerTourListEmpty,
    customerTourDetailTop,
    customerRequestsTop,
    customerRequestsEmpty,
    customerMoreTop,
    handlerChartTop,
    adminHomeTop,
    adminTourDetailTop,
    adminMoneyTop,
  };
}
