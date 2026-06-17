import 'package:get/get.dart';
import '../screens/main_shell.dart';
import '../screens/splash_screen.dart';
import '../screens/login_screen.dart';
import '../screens/admin_setup_screen.dart';
import '../screens/customer_tour_list_screen.dart';
import '../screens/customer_my_requests_screen.dart';
import '../screens/create_tour_screen.dart';
import '../screens/seats_screen.dart';
import '../screens/seating_exceptions_screen.dart';
import '../screens/tour_groups_screen.dart';
import '../screens/tour_money_board_screen.dart';
import '../screens/account_details_screen.dart';
import '../screens/whatsapp_settings_screen.dart';
import '../screens/notifications_settings_screen.dart';
import '../screens/finance_screen.dart';

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
  static const String seatingExceptions = '/seating-exceptions';
  static const String tourGroups = '/tour-groups';
  static const String tourMoney = '/tour-money';
  static const String accountDetails = '/settings/account';
  static const String whatsappSettings = '/settings/whatsapp';
  static const String notificationsSettings = '/settings/notifications';
  static const String finance = '/settings/finance';

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
        return SeatsScreen(
          tourId: (args?['tourId'] as String?) ?? '',
          initialMode: SeatsMode.grid,
          initialPassengerId: args?['passengerId'] as String?,
          initialBusId: args?['busId'] as String?,
        );
      },
    ),
    GetPage(
      name: tourOverview,
      page: () {
        final args = Get.arguments as Map<String, dynamic>?;
        return SeatsScreen(
          tourId: (args?['tourId'] as String?) ?? '',
          initialMode: SeatsMode.summary,
        );
      },
    ),
    GetPage(
      name: seatingExceptions,
      page: () {
        final args = Get.arguments as Map<String, dynamic>?;
        return SeatingExceptionsScreen(
          tourId: (args?['tourId'] as String?) ?? '',
        );
      },
    ),
    GetPage(
      name: tourGroups,
      page: () {
        final args = Get.arguments as Map<String, dynamic>?;
        return TourGroupsScreen(
          tourId: (args?['tourId'] as String?) ?? '',
        );
      },
    ),
    GetPage(
      name: tourMoney,
      page: () {
        final args = Get.arguments as Map<String, dynamic>?;
        return TourMoneyBoardScreen(
          tourId: (args?['tourId'] as String?) ?? '',
        );
      },
    ),
    GetPage(
      name: accountDetails,
      page: () => const AccountDetailsScreen(),
    ),
    GetPage(
      name: whatsappSettings,
      page: () => const WhatsAppSettingsScreen(),
    ),
    GetPage(
      name: notificationsSettings,
      page: () => const NotificationsSettingsScreen(),
    ),
    GetPage(
      name: finance,
      page: () => const FinanceScreen(),
    ),
  ];
}
