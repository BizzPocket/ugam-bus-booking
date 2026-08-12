import 'package:get/get.dart';
import '../screens/board/board_screen.dart';
import '../screens/charts_screen.dart';
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
import '../screens/pickup_locations_screen.dart';
import '../screens/inbox_screen.dart';

class AppRoutes {
  /// **The stop-and-review gate** (Board interaction spec §15, step 2).
  ///
  /// One boolean decides whether [seatAssignment] — the app's "open this bus's
  /// chart" destination, used by the charts tab, the requests roster, the
  /// seating-exceptions list and the tour overview — lands on the new Board or
  /// on the seat grid it is trialling against.
  ///
  /// Everything the Board replaces is still in the tree and still routable:
  ///
  /// | route | screen |
  /// |---|---|
  /// | `/board` | [BoardScreen] — direct, always |
  /// | `/seat-assignment` | [BoardScreen] while this is true, [SeatsScreen] when false |
  /// | `/seat-grid` | [SeatsScreen] — always, whatever this says |
  /// | `/charts` | [ChartsScreen] — always (also still the CHARTS shell tab) |
  ///
  /// So the fallback, if the live-tour review goes badly, is flipping this to
  /// `false`. No screen is deleted, no call site changes, and the two screens
  /// the Board is trialling against keep routes of their own for a side-by-side
  /// comparison during the review itself.
  static const bool boardReplacesChart = true;

  static const String splash = '/splash';
  static const String login = '/login';
  static const String adminSetup = '/admin-setup';
  static const String customerHome = '/customer-home';
  static const String customerMyRequests = '/customer-my-requests';
  static const String home = '/';
  static const String createTour = '/create-tour';

  /// The Board, reached directly. Args: `tourId`, optional `busId`.
  static const String board = '/board';

  /// The read-only chart browser. It is also the CHARTS shell tab (owned by
  /// `main_shell.dart`); this route exists so the fallback has a name to be
  /// pushed by during the review rather than only a tab index.
  static const String charts = '/charts';

  /// "Open this bus's chart." Resolves per [boardReplacesChart].
  static const String seatAssignment = '/seat-assignment';

  /// The seat grid, unconditionally — the instant fallback, and the way to
  /// stand the two surfaces side by side on the same bus during the review.
  ///
  /// A sibling path rather than `/seat-assignment/legacy`: GetX builds a route
  /// TREE out of the path segments, and a child of a registered parent is a
  /// shape worth not relying on for the one route whose whole job is to work
  /// when something else has gone wrong.
  static const String seatGrid = '/seat-grid';

  static const String tourOverview = '/tour-overview';
  static const String seatingExceptions = '/seating-exceptions';
  static const String tourGroups = '/tour-groups';
  static const String tourMoney = '/tour-money';
  static const String accountDetails = '/settings/account';
  static const String whatsappSettings = '/settings/whatsapp';
  static const String notificationsSettings = '/settings/notifications';
  static const String finance = '/settings/finance';
  static const String pickupLocations = '/settings/pickup-locations';
  static const String inbox = '/inbox';

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
      name: board,
      page: () {
        final args = Get.arguments as Map<String, dynamic>?;
        return BoardScreen(
          tourId: (args?['tourId'] as String?) ?? '',
          initialBusId: args?['busId'] as String?,
        );
      },
    ),
    GetPage(name: charts, page: () => const ChartsScreen()),
    GetPage(
      name: seatAssignment,
      page: () {
        final args = Get.arguments as Map<String, dynamic>?;
        final passengerId = args?['passengerId'] as String?;
        // A caller carrying a passengerId is not asking to LOOK at the chart,
        // it is asking to place that person (the seating-exceptions list and
        // the requests roster both do this). The Board has no assign picker in
        // this wave, so honouring the flag there would silently drop the
        // argument and strand the agent on a chart with no way to act. Those
        // callers keep the seat grid until the assign lens lands.
        if (boardReplacesChart && (passengerId == null || passengerId.isEmpty)) {
          return BoardScreen(
            tourId: (args?['tourId'] as String?) ?? '',
            initialBusId: args?['busId'] as String?,
          );
        }
        return SeatsScreen(
          tourId: (args?['tourId'] as String?) ?? '',
          initialMode: SeatsMode.grid,
          initialPassengerId: passengerId,
          initialBusId: args?['busId'] as String?,
        );
      },
    ),
    GetPage(
      name: seatGrid,
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
    GetPage(
      name: pickupLocations,
      page: () => const PickupLocationsScreen(),
    ),
    GetPage(
      name: inbox,
      page: () => const InboxScreen(),
    ),
  ];
}
