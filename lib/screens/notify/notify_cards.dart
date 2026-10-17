part of '../notify_screen.dart';

// ─── Tour selector ────────────────────────────────────────────────────

class _TourSelector extends StatelessWidget {
  final List<Tour> tours;
  final String selectedId;
  final ValueChanged<String> onSelect;

  const _TourSelector({
    required this.tours,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final selectedIndex = tours.indexWhere((t) => t.id == selectedId);
    final currentIndex = selectedIndex < 0 ? 0 : selectedIndex;

    // UgamTabPills is a fixed segmented control built for 2–5 segments. When
    // there are more active tours than that, fall back to the shared scrolling
    // pill strip. This used to be a hand-rolled copy of [UgamSelectorPills]
    // that painted its ACTIVE pill flat `c.card` instead of the component's
    // tonal accentFill + accent ink + hairline — so past four tours the
    // selected tour lost its copper tint and stopped reading as selected.
    if (tours.length > 4) {
      return UgamSelectorPills(
        items: [for (final t in tours) UgamSelectorItem(label: t.title)],
        currentIndex: currentIndex,
        onChanged: (i) => onSelect(tours[i].id),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      child: UgamTabPills(
        currentIndex: currentIndex,
        onChanged: (i) => onSelect(tours[i].id),
        items: [for (final t in tours) UgamTabItem(label: t.title)],
      ),
    );
  }
}

// ─── Hero summary card ────────────────────────────────────────────────

class _HeroSummaryCard extends StatelessWidget {
  final Tour tour;
  final _BusInfo busInfo;
  final UgamColorSet c;

  const _HeroSummaryCard({
    required this.tour,
    required this.busInfo,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final isLocked = tour.status == TourStatus.locked;
    final handler = tour.handler;
    final locale = context.locale.toString();
    final departure = DateFormat('d MMM', locale).format(tour.departureDate);
    // The clock lives in the tour's `departure_time` ('HH:mm'), NOT in
    // departureDate — a date-only column, so formatting its time always
    // printed "00:00". Fall back to the first bus that has its own time; no
    // time anywhere → the date alone, never a made-up midnight.
    String? hhmm = tour.departureTime;
    if (hhmm == null || hhmm.trim().isEmpty) {
      for (final b in tour.buses) {
        final t = b.departureTime;
        if (t != null && t.trim().isNotEmpty) {
          hhmm = t;
          break;
        }
      }
    }
    final departureTime = formatHhMm(hhmm);
    final departureValue = departureTime == null
        ? departure
        : '$departure · $departureTime';
    final handlerCell = _InfoCell(
      c: c,
      icon: Icons.person_pin_rounded,
      label: tr('notify.info_handler'),
      value: handler?.displayName ?? tr('notify.not_assigned'),
    );
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tour.title,
                  style: UgamText.titleM.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // [UgamStatusDot] holds its label in a Flexible and documents
              // that "all call sites pass bounded width" — this one did not.
              // As a bare Row child it took unbounded constraints, so a long
              // Gujarati status could squeeze the title to nothing and then
              // overflow instead of ellipsising.
              Flexible(
                child: UgamStatusDot(
                  label: isLocked
                      ? tr('notify.status_locked')
                      : tour.status.displayName,
                  // Amber is not a status colour. "Locked" is a genuine
                  // semantic (done → good); everything before it is just the
                  // ambient state of an in-progress tour, which is what the
                  // neutral tone is for.
                  tone: isLocked ? UgamStatusTone.good : UgamStatusTone.neutral,
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            '${tour.fromCity} → ${tour.toCity}',
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.event_rounded,
                  label: tr('notify.info_departure'),
                  value: departureValue,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: _InfoCell(
                  c: c,
                  icon: Icons.directions_bus_rounded,
                  label: tr('notify.info_bus'),
                  value: busInfo.busNo,
                  maxLines: busInfo.busCount.clamp(1, 3),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          // No driver entered on any bus → the handler cell takes the row.
          if (busInfo.driverName.isEmpty)
            handlerCell
          else
            Row(
              children: [
                Expanded(
                  child: _InfoCell(
                    c: c,
                    icon: Icons.badge_outlined,
                    label: tr('notify.info_driver'),
                    value: busInfo.driverName,
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(child: handlerCell),
              ],
            ),
        ],
      ),
    );
  }
}

class _InfoCell extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final String value;
  final int maxLines;

  const _InfoCell({
    required this.c,
    required this.icon,
    required this.label,
    required this.value,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.tight,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 12, color: c.ink2),
              const SizedBox(width: 4),
              // The label half of a value pair, which is [captionStrong]'s
              // stated job — not `micro`, whose caps are a no-op in Gujarati,
              // whose tracking breaks conjuncts, and whose 10px lands at 8.5
              // on a small phone. captionStrong (12) sits on the documented
              // script floor and stays a step under the bodyStrong value
              // below it, so the figure still leads. Emphasis is `ink2`, the
              // one device that survives a fallback Indic face.
              //
              // Flexible + ellipsis because this cell is half a card wide and
              // the label was an unbounded Row child.
              Flexible(
                child: Text(
                  label,
                  style: UgamText.captionStrong.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: UgamText.bodyStrong.copyWith(color: c.ink),
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── Progress card ────────────────────────────────────────────────────

class _ProgressCard extends StatelessWidget {
  final UgamColorSet c;
  final int sent;
  final int total;

  const _ProgressCard({
    required this.c,
    required this.sent,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0.0 : (sent / total).clamp(0.0, 1.0);
    final done = sent >= total && total > 0;
    // "Everyone has been told" is a genuine semantic (good). Part-way through
    // is NOT a warning and not an ownership — it is simply an incomplete bar,
    // so it fills in ink, the same max-contrast neutral the primary control
    // uses. Amber is not a progress colour.
    final barColor = done ? c.good : c.ink;
    final labelColor = done ? c.good : c.ink2;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Expanded (not a bare Text + Spacer): the eyebrow was an
              // unbounded Row child, so a long translation next to a wide
              // "128 / 250" had nowhere to give.
              Expanded(
                child: Text(
                  done
                      ? tr('notify.progress_all_notified')
                      : tr('notify.progress_label'),
                  // A section eyebrow over translated copy → [UgamText.label].
                  // The en values for both keys were authored in CAPS for the
                  // old micro treatment ("NOTIFICATION PROGRESS") and are now
                  // sentence case, so English no longer shouts a line that is
                  // quiet in the caseless scripts.
                  style: UgamText.label.copyWith(color: labelColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Text(
                '$sent / $total',
                style: UgamText.tabular(
                  UgamText.bodyStrong.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.tight),
          Text(
            done
                ? tr('notify.progress_done_body')
                : tr(
                    'notify.progress_count_body',
                    namedArgs: {'sent': '$sent', 'total': '$total'},
                  ),
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: UgamSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: c.cardElev,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Withdrawn-seat banner ────────────────────────────────────────────

/// Names the riders who were told about a seat that has since been taken away.
///
/// They are the one group on this screen the app CANNOT reach by itself: the
/// `seat_allotment` template needs a seat to draw, and no approved template
/// says "your seat was withdrawn". Before this card they were filtered out of
/// the tracker entirely and nothing anywhere said they existed — so the card
/// states the count AND why it is a phone call rather than a Send button.
class _SeatRemovedCard extends StatelessWidget {
  final UgamColorSet c;
  final int count;

  const _SeatRemovedCard({required this.c, required this.count});

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Warm, because this is unresolved work the organiser owns — the one
          // place on the tracker where a tinted medallion carries a meaning
          // every other row's neutral disc does not.
          Container(
            width: UgamScale.px(context, 40),
            height: UgamScale.px(context, 40),
            decoration: BoxDecoration(
              color: c.warmFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.phone_in_talk_rounded,
              size: UgamScale.px(context, 19),
              color: c.warm,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr(
                    'notify.seat_removed_card_title',
                    namedArgs: {'count': '$count'},
                  ),
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('notify.seat_removed_card_body'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
