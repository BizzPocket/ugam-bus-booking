part of '../notify_screen.dart';

/// The two bodies of the Notify screen: the post-lock tracker and the
/// pre-lock gate.
extension _NotifySections on _NotifyScreenState {
  // ── Tracker (post-lock) ────────────────────────────────────────
  Widget _buildTracker({
    required Tour tour,
    required List<Passenger> roster,
    required List<Passenger> stranded,
    required int sentCount,
    required int pendingCount,
    required _BusInfo busInfo,
    required UgamColorSet c,
  }) {
    if (roster.isEmpty) {
      return UgamEmpty(
        icon: Icons.event_seat_outlined,
        title: tr('notify.empty_no_seats'),
        body: tr('notify.assign_first'),
      );
    }

    final q = _query.toLowerCase();
    final baseByFilter = switch (_filter) {
      _NotifyFilter.all => roster,
      // "Pending" is everyone who still needs something from the organiser —
      // a chart to send, or a phone call about a withdrawn seat.
      _NotifyFilter.pending => roster.where((p) => !_isSent(p)).toList(),
      _NotifyFilter.notified => roster.where(_isSent).toList(),
    };
    final filtered = q.isEmpty
        ? baseByFilter
        : baseByFilter
              .where(
                (p) =>
                    p.displayName.toLowerCase().contains(q) ||
                    p.phone.toLowerCase().contains(q),
              )
              .toList();

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.huge,
      ),
      children: [
        _HeroSummaryCard(tour: tour, busInfo: busInfo, c: c),
        const SizedBox(height: UgamSpacing.md),
        // Counted over the WHOLE roster, so a stranded rider keeps the bar off
        // 100% and the card off "Every passenger has been notified" — which it
        // used to claim while someone sat holding a message about a seat that
        // had been taken back.
        _ProgressCard(c: c, sent: sentCount, total: roster.length),
        if (stranded.isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.md),
          _SeatRemovedCard(c: c, count: stranded.length),
        ],
        if (tour.buses.isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.md),
          _BusMessageCard(c: c, onTap: () => _openBusMessageComposer(tour)),
        ],
        const SizedBox(height: UgamSpacing.md),
        UgamTabPills(
          currentIndex: _filter.index,
          onChanged: (i) => _update(() => _filter = _NotifyFilter.values[i]),
          items: [
            UgamTabItem(label: tr('notify.filter_all'), count: roster.length),
            UgamTabItem(label: tr('notify.filter_pending'), count: pendingCount),
            UgamTabItem(label: tr('notify.filter_notified'), count: sentCount),
          ],
        ),
        const SizedBox(height: UgamSpacing.md),
        // A dead end with no way out was a bare sentence. This state is only
        // ever reachable BECAUSE of a filter or a query (an empty roster is
        // caught above), so there is always exactly one useful action — undo
        // whichever one is hiding the rows.
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
            child: _query.isNotEmpty
                ? UgamEmpty(
                    icon: Icons.search_off_rounded,
                    title: tr('notify.no_matches', namedArgs: {
                      'query': _query,
                    }),
                    cta: UgamCTA(
                      label: tr('notify.clear_search'),
                      leadingIcon: Icons.close_rounded,
                      // Clear the text but LEAVE the field open — the agent is
                      // mid-search and almost always wants to retype, not to
                      // lose the search bar as well.
                      onPressed: () => _update(() {
                        _searchCtrl.clear();
                        _query = '';
                      }),
                    ),
                  )
                : UgamEmpty(
                    icon: Icons.filter_alt_off_rounded,
                    title: tr('notify.nothing_here'),
                    cta: UgamCTA(
                      label: tr('notify.show_all'),
                      leadingIcon: Icons.list_rounded,
                      onPressed: () =>
                          _update(() => _filter = _NotifyFilter.all),
                    ),
                  ),
          )
        else
          for (var i = 0; i < filtered.length; i++) ...[
            _NotifyRow(
              passenger: filtered[i],
              state: notifyRowState(filtered[i]),
              c: c,
              // Repeat the EXACT after-lock message to just this one person:
              // the `seat_allotment` Cloud API template (highlighted seat-chart
              // image header + boarding/departure/handler body) — the same
              // payload the bulk "send to all pending" CTA fires, scoped to one
              // id. Not the old "Ticket Confirmed!" deep-link/OS-share caption.
              // A rider whose seat was withdrawn takes the call-them path
              // instead — there is no template that says that truthfully.
              onSend: () => _rowAction(tour, filtered[i]),
            ),
            if (i != filtered.length - 1)
              const SizedBox(height: UgamSpacing.tight),
          ],
      ],
    );
  }

  // ── Lock gate (pre-lock) ───────────────────────────────────────
  Widget _buildLockGate({required Tour tour, required UgamColorSet c}) {
    final allAssigned = tour.allSeatsAssigned;
    final hasHandler = tour.handlerId != null;
    final hasPassengers = tour.passengers.isNotEmpty;
    // Whole-bus announcements don't need lock — the recipient set (riders
    // seated on a bus) already exists during the assigning phase. Surface the
    // SAME composer here, but only once someone is actually seated so the card
    // is never a dead-end (the composer disables Send for a 0-rider bus anyway).
    final anySeated = tour.passengers.any((p) => p.assignedSeats.isNotEmpty);

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.huge,
      ),
      children: [
        _HeroSummaryCard(tour: tour, busInfo: _resolveBusInfo(tour), c: c),
        if (tour.buses.isNotEmpty && anySeated) ...[
          const SizedBox(height: UgamSpacing.md),
          _BusMessageCard(c: c, onTap: () => _openBusMessageComposer(tour)),
        ],
        const SizedBox(height: UgamSpacing.lg),
        UgamCard.plain(
          padding: const EdgeInsets.fromLTRB(
            UgamSpacing.lg,
            UgamSpacing.lg,
            UgamSpacing.lg,
            UgamSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // Decorative medallion. It labels a card; it is not a berth
                  // the agent picked, so it carries no accent — see [Brand].
                  Container(
                    width: UgamScale.px(context, 40),
                    height: UgamScale.px(context, 40),
                    decoration: BoxDecoration(
                      color: c.cardElev,
                      borderRadius: BorderRadius.circular(UgamRadius.input),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.lock_outline_rounded,
                      size: UgamScale.px(context, 19),
                      color: c.ink2,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr('notify.lock_gate_ready'),
                          style: UgamText.titleM.copyWith(color: c.ink),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('notify.lock_gate_body'),
                          style: UgamText.caption.copyWith(color: c.ink2),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UgamSpacing.lg),
              _Check(
                done: hasPassengers,
                label: tr('notify.check_has_passengers'),
                c: c,
              ),
              const SizedBox(height: UgamSpacing.sm),
              _Check(
                done: allAssigned,
                label: tr('notify.check_all_assigned'),
                c: c,
              ),
              const SizedBox(height: UgamSpacing.sm),
              _Check(
                done: hasHandler,
                label: tr('notify.check_has_handler'),
                c: c,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
