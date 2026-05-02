class Validators {
  static String? validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Name cannot be empty';
    }
    return null;
  }

  static String? validateSeatCount(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Seat count cannot be empty';
    }
    final intValue = int.tryParse(value);
    if (intValue == null || intValue <= 0) {
      return 'Seat count must be a positive integer';
    }
    return null;
  }

  static String? validateSeatType(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Seat type cannot be empty';
    }
    final validTypes = ['singleSofa', 'doubleSofa', 'Single_Sofa', 'Double_Sofa'];
    if (!validTypes.any((t) => t.toLowerCase() == value.toLowerCase())) {
      return 'Invalid seat type';
    }
    return null;
  }
}
