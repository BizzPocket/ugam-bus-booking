import 'package:get/get.dart';
import '../screens/main_shell.dart';
import '../screens/splash_screen.dart';
import '../screens/login_screen.dart';
import '../screens/admin_setup_screen.dart';
import '../screens/customer_tour_list_screen.dart';
import '../screens/customer_my_requests_screen.dart';
import '../screens/create_tour_screen.dart';
import '../screens/tour_seat_assignment_screen.dart';
import '../screens/tour_overview_screen.dart';

class AppRoutes {
  static const String splash = '/splash';
  static const String login = '/login';
  static const String adminSetup = '/admin-setup';
  static const String customerHome = '/customer-home';
  static const String customerMyRequests = '/customer-my-requests';
  static const String home = '/';
  static const String createTour = '/create-tour';
  static const String seatAssignment = '/seat-assignment';
  static const String tourOverview = '/tour-overview';

  static final routes = [
    GetPage(name: splash, page: () => const SplashScreen()),
    GetPage(name: login, page: () => const LoginScreen()),
    GetPage(name: adminSetup, page: () => const AdminSetupScreen()),
    GetPage(name: customerHome, page: () => const CustomerTourListScreen()),
    GetPage(
      name: customerMyRequests,
      page: () => const CustomerMyRequestsScreen(),
    ),
    GetPage(name: home, page: () => const MainShell()),
    GetPage(name: createTour, page: () => const CreateTourScreen()),
    GetPage(
      name: seatAssignment,
      page: () {
        final args = Get.arguments as Map<String, dynamic>?;
        return TourSeatAssignmentScreen(
          tourId: (args?['tourId'] as String?) ?? '',
          initialPassengerId: args?['passengerId'] as String?,
        );
      },
    ),
    GetPage(
      name: tourOverview,
      page: () {
        final args = Get.arguments as Map<String, dynamic>?;
        return TourOverviewScreen(
          tourId: (args?['tourId'] as String?) ?? '',
        );
      },
    ),
  ];
}
