import 'package:easy_localization/easy_localization.dart';

class Validators {
  static String? validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return tr('validation.name_required');
    }
    return null;
  }

  static String? validateSeatCount(String? value) {
    if (value == null || value.trim().isEmpty) {
      return tr('validation.seat_count_required');
    }
    final intValue = int.tryParse(value);
    if (intValue == null || intValue <= 0) {
      return tr('validation.seat_count_positive');
    }
    return null;
  }

  static String? validateSeatType(String? value) {
    if (value == null || value.trim().isEmpty) {
      return tr('validation.seat_type_required');
    }
    final validTypes = ['singleSofa', 'doubleSofa', 'Single_Sofa', 'Double_Sofa'];
    if (!validTypes.any((t) => t.toLowerCase() == value.toLowerCase())) {
      return tr('validation.seat_type_invalid');
    }
    return null;
  }
}
