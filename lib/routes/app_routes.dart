import 'package:get/get.dart';
import '../screens/main_shell.dart';
import '../screens/splash_screen.dart';
import '../screens/login_screen.dart';
import '../screens/admin_setup_screen.dart';
import '../screens/create_tour_screen.dart';
import '../screens/seat_assignment_screen.dart';
import '../screens/bus_list_screen.dart';
import '../screens/add_bus_form_screen.dart';
import '../screens/handler_dashboard_screen.dart';
import '../screens/handler_assignment_screen.dart';
import '../screens/handler_cash_screen.dart';
import '../screens/search_screen.dart';


class AppRoutes {
  static const String splash = '/splash';
  static const String login = '/login';
  static const String adminSetup = '/admin-setup';
  static const String home = '/';
  static const String createTour = '/create-tour';
  static const String seatAssignment = '/seat-assignment';
  static const String busList = '/bus-list';
  static const String addBus = '/add-bus';
  static const String handlerDashboard = '/handler-dashboard';
  static const String handlerAssignment = '/handler-assignment';
  static const String handlerCash = '/handler-cash';
  static const String search = '/search';

  static final routes = [
    GetPage(
      name: splash,
      page: () => const SplashScreen(),
    ),
    GetPage(
      name: login,
      page: () => const LoginScreen(),
    ),
    GetPage(
      name: adminSetup,
      page: () => const AdminSetupScreen(),
    ),
    GetPage(
      name: home,
      page: () => const MainShell(),
    ),
    GetPage(
      name: createTour,
      page: () => const CreateTourScreen(),
    ),
    GetPage(
      name: seatAssignment,
      page: () => const SeatAssignmentScreen(),
    ),
    GetPage(
      name: busList,
      page: () => const BusListScreen(),
    ),
    GetPage(
      name: addBus,
      page: () => AddBusFormScreen(
        tourId: Get.arguments?['tourId'] as String?,
      ),
    ),
    GetPage(
      name: handlerDashboard,
      page: () => const HandlerDashboardScreen(),
    ),
    GetPage(
      name: handlerAssignment,
      page: () => HandlerAssignmentScreen(
        tourId: Get.arguments?['tourId'] as String? ?? '',
      ),
    ),
    GetPage(
      name: handlerCash,
      page: () => HandlerCashScreen(
        tourId: Get.arguments?['tourId'] as String? ?? '',
      ),
    ),
    GetPage(
      name: search,
      page: () => const SearchScreen(),
    ),
  ];
}
