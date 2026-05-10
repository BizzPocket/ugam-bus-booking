import 'package:get/get.dart';

import '../controllers/user_controller.dart';
import '../models/passenger.dart';

/// Display-side enrichment for Passenger.
///
/// `displayName` returns the name the current admin has saved this
/// phone as in their contacts directory, falling back to the name the
/// customer typed on the booking form. Use this everywhere a passenger
/// name is shown to the agent — it's a one-line, GetX-aware swap.
extension PassengerDisplay on Passenger {
  String get displayName {
    if (!Get.isRegistered<UserController>()) return name;
    return Get.find<UserController>().displayName(phone, name);
  }
}
