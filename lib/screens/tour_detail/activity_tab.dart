part of '../tour_detail_screen.dart';

// ─── ACTIVITY TAB ─────────────────────────────────────────────────────

class _ActivityTab extends StatefulWidget {
  final Tour tour;
  final UgamColorSet c;

  const _ActivityTab({required this.tour, required this.c});

  @override
  State<_ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<_ActivityTab> {
  ActivityEventCategory? _filter; // null = all

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final events = _buildTourTimelineEvents(widget.tour);
    final visible = _filter == null
        ? events
        : events.where((e) => e.category == _filter).toList();
    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _SectionEyebrow(label: tr('tour_detail.timeline'), c: c),
        const SizedBox(height: UgamSpacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _FilterChip(
                label: tr('tour_detail.activity_filter_all'),
                selected: _filter == null,
                c: c,
                onTap: () => setState(() => _filter = null),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.activity_filter_seats'),
                selected: _filter == ActivityEventCategory.seats,
                c: c,
                onTap: () => setState(() => _filter = ActivityEventCategory.seats),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.activity_filter_buses'),
                selected: _filter == ActivityEventCategory.buses,
                c: c,
                onTap: () => setState(() => _filter = ActivityEventCategory.buses),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.activity_filter_money'),
                selected: _filter == ActivityEventCategory.money,
                c: c,
                onTap: () => setState(() => _filter = ActivityEventCategory.money),
              ),
            ],
          ),
        ),
        const SizedBox(height: UgamSpacing.md),
        for (var i = 0; i < visible.length; i++)
          _TimelineRow(
            event: visible[i],
            isFirst: i == 0,
            isLast: i == visible.length - 1,
            c: c,
          ),
      ]),
    );
  }
}

/// TONE POLICY for the timeline: a log entry is NEUTRAL. Colour is spent only
/// on the two milestones that mean the tour moved forward — all seats assigned
/// and the tour locked — which are `good`. Four of these entries used to be
/// `accent`, so most of the timeline glowed copper and the two entries that
/// actually mattered had nothing left to stand out against. (Amber's job is
/// "this is yours"; a history of things that already happened is nobody's.)
List<_TimelineEvent> _buildTourTimelineEvents(Tour t) {
  final events = <_TimelineEvent>[];

  events.add(
    _TimelineEvent(
      icon: Icons.add_circle_rounded,
      title: tr('tour_detail.event_tour_created'),
      time: t.createdAt,
      tone: UgamStatusTone.neutral,
      category: ActivityEventCategory.system,
    ),
  );

  if (t.passengers.isNotEmpty) {
    final earliest = t.passengers
        .map((p) => p.createdAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    final first = t.passengers.firstWhere(
      (p) => p.createdAt == earliest,
      orElse: () => t.passengers.first,
    );
    events.add(
      _TimelineEvent(
        icon: Icons.person_add_alt_1_rounded,
        title: tr(
          'tour_detail.event_first_request',
          namedArgs: {'name': first.name},
        ),
        time: earliest,
        tone: UgamStatusTone.neutral,
        category: ActivityEventCategory.requests,
      ),
    );

    if (t.passengers.length > 1) {
      final latestReq = t.passengers
          .map((p) => p.createdAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      if (latestReq != earliest) {
        events.add(
          _TimelineEvent(
            icon: Icons.groups_rounded,
            title: tr(
              'tour_detail.event_requests_total',
              namedArgs: {'n': '${t.passengers.length}'},
            ),
            time: latestReq,
            tone: UgamStatusTone.neutral,
            category: ActivityEventCategory.requests,
          ),
        );
      }
    }
  }

  if (t.buses.isNotEmpty) {
    final earliestBus = t.buses
        .map((b) => b.createdAt)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    events.add(
      _TimelineEvent(
        icon: Icons.directions_bus_rounded,
        title: t.buses.length == 1
            ? tr('tour_detail.event_bus_added')
            : tr(
                'tour_detail.event_buses_added',
                namedArgs: {'n': '${t.buses.length}'},
              ),
        time: earliestBus,
        tone: UgamStatusTone.neutral,
        category: ActivityEventCategory.buses,
      ),
    );
  }

  if (t.totalSeatsAssigned > 0) {
    events.add(
      _TimelineEvent(
        icon: Icons.event_seat_rounded,
        title: t.totalSeatsAssigned == 1
            ? tr('tour_detail.event_seats_assigned_one')
            : tr(
                'tour_detail.event_seats_assigned_other',
                namedArgs: {'n': '${t.totalSeatsAssigned}'},
              ),
        time: t.updatedAt,
        tone: UgamStatusTone.neutral,
        category: ActivityEventCategory.seats,
      ),
    );
  }

  if (t.allSeatsAssigned) {
    events.add(
      _TimelineEvent(
        icon: Icons.check_circle_rounded,
        title: tr('tour_detail.event_all_seats_assigned'),
        time: t.updatedAt,
        tone: UgamStatusTone.good,
        category: ActivityEventCategory.seats,
      ),
    );
  }

  if (t.status == TourStatus.locked || t.status == TourStatus.completed) {
    events.add(
      _TimelineEvent(
        icon: Icons.lock_rounded,
        title: tr('tour_detail.event_tour_locked'),
        time: t.updatedAt,
        tone: UgamStatusTone.good,
        category: ActivityEventCategory.system,
      ),
    );
  }

  if (t.status == TourStatus.completed) {
    events.add(
      _TimelineEvent(
        icon: Icons.flag_rounded,
        title: tr('tour_detail.event_trip_completed'),
        time: t.updatedAt,
        tone: UgamStatusTone.neutral,
        category: ActivityEventCategory.system,
      ),
    );
  }

  events.sort((a, b) => a.time.compareTo(b.time));
  return events;
}

class _TimelineEvent {
  final IconData icon;
  final String title;
  final DateTime time;
  final UgamStatusTone tone;
  final ActivityEventCategory category;
  const _TimelineEvent({
    required this.icon,
    required this.title,
    required this.time,
    required this.tone,
    this.category = ActivityEventCategory.system,
  });
}

class _TimelineRow extends StatelessWidget {
  final _TimelineEvent event;
  final bool isFirst;
  final bool isLast;
  final UgamColorSet c;

  const _TimelineRow({
    required this.event,
    required this.isFirst,
    required this.isLast,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final tone = _toneColor(event.tone, c);
    final fill = _toneFill(event.tone, c);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            // Decorative rail — scales so the nodes don't read heavier than the
            // event text beside them on a small phone.
            width: UgamScale.px(context, 36),
            child: Column(
              children: [
                if (isFirst)
                  const SizedBox(height: 8)
                else
                  Expanded(
                    child: Container(
                      width: 2,
                      color: c.border,
                    ),
                  ),
                Container(
                  width: UgamScale.px(context, 28),
                  height: UgamScale.px(context, 28),
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    // 1.5 stays a hairline — hairlines don't scale.
                    border: Border.all(color: tone, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Icon(event.icon,
                      size: UgamScale.px(context, 13), color: tone),
                ),
                if (isLast)
                  const SizedBox(height: 8)
                else
                  Expanded(
                    child: Container(
                      width: 2,
                      color: c.border,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
              child: UgamCard.plain(
                elev: true,
                radius: UgamRadius.input,
                padding: const EdgeInsets.all(UgamSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      event.title,
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _agoLine(context, event.time),
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(color: c.ink3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _agoLine(BuildContext context, DateTime t) {
    final d = DateTime.now().difference(t);
    // Every other branch of this method is tr()'d; without the locale the
    // >6-day branch rendered an English "Jul 14 · 3:05 PM" sandwiched between
    // localized rows in the same timeline.
    if (d.inDays > 6) {
      return DateFormat('MMM d · h:mm a', context.locale.toString()).format(t);
    }
    if (d.inDays > 0) {
      return d.inDays == 1
          ? tr('tour_detail.ago_day_one')
          : tr('tour_detail.ago_day_other', namedArgs: {'n': '${d.inDays}'});
    }
    if (d.inHours > 0) {
      return tr('tour_detail.ago_hours', namedArgs: {'n': '${d.inHours}'});
    }
    if (d.inMinutes > 0) {
      return tr('tour_detail.ago_minutes', namedArgs: {'n': '${d.inMinutes}'});
    }
    return tr('tour_detail.ago_just_now');
  }
}
