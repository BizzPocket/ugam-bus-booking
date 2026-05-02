class AppConstants {
  static const int maxBuses = 10;
  static const int defaultSingleSofaUpper = 4;
  static const int defaultSingleSofaBottom = 4;
  static const int defaultDoubleSofaUpper = 2;
  static const int defaultDoubleSofaBottom = 2;
}

class ValidationPatterns {
  static final namePattern = RegExp(r'^[a-zA-Z\s]+$');
  static final mobilePattern = RegExp(r'^[0-9]{10}$');
}

class RoutePaths {
  static const dashboard = '/dashboard';
  static const booking = '/booking';
  static const search = '/search';
  static const busList = '/bus-list';
  static const reports = '/reports';
  static const bookingDetail = '/booking-detail';
}