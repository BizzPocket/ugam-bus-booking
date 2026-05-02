import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import '../models/bus.dart';


class BusController extends GetxController {
  final buses = <Bus>[].obs;
  final isLoading = false.obs;

  void configureBus(String name, SeatConfiguration config) {
    final bus = Bus(
      id: const Uuid().v4(),
      name: name,
      totalCapacity: config.totalSeats,
      seatConfiguration: config,
    );
    buses.add(bus);
    buses.refresh();
  }

  List<Bus> getAvailableBuses() {
    return buses.where((b) => !b.isFull).toList();
  }

  void updateBus(Bus bus) {
    final index = buses.indexWhere((b) => b.id == bus.id);
    if (index != -1) {
      buses[index] = bus;
      buses.refresh();
    }
  }

  void removeBus(String id) {
    buses.removeWhere((b) => b.id == id);
  }
}
