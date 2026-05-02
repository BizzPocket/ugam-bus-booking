import 'dart:async';
import 'package:get/get.dart';
import '../config/appwrite_config.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/passenger.dart';
import '../models/bus_details.dart';
import '../models/payment_status.dart';
import '../services/sync_service.dart';
import 'auth_controller.dart';

class TourController extends GetxController {
  final tours = <Tour>[].obs;
  final isLoading = false.obs;
  final hasError = false.obs;
  final errorMessage = ''.obs;

  SyncService get _sync => Get.find<SyncService>();
  AuthController get _auth => Get.find<AuthController>();

  @override
  void onInit() {
    super.onInit();
    _loadTours();
    _subscribeToChanges();
  }

  void _subscribeToChanges() {
    // When coming back online, refresh
    ever(_sync.isOnline, (online) {
      if (online) _loadTours();
    });
  }

  /// Load tours — offline-first (cache → network → cache update)
  Future<void> _loadTours() async {
    isLoading.value = true;
    hasError.value = false;
    try {
      final data = await _sync.smartFetch(
        table: AppwriteConfig.toursCollection,
        cacheKey: 'all_tours',
        orderBy: r'$createdAt',
        maxAge: 120000, // 2 min cache for tours
      );

      final loaded = data.map((item) => Tour.fromAppwrite(item)).toList();
      tours.assignAll(loaded);
    } catch (_) {
      if (tours.isEmpty) {
        hasError.value = true;
        errorMessage.value = 'Could not load tours. Check your connection.';
      }
    }
    isLoading.value = false;
  }

  /// Manual refresh
  Future<void> refreshTours() => _loadTours();

  // ── Tour CRUD ─────────────────────────────────────────────

  Future<Tour> createTour({
    required String title,
    required String fromCity,
    required String toCity,
    required DateTime departureDate,
    DateTime? returnDate,
    required double pricePerSeat,
    String? description,
  }) async {
    final tour = Tour(
      title: title,
      fromCity: fromCity,
      toCity: toCity,
      departureDate: departureDate,
      returnDate: returnDate,
      pricePerSeat: pricePerSeat,
      description: description,
      createdBy: _auth.userPhone.value,
    );

    // Optimistic local update
    tours.add(tour);
    tours.refresh();

    await _sync.smartInsert(
      table: AppwriteConfig.toursCollection,
      entityId: tour.id,
      data: tour.toAppwrite(),
    );

    return tour;
  }

  Tour? getTour(String id) {
    final idx = tours.indexWhere((t) => t.id == id);
    return idx >= 0 ? tours[idx] : null;
  }

  Future<void> deleteTour(String id) async {
    tours.removeWhere((t) => t.id == id);
    await _sync.smartDelete(
      table: AppwriteConfig.toursCollection,
      entityId: id,
    );
  }

  // ── Status Transitions ────────────────────────────────────

  Future<void> updateStatus(String tourId, TourStatus status) async {
    await _updateTour(tourId, (t) => t.copyWith(status: status));
  }

  Future<void> startCollecting(String tourId) =>
      updateStatus(tourId, TourStatus.collecting);

  Future<void> markBooked(String tourId) =>
      updateStatus(tourId, TourStatus.booked);

  Future<void> startAssigning(String tourId) =>
      updateStatus(tourId, TourStatus.assigning);

  Future<void> lockTour(String tourId) =>
      updateStatus(tourId, TourStatus.locked);

  Future<void> completeTour(String tourId) =>
      updateStatus(tourId, TourStatus.completed);

  // ── Passenger Management ──────────────────────────────────

  Future<void> addPassenger(String tourId, Passenger passenger) async {
    _updateTourLocal(tourId, (t) {
      final list = List<Passenger>.from(t.passengers)..add(passenger);
      return t.copyWith(passengers: list);
    });

    await _sync.smartInsert(
      table: AppwriteConfig.passengersCollection,
      entityId: passenger.id,
      data: passenger.toAppwrite(),
    );
  }

  Future<void> removePassenger(String tourId, String passengerId) async {
    _updateTourLocal(tourId, (t) {
      final list = t.passengers.where((p) => p.id != passengerId).toList();
      return t.copyWith(passengers: list);
    });

    await _sync.smartDelete(
      table: AppwriteConfig.passengersCollection,
      entityId: passengerId,
    );
  }

  Future<void> updatePassengerPayment(
      String tourId, String passengerId, PaymentStatus status) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      updated = p.copyWith(paymentStatus: status);
      return updated!;
    });
    if (updated != null) {
      await _sync.smartUpdate(
        table: AppwriteConfig.passengersCollection,
        entityId: passengerId,
        data: updated!.toAppwrite(),
      );
    }
  }

  // ── Seat Assignment ───────────────────────────────────────

  Future<void> assignSeats(
      String tourId, String passengerId, List<String> seatNumbers) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      updated = p.copyWith(assignedSeats: seatNumbers);
      return updated!;
    });
    if (updated != null) {
      await _sync.smartUpdate(
        table: AppwriteConfig.passengersCollection,
        entityId: passengerId,
        data: updated!.toAppwrite(),
      );
    }
  }

  Future<void> unassignSeats(String tourId, String passengerId) async {
    Passenger? updated;
    _updatePassengerLocal(tourId, passengerId, (p) {
      updated = p.copyWith(assignedSeats: []);
      return updated!;
    });
    if (updated != null) {
      await _sync.smartUpdate(
        table: AppwriteConfig.passengersCollection,
        entityId: passengerId,
        data: updated!.toAppwrite(),
      );
    }
  }

  // ── Handler ───────────────────────────────────────────────

  Future<void> setHandler(String tourId, String passengerId) async {
    _updateTourLocal(tourId, (t) {
      final updatedPassengers = t.passengers.map((p) {
        if (p.isHandler) return p.copyWith(isHandler: false);
        if (p.id == passengerId) return p.copyWith(isHandler: true);
        return p;
      }).toList();
      return t.copyWith(handlerId: passengerId, passengers: updatedPassengers);
    });

    final tour = getTour(tourId);
    if (tour != null) {
      await _sync.smartUpdate(
        table: AppwriteConfig.toursCollection,
        entityId: tourId,
        data: tour.toAppwrite(),
      );
      for (final p in tour.passengers) {
        await _sync.smartUpdate(
          table: AppwriteConfig.passengersCollection,
          entityId: p.id,
          data: p.toAppwrite(),
        );
      }
    }
  }

  Future<void> removeHandler(String tourId) async {
    _updateTourLocal(tourId, (t) {
      final updatedPassengers = t.passengers
          .map((p) => p.isHandler ? p.copyWith(isHandler: false) : p)
          .toList();
      return t.copyWith(handlerId: null, passengers: updatedPassengers);
    });

    final tour = getTour(tourId);
    if (tour != null) {
      await _sync.smartUpdate(
        table: AppwriteConfig.toursCollection,
        entityId: tourId,
        data: tour.toAppwrite(),
      );
    }
  }

  // ── Bus Details ───────────────────────────────────────────

  Future<void> addBusDetails(String tourId, BusDetails details) async {
    _updateTourLocal(tourId, (t) => t.copyWith(busDetails: details));
    await _sync.smartInsert(
      table: AppwriteConfig.busDetailsCollection,
      entityId: details.id,
      data: details.toAppwrite(tourId),
    );
  }

  // ── Queries ───────────────────────────────────────────────

  List<Tour> toursByStatus(TourStatus status) =>
      tours.where((t) => t.status == status).toList();

  List<Tour> get activeTours =>
      tours.where((t) => t.status != TourStatus.completed).toList();

  List<Tour> get completedTours =>
      tours.where((t) => t.status == TourStatus.completed).toList();

  // ── Internals ─────────────────────────────────────────────

  Future<void> _updateTour(String tourId, Tour Function(Tour) updater) async {
    final idx = tours.indexWhere((t) => t.id == tourId);
    if (idx >= 0) {
      final updated = updater(tours[idx]);
      tours[idx] = updated;
      tours.refresh();

      await _sync.smartUpdate(
        table: AppwriteConfig.toursCollection,
        entityId: tourId,
        data: updated.toAppwrite(),
      );
    }
  }

  void _updateTourLocal(String tourId, Tour Function(Tour) updater) {
    final idx = tours.indexWhere((t) => t.id == tourId);
    if (idx >= 0) {
      tours[idx] = updater(tours[idx]);
      tours.refresh();
    }
  }

  void _updatePassengerLocal(
      String tourId, String passengerId, Passenger Function(Passenger) updater) {
    _updateTourLocal(tourId, (t) {
      final list = t.passengers.map((p) {
        return p.id == passengerId ? updater(p) : p;
      }).toList();
      return t.copyWith(passengers: list);
    });
  }
}
