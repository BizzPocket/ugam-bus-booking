import 'package:get/get.dart';
import '../controllers/tour_controller.dart';
import '../models/payment_status.dart';

/// Searches passengers across all tours via TourController.
/// No external SearchEngine dependency required.
class AppSearchController extends GetxController {
  final searchQuery = ''.obs;
  final searchResults = <SearchResult>[].obs;
  final isSearching = false.obs;

  TourController get _tourCtrl => Get.find<TourController>();

  void search(String query) {
    searchQuery.value = query;
    isSearching.value = true;

    if (query.isEmpty) {
      searchResults.clear();
      isSearching.value = false;
      return;
    }

    final q = query.toLowerCase();
    final results = <String, SearchResult>{};

    for (final tour in _tourCtrl.tours) {
      for (final p in tour.passengers) {
        final matchesName = p.name.toLowerCase().contains(q);
        final matchesPhone = p.phone.contains(q);
        if (matchesName || matchesPhone) {
          results[p.id] = SearchResult(
            passengerId: p.id,
            tourId: tour.id,
            tourTitle: tour.title,
            customerName: p.name,
            mobileNumber: p.phone,
            seatDetails: p.assignedSeats.join(', '),
            paymentStatus: p.paymentStatus,
          );
        }
      }
    }

    searchResults.value = results.values.toList();
    isSearching.value = false;
  }

  void clearSearch() {
    searchQuery.value = '';
    searchResults.clear();
  }
}

class SearchResult {
  final String passengerId;
  final String tourId;
  final String tourTitle;
  final String customerName;
  final String? mobileNumber;
  final String seatDetails;
  final PaymentStatus paymentStatus;

  SearchResult({
    required this.passengerId,
    required this.tourId,
    required this.tourTitle,
    required this.customerName,
    this.mobileNumber,
    required this.seatDetails,
    required this.paymentStatus,
  });
}
