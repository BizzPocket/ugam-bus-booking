import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';

/// What the hero identity card chip should show instead of a blind price badge.
enum TourHeroChipKind { seatsLeft, pricePerSeat, seatsFilled }

class TourHeroChip {
  final TourHeroChipKind kind;
  final int? seatsLeft;
  final double? pricePerSeat;
  final int? filled;
  final int? capacity;

  const TourHeroChip.seatsLeft(this.seatsLeft)
      : kind = TourHeroChipKind.seatsLeft,
        pricePerSeat = null,
        filled = null,
        capacity = null;

  const TourHeroChip.price(this.pricePerSeat)
      : kind = TourHeroChipKind.pricePerSeat,
        seatsLeft = null,
        filled = null,
        capacity = null;

  const TourHeroChip.filled({required this.filled, required this.capacity})
      : kind = TourHeroChipKind.seatsFilled,
        seatsLeft = null,
        pricePerSeat = null;
}

/// Prefer actionable seats-left when work remains; otherwise show price if
/// meaningful (> 0); otherwise show occupancy fill.
TourHeroChip resolveTourHeroChip(Tour tour) {
  final pending = tour.pendingSeatsToAssign;
  if (pending > 0) return TourHeroChip.seatsLeft(pending);
  if (tour.pricePerSeat > 0) return TourHeroChip.price(tour.pricePerSeat);
  if (tour.totalBusSeats > 0) {
    return TourHeroChip.filled(
      filled: tour.occupiedBerths,
      capacity: tour.totalBusSeats,
    );
  }
  return TourHeroChip.price(tour.pricePerSeat);
}

enum TravelerFilter { all, needsSeat, moneyDue, single, double_ }

bool passengerNeedsSeat(Passenger p) =>
    !p.journeyDone && p.totalSeatsAssigned < p.seatBerths;

List<Passenger> filterTravelers(
  List<Passenger> passengers, {
  required TravelerFilter filter,
  String query = '',
  Set<String> moneyDuePassengerIds = const {},
}) {
  final q = query.trim().toLowerCase();
  Iterable<Passenger> list = passengers;
  switch (filter) {
    case TravelerFilter.all:
      break;
    case TravelerFilter.needsSeat:
      list = list.where(passengerNeedsSeat);
      break;
    case TravelerFilter.moneyDue:
      list = list.where((p) => moneyDuePassengerIds.contains(p.id));
      break;
    case TravelerFilter.single:
      list = list.where((p) => p.requestLines.any((l) =>
          l.seatType == SeatType.singleSofa ||
          l.seatType == SeatType.seater));
      break;
    case TravelerFilter.double_:
      list = list.where(
          (p) => p.requestLines.any((l) => l.seatType == SeatType.doubleSofa));
      break;
  }
  if (q.isEmpty) return list.toList(growable: false);
  return list
      .where((p) =>
          p.name.toLowerCase().contains(q) ||
          p.phone.toLowerCase().contains(q))
      .toList(growable: false);
}

enum NeedsAttentionKind { unseated, noDriver }

class NeedsAttentionItem {
  final NeedsAttentionKind kind;
  final String id;
  final String primary;
  final String secondary;

  const NeedsAttentionItem({
    required this.kind,
    required this.id,
    required this.primary,
    required this.secondary,
  });
}

List<NeedsAttentionItem> buildNeedsAttention(Tour tour, {int max = 4}) {
  final items = <NeedsAttentionItem>[];
  final unseated = tour.passengers.where(passengerNeedsSeat).toList();
  if (unseated.isNotEmpty) {
    final names = unseated.take(2).map((p) => p.name).join(' · ');
    items.add(NeedsAttentionItem(
      kind: NeedsAttentionKind.unseated,
      id: 'unseated',
      primary: '${unseated.length}',
      secondary: names,
    ));
  }
  final noDriver =
      tour.buses.where((b) => b.driverName.trim().isEmpty).toList();
  if (noDriver.isNotEmpty) {
    items.add(NeedsAttentionItem(
      kind: NeedsAttentionKind.noDriver,
      id: 'no-driver',
      primary: '${noDriver.length}',
      secondary: noDriver.take(2).map((b) => b.displayLabel).join(' · '),
    ));
  }
  return items.take(max).toList(growable: false);
}

enum ActivityEventCategory { system, seats, buses, money, requests }

ActivityEventCategory categorizeActivityTitle(String titleKey) {
  // titleKey is the tr() key suffix or English event type marker we tag locally.
  if (titleKey.contains('seat')) return ActivityEventCategory.seats;
  if (titleKey.contains('bus')) return ActivityEventCategory.buses;
  if (titleKey.contains('money') || titleKey.contains('pay')) {
    return ActivityEventCategory.money;
  }
  if (titleKey.contains('request')) return ActivityEventCategory.requests;
  return ActivityEventCategory.system;
}

bool busHasDriver(Bus bus) => bus.driverName.trim().isNotEmpty;
