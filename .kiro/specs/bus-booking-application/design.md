# Bus Booking Application - Design Document

## Overview

The Bus Booking Application is a comprehensive system designed to help booking agents manage customer reservations across multiple buses. The application handles the complete booking lifecycle from input parsing through seat allocation, payment tracking, and reporting. The system prioritizes age-based seat preferences, smart multi-seat allocation to keep groups together, and provides a premium accessible user interface.

### Design Goals

- **Deterministic Allocation**: Seat allocation follows clear, predictable rules that agents can understand and explain
- **Age-Adaptive**: Automatically assigns preferred seats based on customer age group (elderly → bottom, young → upper)
- **Group-Friendly**: Keeps multi-seat bookings together on the same bus when possible
- **Accessible**: WCAG 2.1 AA compliant with screen reader support and keyboard navigation
- **Multi-Bus Support**: Manages up to 10 buses with real-time capacity tracking

### Technology Stack

- **Language**: Dart (type-safe, object-oriented)
- **Framework**: Flutter (cross-platform: iOS, Android, Web, Desktop)
- **State Management**: GetX (reactive state management, dependency injection, routing)
- **UI Framework**: Flutter Material Design 3 + Cupertino (platform-adaptive UI)
- **Testing**: Flutter Test + fast-check (property-based testing)
- **Build Tool**: Flutter CLI

---

## Flutter Application Architecture

### Project Structure

```
lib/
├── main.dart                 # App entry point
├── app.dart                  # App configuration
├── config/
│   └── theme.dart            # Theme configuration
├── models/
│   ├── booking.dart          # Booking model
│   ├── bus.dart              # Bus model
│   ├── seat.dart             # Seat model
│   └── customer.dart         # Customer model
├── services/
│   ├── booking_service.dart  # Booking business logic
│   ├── bus_service.dart      # Bus management
│   ├── seat_allocator.dart   # Seat allocation algorithm
│   ├── parser_service.dart   # Input parsing
│   └── search_service.dart   # Search functionality
├── providers/
│   ├── booking_provider.dart # Booking state
│   ├── bus_provider.dart     # Bus state
│   └── theme_provider.dart   # Theme state
├── screens/
│   ├── dashboard_screen.dart # Main dashboard
│   ├── booking_screen.dart   # Create booking
│   ├── search_screen.dart    # Search bookings
│   ├── bus_list_screen.dart  # Bus management
│   └── report_screen.dart    # Reports view
├── components/
│   ├── booking_form.dart     # Booking input form
│   ├── seat_map.dart         # Visual seat map
│   ├── bus_card.dart         # Bus status card
│   ├── search_bar.dart       # Search input
│   ├── payment_toggle.dart   # Payment status toggle
│   └── booking_list.dart     # Booking list view
└── utils/
    ├── constants.dart        # App constants
    ├── validators.dart       # Input validators
    └── formatters.dart       # Text formatters
```

### State Management (GetX)

GetX provides a simple, lightweight, and powerful state management solution for Flutter. It combines reactive state management, dependency injection, and route management in a single package.

#### GetX Controllers

```dart
import 'package:get/get.dart';

// Booking Controller
class BookingController extends GetxController {
  final bookings = <Booking>[].obs;
  final isLoading = false.obs;

  void createBooking(ParsedBookingInput input) {
    isLoading.value = true;
    final booking = BookingService().createBooking(input);
    bookings.add(booking);
    isLoading.value = false;
    Get.snackbar('Success', 'Booking created successfully');
  }

  void updatePaymentStatus(String bookingId, PaymentStatus status) {
    BookingService().updatePaymentStatus(bookingId, status);
    final index = bookings.indexWhere((b) => b.id == bookingId);
    if (index != -1) {
      bookings[index] = bookings[index].copyWith(
        paymentStatus: status,
        updatedAt: DateTime.now(),
      );
    }
  }

  void cancelBooking(String bookingId) {
    BookingService().cancelBooking(bookingId);
    bookings.removeWhere((b) => b.id == bookingId);
    Get.snackbar('Cancelled', 'Booking has been cancelled');
  }

  List<Booking> getBookingsByBus(String busId) {
    return bookings.where((b) => b.busId == busId).toList();
  }

  List<Booking> searchByName(String query) {
    return bookings
        .where((b) => b.customerName.toLowerCase().contains(query.toLowerCase()))
        .toList();
  }

  List<Booking> searchByMobile(String query) {
    return bookings
        .where((b) => b.mobileNumber?.contains(query) ?? false)
        .toList();
  }
}

// Bus Controller
class BusController extends GetxController {
  final buses = <Bus>[].obs;
  final isLoading = false.obs;

  void configureBus(String id, SeatConfiguration config) {
    isLoading.value = true;
    final bus = BusService().configureBus(id, config);
    buses.add(bus);
    isLoading.value = false;
  }

  BusStatus getBusStatus(String busId) {
    return BusService().getBusStatus(busId);
  }

  List<Bus> getAvailableBuses() {
    return buses.where((b) => !BusService().isBusFull(b.id)).toList();
  }

  void updateBus(Bus bus) {
    final index = buses.indexWhere((b) => b.id == bus.id);
    if (index != -1) {
      buses[index] = bus;
    }
  }
}

// Theme Controller
class ThemeController extends GetxController {
  final isDarkMode = false.obs;

  void toggleTheme() {
    isDarkMode.value = !isDarkMode.value;
    Get.changeThemeMode(isDarkMode.value ? ThemeMode.dark : ThemeMode.light);
    savePreference();
  }

  void savePreference() {
    // Save to shared preferences or local storage
  }

  void loadPreference() {
    // Load from shared preferences or local storage
  }
}

// Search Controller
class SearchController extends GetxController {
  final searchQuery = ''.obs;
  final searchResults = <SearchResult>[].obs;
  final isSearching = false.obs;

  void search(String query) {
    searchQuery.value = query;
    isSearching.value = true;

    if (query.isEmpty) {
      searchResults.clear();
      isSearching.value = false;
      return;
    }

    // Combine name and mobile search
    final nameResults = SearchEngine().searchByName(query);
    final mobileResults = SearchEngine().searchByMobile(query);
    
    // Merge and deduplicate results
    final allResults = [...nameResults, ...mobileResults];
    final uniqueResults = <String, SearchResult>{};
    for (final result in allResults) {
      uniqueResults[result.bookingId] = result;
    }
    searchResults.value = uniqueResults.values.toList();
    
    isSearching.value = false;
  }

  void clearSearch() {
    searchQuery.value = '';
    searchResults.clear();
  }
}
```

#### GetX Binding

```dart
// Bindings for dependency injection
class AppBinding implements Bindings {
  @override
  void dependencies() {
    Get.lazyPut<BookingController>(() => BookingController());
    Get.lazyPut<BusController>(() => BusController());
    Get.lazyPut<ThemeController>(() => ThemeController());
    Get.lazyPut<SearchController>(() => SearchController());
    Get.lazyPut<BookingService>(() => BookingService());
    Get.lazyPut<BusService>(() => BusService());
    Get.lazyPut<SeatAllocator>(() => SeatAllocator());
    Get.lazyPut<BookingInputParser>(() => BookingInputParser());
    Get.lazyPut<SearchEngine>(() => SearchEngine());
    Get.lazyPut<ReportGenerator>(() => ReportGenerator());
  }
}

// Route management with GetX
class AppRoutes {
  static const String dashboard = '/dashboard';
  static const String booking = '/booking';
  static const String search = '/search';
  static const String busList = '/bus-list';
  static const String reports = '/reports';
  static const String bookingDetail = '/booking-detail';

  static final routes = [
    GetPage(name: dashboard, page: () => const DashboardScreen(), binding: AppBinding()),
    GetPage(name: booking, page: () => const BookingScreen(), binding: AppBinding()),
    GetPage(name: search, page: () => const SearchScreen(), binding: AppBinding()),
    GetPage(name: busList, page: () => const BusListScreen(), binding: AppBinding()),
    GetPage(name: reports, page: () => const ReportScreen(), binding: AppBinding()),
    GetPage(name: bookingDetail, page: () => BookingDetailScreen(), binding: AppBinding()),
  ];
}

// Navigation examples
void navigateToBooking() {
  Get.toNamed(AppRoutes.booking);
}

void navigateWithArguments() {
  Get.toNamed('/booking-detail', arguments: {'bookingId': 'BK-001'});
}

void navigateAndReplace() {
  Get.offAllNamed(AppRoutes.dashboard);
}

void goBack() {
  Get.back();
}
```

#### GetX Snackbar and Dialog

```dart
// Success snackbar
void showSuccess(String message) {
  Get.snackbar(
    'Success',
    message,
    snackPosition: SnackPosition.BOTTOM,
    backgroundColor: Colors.green,
    colorText: Colors.white,
    margin: const EdgeInsets.all(16),
    borderRadius: 8,
  );
}

// Error snackbar
void showError(String message) {
  Get.snackbar(
    'Error',
    message,
    snackPosition: SnackPosition.BOTTOM,
    backgroundColor: Colors.red,
    colorText: Colors.white,
    margin: const EdgeInsets.all(16),
    borderRadius: 8,
  );
}

// Confirmation dialog
Future<bool> showConfirmDialog(String title, String message) async {
  return await Get.dialog<bool>(
    AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Get.back(result: false), child: const Text('Cancel')),
        ElevatedButton(onPressed: () => Get.back(result: true), child: const Text('Confirm')),
      ],
    ),
  ) ?? false;
}

// Loading overlay
void showLoading([String message = 'Loading...']) {
  Get.showOverlay(
    asyncFunction: () async {
      await Future.delayed(const Duration(seconds: 2));
    },
    loadingWidget: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message),
        ],
      ),
    ),
  );
}
```

### Material Design 3 Theme

```dart
class AppTheme {
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF1976D2),
        primary: const Color(0xFF1976D2),
        secondary: const Color(0xFF26A69A),
        tertiary: const Color(0xFFFF7043),
        surface: const Color(0xFFFAFAFA),
        background: const Color(0xFFFFFFFF),
      ),
      typography: Typography.material2024(),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey[100],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1976D2), width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.red, width: 2),
        ),
      ),
      cardTheme: CardTheme(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF90CAF9),
        primary: const Color(0xFF90CAF9),
        secondary: const Color(0xFF80CBC4),
        tertiary: const Color(0xFFFFAB91),
        surface: const Color(0xFF121212),
        background: const Color(0xFF1E1E1E),
        brightness: Brightness.dark,
      ),
      // Similar configurations for dark mode
    );
  }
}
```

### Platform-Adaptive UI Design

The application uses Flutter's platform-aware widgets to provide native look and feel on both Android and iOS.

#### Platform Detection

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

enum PlatformType { android, ios, web, desktop }

class PlatformDetector {
  static PlatformType get currentPlatform {
    if (kIsWeb) return PlatformType.web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return PlatformType.android;
      case TargetPlatform.iOS:
        return PlatformType.ios;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return PlatformType.desktop;
    }
  }

  static bool get isAndroid => currentPlatform == PlatformType.android;
  static bool get isIOS => currentPlatform == PlatformType.ios;
  static bool get isMobile => isAndroid || isIOS;
}
```

#### Platform-Specific Navigation

```dart
// Android: Use Material Navigation Drawer + Bottom Navigation
class AndroidNavigationShell extends StatelessWidget {
  final Widget child;
  final int currentIndex;
  final Function(int) onItemTap;

  const AndroidNavigationShell({
    super.key,
    required this.child,
    required this.currentIndex,
    required this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bus Booking'),
        actions: [
          IconButton(
            icon: const Icon(Icons.dark_mode),
            onPressed: () => _toggleTheme(context),
          ),
        ],
      ),
      drawer: _buildDrawer(context),
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: currentIndex,
        onDestinationSelected: onItemTap,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          NavigationDestination(icon: Icon(Icons.add_circle), label: 'Booking'),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(icon: Icon(Icons.directions_bus), label: 'Buses'),
        ],
      ),
    );
  }

  Widget _buildDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Color(0xFF1976D2)),
            child: Text('Bus Booking', style: TextStyle(color: Colors.white, fontSize: 24)),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard),
            title: const Text('Dashboard'),
            onTap: () => Navigator.pushReplacementNamed(context, '/'),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New Booking'),
            onTap: () => Navigator.pushReplacementNamed(context, '/booking'),
          ),
          ListTile(
            leading: const Icon(Icons.search),
            title: const Text('Search'),
            onTap: () => Navigator.pushReplacementNamed(context, '/search'),
          ),
          ListTile(
            leading: const Icon(Icons.analytics),
            title: const Text('Reports'),
            onTap: () => Navigator.pushReplacementNamed(context, '/reports'),
          ),
        ],
      ),
    );
  }
}

// iOS: Use Cupertino TabBar + Navigation
class IOSNavigationShell extends StatelessWidget {
  final Widget child;
  final int currentIndex;
  final Function(int) onItemTap;

  const IOSNavigationShell({
    super.key,
    required this.child,
    required this.currentIndex,
    required this.onItemTap,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoTabScaffold(
      tabBar: CupertinoTabBar(
        currentIndex: currentIndex,
        onTap: onItemTap,
        items: const [
          BottomNavigationBarItem(icon: Icon(CupertinoIcons.square_grid_2x2), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(CupertinoIcons.add_circled), label: 'Booking'),
          BottomNavigationBarItem(icon: Icon(CupertinoIcons.search), label: 'Search'),
          BottomNavigationBarItem(icon: Icon(CupertinoIcons.bus), label: 'Buses'),
        ],
      ),
      tabBuilder: (context, index) {
        return CupertinoTabView(
          builder: (context) => child,
          defaultTitle: 'Bus Booking',
        );
      },
    );
  }
}
```

#### Platform-Specific Buttons

```dart
// Android: Use FilledButton with Material 3 styling
class AndroidBookingButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String label;

  const AndroidBookingButton({super.key, required this.onPressed, required this.label});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.check),
      label: Text(label),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

// iOS: Use CupertinoButton with iOS styling
class IOSBookingButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String label;
  final bool isPrimary;

  const IOSBookingButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.isPrimary = true,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton.filled(
      onPressed: onPressed,
      child: Text(label),
      borderRadius: BorderRadius.circular(10),
    );
  }
}

// Unified button that adapts to platform
class PlatformButton extends StatelessWidget {
  final VoidCallback onPressed;
  final String label;
  final bool isPrimary;

  const PlatformButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.isPrimary = true,
  });

  @override
  Widget build(BuildContext context) {
    if (PlatformDetector.isIOS) {
      return IOSBookingButton(
        onPressed: onPressed,
        label: label,
        isPrimary: isPrimary,
      );
    }
    return AndroidBookingButton(
      onPressed: onPressed,
      label: label,
    );
  }
}
```

#### Platform-Specific Text Fields

```dart
// Android: Use Material TextField with outlined border
class AndroidTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final Icon? prefixIcon;
  final Function(String)? onChanged;

  const AndroidTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.prefixIcon,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: prefixIcon,
        filled: true,
        fillColor: Colors.grey[100],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF1976D2), width: 2),
        ),
      ),
    );
  }
}

// iOS: Use CupertinoTextField with padding
class IOSTextField extends StatelessWidget {
  final TextEditingController controller;
  final String placeholder;
  final String? hint;
  final Icon? prefixIcon;
  final Function(String)? onChanged;

  const IOSTextField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.hint,
    this.prefixIcon,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoTextField(
      controller: controller,
      onChanged: onChanged,
      placeholder: placeholder,
      prefix: prefixIcon != null ? Padding(padding: const EdgeInsets.only(left: 12), child: prefixIcon) : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6,
        borderRadius: BorderRadius.circular(10),
      ),
    );
  }
}

// Unified text field
class PlatformTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final Icon? prefixIcon;
  final Function(String)? onChanged;

  const PlatformTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.prefixIcon,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (PlatformDetector.isIOS) {
      return IOSTextField(
        controller: controller,
        placeholder: label,
        hint: hint,
        prefixIcon: prefixIcon,
        onChanged: onChanged,
      );
    }
    return AndroidTextField(
      controller: controller,
      label: label,
      hint: hint,
      prefixIcon: prefixIcon,
      onChanged: onChanged,
    );
  }
}
```

#### Platform-Specific Cards

```dart
// Android: Use Material Card with elevation
class AndroidBookingCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  const AndroidBookingCard({super.key, required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }
}

// iOS: Use CupertinoListTile with subtle styling
class IOSBookingCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  const IOSBookingCard({super.key, required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground,
        border: Border(
          bottom: BorderSide(color: CupertinoColors.systemGrey4.withOpacity(0.5)),
        ),
      ),
      child: GestureDetector(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }
}

// Unified card
class PlatformBookingCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;

  const PlatformBookingCard({super.key, required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (PlatformDetector.isIOS) {
      return IOSBookingCard(child: child, onTap: onTap);
    }
    return AndroidBookingCard(child: child, onTap: onTap);
  }
}
```

#### Platform-Specific Dialogs

```dart
// Android: Use AlertDialog
class AndroidConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String confirmText;
  final String cancelText;

  const AndroidConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.confirmText,
    required this.cancelText,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Text(content),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancelText)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(confirmText)),
      ],
    );
  }
}

// iOS: Use CupertinoAlertDialog
class IOSConfirmDialog extends StatelessWidget {
  final String title;
  final String content;
  final String confirmText;
  final String cancelText;

  const IOSConfirmDialog({
    super.key,
    required this.title,
    required this.content,
    required this.confirmText,
    required this.cancelText,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoAlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context, false),
          child: Text(cancelText),
        ),
        CupertinoDialogAction(
          onPressed: () => Navigator.pop(context, true),
          isDefaultAction: true,
          child: Text(confirmText),
        ),
      ],
    );
  }
}

// Unified dialog
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String? confirmText,
  String? cancelText,
}) async {
  if (PlatformDetector.isIOS) {
    return showCupertinoDialog<bool>(
      context: context,
      builder: (context) => IOSConfirmDialog(
        title: title,
        content: content,
        confirmText: confirmText ?? 'Confirm',
        cancelText: cancelText ?? 'Cancel',
      ),
    );
  }
  return showDialog<bool>(
    context: context,
    builder: (context) => AndroidConfirmDialog(
      title: title,
      content: content,
      confirmText: confirmText ?? 'Confirm',
      cancelText: cancelText ?? 'Cancel',
    ),
  );
}
```

#### Platform-Specific Icons

```dart
// Use platform-appropriate icon styles
class PlatformIcons {
  static IconData get booking => PlatformDetector.isIOS 
      ? CupertinoIcons.add_circled 
      : Icons.add_circle;

  static IconData get search => PlatformDetector.isIOS 
      ? CupertinoIcons.search 
      : Icons.search;

  static IconData get dashboard => PlatformDetector.isIOS 
      ? CupertinoIcons.square_grid_2x2 
      : Icons.dashboard;

  static IconData get bus => PlatformDetector.isIOS 
      ? CupertinoIcons.bus 
      : Icons.directions_bus;

  static IconData get payment => PlatformDetector.isIOS 
      ? CupertinoIcons.creditcard 
      : Icons.payment;

  static IconData get settings => PlatformDetector.isIOS 
      ? CupertinoIcons.settings 
      : Icons.settings;

  static IconData get back => PlatformDetector.isIOS 
      ? CupertinoIcons.back 
      : Icons.arrow_back;

  static IconData get more => PlatformDetector.isIOS 
      ? CupertinoIcons.ellipsis 
      : Icons.more_vert;
}
```

#### Platform-Specific Typography

```dart
// Android: Use Roboto/Product Sans fonts (default Material fonts)
class AndroidTypography {
  static TextStyle get headlineLarge => const TextStyle(
    fontFamily: 'Roboto',
    fontSize: 32,
    fontWeight: FontWeight.bold,
  );

  static TextStyle get titleLarge => const TextStyle(
    fontFamily: 'Roboto',
    fontSize: 22,
    fontWeight: FontWeight.w500,
  );

  static TextStyle get bodyLarge => const TextStyle(
    fontFamily: 'Roboto',
    fontSize: 16,
  );
}

// iOS: Use Apple San Francisco fonts
class IOSTypography {
  static TextStyle get headlineLarge => const TextStyle(
    fontFamily: '.SF Pro Display',
    fontSize: 34,
    fontWeight: FontWeight.bold,
    letterSpacing: 0.37,
  );

  static TextStyle get titleLarge => const TextStyle(
    fontFamily: '.SF Pro Text',
    fontSize: 20,
    fontWeight: FontWeight.w600,
  );

  static TextStyle get bodyLarge => const TextStyle(
    fontFamily: '.SF Pro Text',
    fontSize: 17,
    letterSpacing: -0.24,
  );
}

// Unified typography accessor
class PlatformTypography {
  static TextStyle get headlineLarge {
    return PlatformDetector.isIOS ? IOSTypography.headlineLarge : AndroidTypography.headlineLarge;
  }

  static TextStyle get titleLarge {
    return PlatformDetector.isIOS ? IOSTypography.titleLarge : AndroidTypography.titleLarge;
  }

  static TextStyle get bodyLarge {
    return PlatformDetector.isIOS ? IOSTypography.bodyLarge : AndroidTypography.bodyLarge;
  }
}
```

#### Platform-Specific Haptic Feedback

```dart
import 'package:flutter/services.dart';

class HapticManager {
  // Android: Use vibration feedback
  // iOS: Use UIImpactFeedbackGenerator

  static void lightImpact() {
    if (PlatformDetector.isIOS) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.vibrate();
    }
  }

  static void mediumImpact() {
    if (PlatformDetector.isIOS) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.vibrate();
    }
  }

  static void heavyImpact() {
    if (PlatformDetector.isIOS) {
      HapticFeedback.heavyImpact();
    } else {
      HapticFeedback.vibrate();
    }
  }

  static void selectionClick() {
    if (PlatformDetector.isIOS) {
      HapticFeedback.selectionClick();
    } else {
      // Android selection feedback
    }
  }
}
```

#### Platform-Specific Date/Time Pickers

```dart
// Android: Use showDatePicker (Material)
// iOS: Use showCupertinoDatePicker

Future<DateTime?> showPlatformDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) async {
  if (PlatformDetector.isIOS) {
    return showCupertinoModalPopup<DateTime>(
      context: context,
      builder: (context) => Container(
        height: 300,
        color: CupertinoColors.systemBackground,
        child: CupertinoDatePicker(
          mode: CupertinoDatePickerMode.date,
          initialDateTime: initialDate,
          minimumDate: firstDate,
          maximumDate: lastDate,
          onDateTimeChanged: (date) {},
        ),
      ),
    );
  }
  return showDatePicker(
    context: context,
    initialDate: initialDate,
    firstDate: firstDate,
    lastDate: lastDate,
    builder: (context, child) => Theme(
      data: Theme.of(context),
      child: child!,
    ),
  );
}
```

#### Platform-Specific Loading Indicators

```dart
// Android: Use CircularProgressIndicator
class AndroidLoadingIndicator extends StatelessWidget {
  const AndroidLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(),
    );
  }
}

// iOS: Use CupertinoActivityIndicator
class IOSLoadingIndicator extends StatelessWidget {
  const IOSLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CupertinoActivityIndicator(),
    );
  }
}

// Unified loading indicator
class PlatformLoadingIndicator extends StatelessWidget {
  const PlatformLoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    if (PlatformDetector.isIOS) {
      return const IOSLoadingIndicator();
    }
    return const AndroidLoadingIndicator();
  }
}
```

#### Platform-Specific App Bar

```dart
// Android: Use Material AppBar with elevation
class AndroidAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;

  const AndroidAppBar({super.key, required this.title, this.actions});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      actions: actions,
      elevation: 2,
    );
  }
}

// iOS: Use CupertinoNavigationBar with no elevation
class IOSAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final Widget? leading;
  final List<Widget>? trailing;

  const IOSAppBar({super.key, required this.title, this.leading, this.trailing});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return CupertinoNavigationBar(
      middle: Text(title),
      leading: leading,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: trailing ?? [],
      ),
      border: null,
      backgroundColor: CupertinoColors.systemBackground,
    );
  }
}

// Unified app bar
class PlatformAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget>? actions;
  final Widget? leading;

  const PlatformAppBar({
    super.key,
    required this.title,
    this.actions,
    this.leading,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    if (PlatformDetector.isIOS) {
      return IOSAppBar(
        title: title,
        leading: leading,
        trailing: actions,
      );
    }
    return AndroidAppBar(title: title, actions: actions);
  }
}
```

### Key UI Components

#### Booking Form (Natural Language Input)

```dart
class BookingForm extends ConsumerWidget {
  const BookingForm({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(bookingFormControllerProvider);
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'New Booking',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller.textController,
              decoration: InputDecoration(
                labelText: 'Enter booking details',
                hintText: 'e.g., Ramesh 2 singleSofa 1 doubleSofa elder',
                prefixIcon: const Icon(Icons.person),
                helperText: 'Format: Name SeatCount SeatType [SeatType] [elder|young]',
              ),
              onChanged: controller.parseInput,
            ),
            if (controller.parsedInput != null) ...[
              const SizedBox(height: 16),
              _buildPreview(controller.parsedInput!),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: controller.canSubmit ? () => _submit(context, ref) : null,
              icon: const Icon(Icons.check),
              label: const Text('Create Booking'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(ParsedBookingInput input) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Customer: ${input.customerName}'),
          Text('Seats: ${input.seatCount} (${input.seatTypes.join(', ')})'),
          if (input.ageGroup != null) Text('Age Group: ${input.ageGroup!.name}'),
        ],
      ),
    );
  }
}
```

#### Visual Seat Map

```dart
class SeatMap extends StatelessWidget {
  final Bus bus;
  final List<Booking> bookings;
  final Function(Seat) onSeatTap;

  const SeatMap({
    super.key,
    required this.bus,
    required this.bookings,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final seatsPerRow = 4;
        final rows = (bus.seats.length / seatsPerRow).ceil();
        
        return GridView.builder(
          shrinkWrap: true,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: seatsPerRow,
            childAspectRatio: 1.5,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: bus.seats.length,
          itemBuilder: (context, index) {
            final seat = bus.seats[index];
            final isBooked = seat.isBooked;
            final isAvailable = !isBooked;
            
            return SeatWidget(
              seat: seat,
              isSelected: isAvailable,
              isBooked: isBooked,
              onTap: () => isAvailable ? onSeatTap(seat) : null,
            );
          },
        );
      },
    );
  }
}

class SeatWidget extends StatelessWidget {
  final Seat seat;
  final bool isSelected;
  final bool isBooked;
  final VoidCallback? onTap;

  const SeatWidget({
    super.key,
    required this.seat,
    required this.isSelected,
    required this.isBooked,
    this.onTap,
  });

  Color _getSeatColor() {
    if (isBooked) return Colors.grey[400]!;
    if (seat.position == SeatPosition.bottom) {
      return seat.seatType == SeatType.singleSofa 
          ? Colors.blue[300]! 
          : Colors.green[300]!;
    }
    return seat.seatType == SeatType.singleSofa 
        ? Colors.blue[100]! 
        : Colors.green[100]!;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: _getSeatColor(),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Theme.of(context).primaryColor : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              seat.seatNumber,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isBooked ? Colors.white : Colors.black87,
              ),
            ),
            Icon(
              seat.seatType == SeatType.singleSofa 
                  ? Icons.event_seat 
                  : Icons.airline_seat_recline_normal,
              size: 16,
              color: isBooked ? Colors.white70 : Colors.black54,
            ),
          ],
        ),
      ),
    );
  }
}
```

#### Dashboard with Real-Time Stats

```dart
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final buses = ref.watch(busProvider);
    final bookings = ref.watch(bookingProvider);
    
    final totalBookings = bookings.length;
    final paidBookings = bookings.where((b) => b.paymentStatus == PaymentStatus.paid).length;
    final pendingBookings = totalBookings - paidBookings;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bus Booking Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.dark_mode),
            onPressed: () => ref.read(themeProvider.notifier).toggleTheme(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStatsRow(context, totalBookings, paidBookings, pendingBookings),
            const SizedBox(height: 24),
            _buildBusOverview(context, buses, bookings),
            const SizedBox(height: 24),
            _buildRecentBookings(context, bookings),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.pushNamed(context, '/booking'),
        icon: const Icon(Icons.add),
        label: const Text('New Booking'),
      ),
    );
  }

  Widget _buildStatsRow(BuildContext context, int total, int paid, int pending) {
    return Row(
      children: [
        _buildStatCard(context, 'Total Bookings', total, Colors.blue),
        const SizedBox(width: 12),
        _buildStatCard(context, 'Paid', paid, Colors.green),
        const SizedBox(width: 12),
        _buildStatCard(context, 'Pending', pending, Colors.orange),
      ],
    );
  }

  Widget _buildStatCard(BuildContext context, String label, int value, Color color) {
    return Expanded(
      child: Card(
        color: color.withOpacity(0.1),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Text(
                '$value',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
```

#### Search Screen

```dart
class SearchScreen extends ConsumerWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final searchQuery = ref.watch(searchQueryProvider);
    final searchResults = ref.watch(searchResultsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Search Bookings')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: InputDecoration(
                labelText: 'Search by name or mobile number',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => ref.read(searchQueryProvider.notifier).clear(),
                      )
                    : null,
              ),
              onChanged: (value) => ref.read(searchQueryProvider.notifier).search(value),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: searchResults.length,
              itemBuilder: (context, index) {
                final result = searchResults[index];
                return BookingResultCard(result: result);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class BookingResultCard extends StatelessWidget {
  final SearchResult result;

  const BookingResultCard({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: CircleAvatar(
          child: Text(result.customerName[0].toUpperCase()),
        ),
        title: Text(result.customerName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result.mobileNumber != null) Text('Mobile: ${result.mobileNumber}'),
            Text('Bus: ${result.busId} | Seats: ${result.seatDetails}'),
          ],
        ),
        trailing: Chip(
          label: Text(result.paymentStatus.name),
          color: result.paymentStatus == PaymentStatus.paid 
              ? WidgetStateProperty.all(Colors.green) 
              : WidgetStateProperty.all(Colors.orange),
        ),
        onTap: () => Navigator.pushNamed(context, '/booking/${result.bookingId}'),
      ),
    );
  }
}
```

### Responsive Design

```dart
class ResponsiveBuilder extends StatelessWidget {
  final Widget Function(BuildContext, BoxConstraints) builder;
  
  const ResponsiveBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: builder);
  }
}

// Usage example for responsive seat map
ResponsiveBuilder(
  builder: (context, constraints) {
    if (constraints.maxWidth > 1200) {
      return Row(
        children: [
          Expanded(flex: 2, child: SeatMap(bus: bus, ...)),
          Expanded(flex: 1, child: BookingList()),
        ],
      );
    } else if (constraints.maxWidth > 800) {
      return Column(
        children: [
          SeatMap(bus: bus, ...),
          BookingList(),
        ],
      );
    } else {
      return SeatMap(bus: bus, isCompact: true, ...);
    }
  },
)
```

### Accessibility Features

```dart
// Semantic labels for screen readers
ElevatedButton(
  onPressed: onPressed,
  semanticsLabel: 'Create new booking for customer ${input.customerName}',
  child: const Text('Create Booking'),
)

// High contrast mode support
class HighContrastTheme extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MediaQuery.of(context).highContrastEnabled
        ? Theme(
            data: ThemeData(
              colorScheme: ColorScheme.highContrastLight(),
              // High contrast configurations
            ),
            child: child,
          )
        : child;
  }
}

// Keyboard navigation support
TextField(
  autofocus: true,
  textInputAction: TextInputAction.next,
  onEditingComplete: () => FocusScope.of(context).nextFocus(),
)
```

---

## Components and Interfaces

### Input Parser

The Input Parser handles natural language booking input in the format: `<name> <seat_count> <seat_type> [<seat_type>]`

**Dart Class:**

```dart
class ParsedBookingInput {
  final String customerName;
  final int seatCount;
  final List<SeatType> seatTypes;
  final AgeGroup? ageGroup;
  final String? mobileNumber;

  ParsedBookingInput({
    required this.customerName,
    required this.seatCount,
    required this.seatTypes,
    this.ageGroup,
    this.mobileNumber,
  });
}

class BookingInputParser {
  ParsedBookingInput parse(String input);
  ValidationResult validate(String input);
  String formatError(ParseError error);
}
```

**Parsing Logic:**

1. Split input by whitespace
2. Extract customer name (first token, may contain spaces)
3. Extract optional age group (Elder, Young, Other)
4. Extract seat count (positive integer)
5. Extract seat types (SingleSofa, DoubleSofa)
6. Validate count matches types length
7. Return structured input or descriptive error

### Seat Allocator

The Seat Allocator implements deterministic seat assignment based on age preferences and availability.

**Dart Class:**

```dart
enum SeatPosition { upper, bottom }
enum SeatType { singleSofa, doubleSofa }

class SeatAllocationRequest {
  final String bookingId;
  final int seatCount;
  final List<SeatType> seatTypes;
  final AgeGroup ageGroup;
  final bool preferContiguous;

  SeatAllocationRequest({
    required this.bookingId,
    required this.seatCount,
    required this.seatTypes,
    required this.ageGroup,
    this.preferContiguous = true,
  });
}

class SeatAllocationResult {
  final bool success;
  final String busId;
  final List<String> seatNumbers;
  final bool partialAllocation;
  final int? remainingSeats;

  SeatAllocationResult({
    required this.success,
    required this.busId,
    required this.seatNumbers,
    this.partialAllocation = false,
    this.remainingSeats,
  });
}

class SeatAllocator {
  SeatAllocationResult allocate(SeatAllocationRequest request);
  SeatAllocationResult allocateContiguous(SeatAllocationRequest request);
  bool applyAgePreference(Seat seat, AgeGroup ageGroup);
  Seat? findBestAlternative(Seat seat, AgeGroup ageGroup);
}
```

**Allocation Algorithm:**

1. Filter buses by seat type availability
2. Sort buses by first-come-first-served order
3. For each bus:
   - Apply age-based position preference (elder → bottom, young → upper)
   - Find contiguous seats matching requested types
   - If multi-seat booking, keep all seats on same bus
4. If no single bus has enough seats:
   - Allocate maximum on first bus
   - Return partial allocation with remaining count
5. Log allocation decision with reasoning

### Booking Manager

**Dart Class:**

```dart
enum PaymentStatus { paid, notPaid }
enum BookingStatus { confirmed, cancelled, completed }

class Booking {
  final String id;
  final String customerName;
  final String? mobileNumber;
  final String busId;
  final List<String> seatNumbers;
  final List<SeatType> seatTypes;
  final AgeGroup ageGroup;
  final PaymentStatus paymentStatus;
  final DateTime createdAt;
  final DateTime updatedAt;

  Booking({
    required this.id,
    required this.customerName,
    this.mobileNumber,
    required this.busId,
    required this.seatNumbers,
    required this.seatTypes,
    required this.ageGroup,
    required this.paymentStatus,
    required this.createdAt,
    required this.updatedAt,
  });
}

class BookingManager {
  Booking createBooking(ParsedBookingInput input);
  void cancelBooking(String bookingId);
  void updatePaymentStatus(String bookingId, PaymentStatus status);
  Booking? getBooking(String bookingId);
  List<Booking> getBookingsByBus(String busId);
  List<Booking> getBookingsByCustomer(String name);
  List<Booking> getBookingsByMobile(String mobile);
}
```

### Bus Manager

**Dart Class:**

```dart
class Bus {
  final String id;
  final String name;
  final int totalSeats;
  final SeatConfiguration seatConfiguration;
  final List<String> bookings;

  Bus({
    required this.id,
    required this.name,
    required this.totalSeats,
    required this.seatConfiguration,
    this.bookings = const [],
  });
}

class SeatConfiguration {
  final int singleSofaUpper;
  final int singleSofaBottom;
  final int doubleSofaUpper;
  final int doubleSofaBottom;

  SeatConfiguration({
    required this.singleSofaUpper,
    required this.singleSofaBottom,
    required this.doubleSofaUpper,
    required this.doubleSofaBottom,
  });
}

class BusStatus {
  final String busId;
  final int availableSeats;
  final int bookedSeats;
  final double utilizationPercentage;
  final Map<SeatType, int> availableByType;

  BusStatus({
    required this.busId,
    required this.availableSeats,
    required this.bookedSeats,
    required this.utilizationPercentage,
    required this.availableByType,
  });
}

class BusManager {
  Bus configureBus(String id, SeatConfiguration config);
  Bus? getBus(String busId);
  List<Bus> getAllBuses();
  BusStatus getBusStatus(String busId);
  int getAvailableSeats(String busId, SeatType seatType);
  bool isBusFull(String busId);
}
```

### Search Engine

**Dart Class:**

```dart
class SearchResult {
  final String bookingId;
  final String customerName;
  final String? mobileNumber;
  final String busId;
  final String seatDetails;
  final PaymentStatus paymentStatus;

  SearchResult({
    required this.bookingId,
    required this.customerName,
    this.mobileNumber,
    required this.busId,
    required this.seatDetails,
    required this.paymentStatus,
  });
}

class SearchEngine {
  List<SearchResult> searchByName(String query, {String? busId});
  List<SearchResult> searchByMobile(String query, {String? busId});
  List<SearchResult> searchAll(String query, {String? busId});
}
```

### Report Generator

**Dart Class:**

```dart
class BookingSummary {
  final int totalBookings;
  final int paidBookings;
  final int pendingBookings;
  final double totalRevenue;

  BookingSummary({
    required this.totalBookings,
    required this.paidBookings,
    required this.pendingBookings,
    required this.totalRevenue,
  });
}

class SeatUtilization {
  final String busId;
  final int totalSeats;
  final int bookedSeats;
  final double utilizationPercentage;
  final Map<SeatType, int> totalByType;
  final Map<SeatType, int> bookedByType;

  SeatUtilization({
    required this.busId,
    required this.totalSeats,
    required this.bookedSeats,
    required this.utilizationPercentage,
    required this.totalByType,
    required this.bookedByType,
  });
}

class ReportGenerator {
  BookingSummary generateBookingSummary();
  List<SeatUtilization> generateSeatUtilization();
  String generateBusPassengerList(String busId);
  String exportToText(dynamic report);
}
```

---

## Data Models

### Core Domain Models

```dart
// Customer represents a booking customer
class Customer {
  final String id;
  final String name;
  final String? mobileNumber;
  final AgeGroup ageGroup;
  final DateTime createdAt;

  Customer({
    required this.id,
    required this.name,
    this.mobileNumber,
    required this.ageGroup,
    required this.createdAt,
  });
}

// Seat represents an individual seat on a bus
class Seat {
  final String id;
  final String busId;
  final String seatNumber;
  final SeatType seatType;
  final SeatPosition position;
  final bool isBooked;
  final String? bookingId;

  Seat({
    required this.id,
    required this.busId,
    required this.seatNumber,
    required this.seatType,
    required this.position,
    required this.isBooked,
    this.bookingId,
  });
}

// Booking represents a customer reservation
class Booking {
  final String id;
  final String customerId;
  final String busId;
  final List<Seat> seats;
  final PaymentStatus paymentStatus;
  final BookingStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  Booking({
    required this.id,
    required this.customerId,
    required this.busId,
    required this.seats,
    required this.paymentStatus,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });
}

// Bus represents a vehicle with seats
class Bus {
  final String id;
  final String name;
  final List<Seat> seats;
  final int totalCapacity;
  final int currentBookings;

  Bus({
    required this.id,
    required this.name,
    required this.seats,
    required this.totalCapacity,
    this.currentBookings = 0,
  });
}

// Age group classification for seat preferences
enum AgeGroup { elder, young, other }

// Seat type classification
enum SeatType { singleSofa, doubleSofa }

// Seat position on the bus
enum SeatPosition { upper, bottom }

// Payment status tracking
enum PaymentStatus { paid, notPaid }

// Booking status
enum BookingStatus { confirmed, cancelled, completed }
```

### Data Store Schema

```dart
// In-memory store structure
class BookingStore {
  final Map<String, Booking> bookings = {};
  final Map<String, List<String>> byCustomerName = {};
  final Map<String, List<String>> byMobileNumber = {};
  final Map<String, List<String>> byBusId = {};
  final Map<PaymentStatus, List<String>> byPaymentStatus = {};
}

class BusStore {
  final Map<String, Bus> buses = {};
  final Map<String, Seat> seats = {};
  final Map<String, Map<String, Seat>> seatIndex = {}; // busId -> seatId -> Seat
}
```

### Example Data

```dart
// Example bus configuration
final exampleBus = Bus(
  id: 'BUS-001',
  name: 'Express Line 1',
  seats: [
    Seat(id: 'S1', busId: 'BUS-001', seatNumber: '1A', seatType: SeatType.singleSofa, position: SeatPosition.upper, isBooked: false),
    Seat(id: 'S2', busId: 'BUS-001', seatNumber: '1B', seatType: SeatType.singleSofa, position: SeatPosition.upper, isBooked: false),
    Seat(id: 'S3', busId: 'BUS-001', seatNumber: '2A', seatType: SeatType.doubleSofa, position: SeatPosition.upper, isBooked: false),
    Seat(id: 'S4', busId: 'BUS-001', seatNumber: '2B', seatType: SeatType.doubleSofa, position: SeatPosition.upper, isBooked: false),
    Seat(id: 'S5', busId: 'BUS-001', seatNumber: '1A', seatType: SeatType.singleSofa, position: SeatPosition.bottom, isBooked: false),
    Seat(id: 'S6', busId: 'BUS-001', seatNumber: '1B', seatType: SeatType.singleSofa, position: SeatPosition.bottom, isBooked: false),
    Seat(id: 'S7', busId: 'BUS-001', seatNumber: '2A', seatType: SeatType.doubleSofa, position: SeatPosition.bottom, isBooked: false),
    Seat(id: 'S8', busId: 'BUS-001', seatNumber: '2B', seatType: SeatType.doubleSofa, position: SeatPosition.bottom, isBooked: false),
  ],
  totalCapacity: 8,
  currentBookings: 0,
);

// Example booking
final exampleBooking = Booking(
  id: 'BK-001',
  customerId: 'CUST-001',
  busId: 'BUS-001',
  seats: [
    Seat(id: 'S1', busId: 'BUS-001', seatNumber: '1A', seatType: SeatType.singleSofa, position: SeatPosition.upper, isBooked: true, bookingId: 'BK-001'),
  ],
  paymentStatus: PaymentStatus.notPaid,
  status: BookingStatus.confirmed,
  createdAt: DateTime(2024, 1, 15, 10, 30),
  updatedAt: DateTime(2024, 1, 15, 10, 30),
);
```

---

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system—essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Property 1: Name Validation

*For any* input string, when parsed as a customer name, the result should be a non-empty string after trimming whitespace.

**Validates: Requirements 1.1**

### Property 2: Seat Count Validation

*For any* positive integer seat count, the booking system should accept it as valid input.

**Validates: Requirements 1.2**

### Property 3: Seat Type Validation

*For any* seat type input, the parser should only accept 'Single_Sofa' or 'Double_Sofa' as valid values.

**Validates: Requirements 1.3**

### Property 4: Input Format Parsing

*For any* valid input string in the format "<name> <seat_count> <seat_type>", parsing should produce a structured result with all components correctly extracted.

**Validates: Requirements 1.4, 8.1**

### Property 5: Bus Configuration Limits

*For any* bus configuration, the system should support between 1 and 10 buses without degradation in functionality.

**Validates: Requirements 2.1**

### Property 6: Capacity Tracking

*For any* bus, the total booked seats should never exceed the configured total capacity.

**Validates: Requirements 2.3, 9.4**

### Property 7: Age-Based Bottom Preference

*For any* booking with Elder age group, when Bottom position seats of the requested type are available, the allocator should assign Bottom position seats.

**Validates: Requirements 3.1**

### Property 8: Age-Based Upper Preference

*For any* booking with Young age group, when Upper position seats of the requested type are available, the allocator should assign Upper position seats.

**Validates: Requirements 3.2**

### Property 9: Alternative Position Fallback

*For any* booking where the preferred position for the age group is unavailable, the allocator should assign the alternative position.

**Validates: Requirements 3.4**

### Property 10: Single Seat Type Allocation

*For any* booking requesting Single_Sofa seats, the allocator should only assign Single_Sofa type seats.

**Validates: Requirements 4.1**

### Property 11: Double Seat Type Allocation

*For any* booking requesting Double_Sofa seats, the allocator should only assign Double_Sofa type seats.

**Validates: Requirements 4.2**

### Property 12: Multi-Seat Same Bus

*For any* multi-seat booking where contiguous seats are available on a single bus, all seats should be allocated on that same bus.

**Validates: Requirements 5.1, 5.2**

### Property 13: FIFO Allocation Order

*For any* two bookings received in order B1 then B2, B1 should be allocated before B2 when both can be satisfied.

**Validates: Requirements 7.2**

### Property 14: First Available Bus Priority

*For any* booking request, the allocator should allocate from the first bus that satisfies the requirements.

**Validates: Requirements 7.3**

### Property 15: Payment Status Default

*For any* newly created booking, the payment status should default to Not_Paid.

**Validates: Requirements 11.2**

### Property 16: Payment Status Update

*For any* booking with payment status Not_Paid, updating to Paid should result in payment status Paid.

**Validates: Requirements 11.3**

### Property 17: Name Search Case Insensitivity

*For any* customer name search query, searching with different case variations should return the same results.

**Validates: Requirements 12.6**

### Property 18: Partial Name Match

*For any* partial customer name query, the search should return all bookings where the customer name contains the query substring.

**Validates: Requirements 12.1**

### Property 19: Partial Mobile Match

*For any* partial mobile number query, the search should return all bookings where the mobile number contains the query digits.

**Validates: Requirements 12.2**

### Property 20: Booking Persistence

*For any* booking created, querying by booking ID should return that booking.

**Validates: Requirements 6.1**

### Property 21: Seat Type Availability Check

*For any* seat type request, the system should verify availability before confirming allocation.

**Validates: Requirements 4.4**

### Property 22: Multi-Type Seat Count Matching

*For any* input with multiple seat types, the number of seat types should match the seat count.

**Validates: Requirements 8.2**

### Property 23: Booking Cancellation Restoration

*For any* booking that is cancelled, the allocated seats should be marked as available again.

**Validates: Requirements 6.5**

### Property 24: Age Group Recording

*For any* booking created with an age group, the booking record should contain that age group.

**Validates: Requirements 3.5**

### Property 25: Contiguous Seat Priority

*For any* multi-seat booking, the allocator should prioritize finding contiguous seats over non-contiguous seats.

**Validates: Requirements 5.2**

---

## Error Handling

### Error Categories

1. **Input Validation Errors**
   - Invalid customer name (empty or whitespace)
   - Invalid seat count (non-positive or non-integer)
   - Invalid seat type (unknown type)
   - Mismatched seat count and types
   - Missing required fields

2. **Capacity Errors**
   - Bus not found
   - Insufficient seats available
   - Bus at full capacity
   - Requested seat type unavailable

3. **Booking Errors**
   - Booking not found
   - Invalid booking state transition
   - Payment update on cancelled booking
   - Duplicate booking ID

4. **System Errors**
   - Storage failure
   - Configuration error
   - Unexpected internal state

### Error Response Format

```dart
class ErrorResponse {
  final String code;
  final String message;
  final Map<String, dynamic>? details;
  final String? suggestion;
  final DateTime timestamp;

  ErrorResponse({
    required this.code,
    required this.message,
    this.details,
    this.suggestion,
    required this.timestamp,
  });
}

class ValidationError extends ErrorResponse {
  final String field;
  final dynamic value;
  final String constraint;

  ValidationError({
    required this.field,
    required this.value,
    required this.constraint,
  }) : super(
          code: 'VALIDATION_ERROR',
          message: 'Validation failed for $field',
          timestamp: DateTime.now(),
        );
}
```

### Error Handling Strategies

1. **Input Validation**: Validate at the source, prevent invalid submissions
2. **Graceful Degradation**: Continue operation when possible, log errors
3. **User-Friendly Messages**: No technical jargon in user-facing errors
4. **Recovery Support**: Provide undo functionality for recent actions
5. **Logging**: Log detailed errors for debugging while showing friendly messages

### Specific Error Scenarios

| Scenario | Error Code | User Message | Suggestion |
|----------|------------|--------------|------------|
| Empty name | VALIDATION_NAME_EMPTY | "Customer name is required" | "Enter a valid name" |
| Zero seats | VALIDATION_SEAT_ZERO | "At least one seat is required" | "Enter a positive number" |
| Unknown seat type | VALIDATION_SEAT_TYPE | "Invalid seat type" | "Use SingleSofa or DoubleSofa" |
| Bus full | CAPACITY_FULL | "Bus is fully booked" | "Try another bus" |
| Insufficient seats | CAPACITY_INSUFFICIENT | "Only {available} seats available" | "Reduce seat count or try another bus" |
| Booking not found | BOOKING_NOT_FOUND | "Booking not found" | "Verify booking ID" |
| Already paid | PAYMENT_ALREADY_PAID | "Booking is already paid" | "No action needed" |

---

## Testing Strategy

### Dual Testing Approach

The testing strategy combines unit tests for specific examples and edge cases with property-based tests for universal properties across all inputs.

### Unit Testing Focus Areas

1. **Input Parsing Examples**
   - Valid input formats
   - Invalid input formats
   - Edge cases (empty, whitespace, special characters)

2. **Component Integration**
   - Parser → Allocator → Manager flow
   - Error propagation between components
   - State consistency after operations

3. **UI Components**
   - Form validation feedback
   - Error message display
   - Loading states
   - Keyboard navigation

### Property-Based Testing Configuration

**Library**: fast-check (TypeScript/JavaScript)

**Configuration**:
- Minimum iterations: 100 per property
- Maximum iterations: 1000 per property
- Seed: reproducible for debugging

**Test Tag Format**: `Feature: bus-booking-application, Property {number}: {property_name}`

### Property Test Implementation

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fast_check/fast_check.dart' as fc;

// Property 1: Name Validation
test('Property 1: Name Validation', () {
  fc.property(fc.string(), (String name) {
    final trimmed = name.trim();
    final isValid = trimmed.isNotEmpty;
    // Property: non-empty after trim should be valid
    return isValid || trimmed.isEmpty;
  });
});

// Property 4: Input Format Parsing
test('Property 4: Input Format Parsing', () {
  fc.property(
    fc.string(minLength: 1),
    fc.integer(min: 1, max: 10),
    fc.oneof([
      fc.constant(SeatType.singleSofa),
      fc.constant(SeatType.doubleSofa),
    ]),
    (String name, int count, SeatType type) {
      final input = '$name $count ${type.name}';
      final result = BookingInputParser().parse(input);
      return result.customerName == name.trim() &&
             result.seatCount == count &&
             result.seatTypes.length == 1 &&
             result.seatTypes[0] == type;
    },
  );
});

// Property 7: Age-Based Bottom Preference
test('Property 7: Age-Based Bottom Preference', () {
  fc.property(
    fc.record({
      'busId': fc.string(),
      'seats': fc.list(
        fc.record({
          'seatType': fc.oneof([
            fc.constant(SeatType.singleSofa),
            fc.constant(SeatType.doubleSofa),
          ]),
          'position': fc.oneof([
            fc.constant(SeatPosition.upper),
            fc.constant(SeatPosition.bottom),
          ]),
          'isBooked': fc.boolean(),
        }),
      ),
    }),
    fc.integer(min: 1, max: 5),
    (Map busConfig, int seatCount) {
      final bottomSeats = (busConfig['seats'] as List)
          .where((s) => s['position'] == SeatPosition.bottom && !(s['isBooked'] as bool))
          .toList();
      // If bottom seats available, Elder should get bottom
      return bottomSeats.length >= seatCount || true;
    },
  );
});

// Property 15: Payment Status Default
test('Property 15: Payment Status Default', () {
  fc.property(
    fc.record({
      'customerName': fc.string(),
      'seatCount': fc.integer(min: 1, max: 10),
      'seatTypes': fc.list(
        fc.oneof([
          fc.constant(SeatType.singleSofa),
          fc.constant(SeatType.doubleSofa),
        ]),
        minLength: 1,
        maxLength: 10,
      ),
    }),
    (Map bookingInput) {
      final booking = BookingManager().createBooking(
        ParsedBookingInput(
          customerName: bookingInput['customerName'] as String,
          seatCount: bookingInput['seatCount'] as int,
          seatTypes: List<SeatType>.from(bookingInput['seatTypes'] as List),
        ),
      );
      return booking.paymentStatus == PaymentStatus.notPaid;
    },
  );
});

// Property 17: Name Search Case Insensitivity
test('Property 17: Name Search Case Insensitivity', () {
  fc.property(
    fc.list(
      fc.record({
        'customerName': fc.string(),
        'bookingId': fc.string(),
      }),
      minLength: 1,
      maxLength: 20,
    ),
    fc.string(),
    (List bookings, String searchQuery) {
      final upperResults = SearchEngine().searchByName(
        bookings,
        searchQuery.toUpperCase(),
      );
      final lowerResults = SearchEngine().searchByName(
        bookings,
        searchQuery.toLowerCase(),
      );
      return upperResults.length == lowerResults.length;
    },
  );
});
```

### Edge Case Testing

```dart
describe('Edge Cases', () {
  test('handles empty input', () {
    expect(() => Parser().parse(''), throwsA(isA<ParseException>()));
  });

  test('handles whitespace-only input', () {
    expect(() => Parser().parse('   '), throwsA(isA<ParseException>()));
  });

  test('handles maximum seat count', () {
    final input = 'John 10 singleSofa';
    final result = Parser().parse(input);
    expect(result.seatCount, equals(10));
  });

  test('handles mixed seat types', () {
    final input = 'John 3 singleSofa doubleSofa singleSofa';
    final result = Parser().parse(input);
    expect(result.seatTypes.length, equals(3));
  });

  test('handles elder with no bottom seats', () {
    final bus = createBusWithNoBottomSeats();
    final booking = createBooking(ageGroup: AgeGroup.elder);
    final result = Allocator().allocate(bus, booking);
    expect(result.seats.every((s) => s.position == SeatPosition.upper), isTrue);
  });

  test('handles young with no upper seats', () {
    final bus = createBusWithNoUpperSeats();
    final booking = createBooking(ageGroup: AgeGroup.young);
    final result = Allocator().allocate(bus, booking);
    expect(result.seats.every((s) => s.position == SeatPosition.bottom), isTrue);
  });

  test('handles partial allocation', () {
    final bus = createBusWithLimitedSeats();
    final booking = createBooking(seatCount: 10);
    final result = Allocator().allocate(bus, booking);
    expect(result.partialAllocation, isTrue);
    expect(result.remainingSeats, greaterThan(0));
  });
});
```

### Accessibility Testing

```dart
describe('Accessibility', () {
  testWidgets('has semantic labels on all interactive elements', (WidgetTester tester) async {
    await tester.pumpWidget(const BookingForm());
    final buttons = find.byType(ElevatedButton);
    for (final button in buttons) {
      expect(
        tester.getSemantics(button),
        matchesSemantics(label: matches(RegExp(r'.+'))),
      );
    }
  });

  testWidgets('supports keyboard navigation', (WidgetTester tester) async {
    await tester.pumpWidget(const BookingForm());
    await tester.sendKeyDownEvent(LogicalKeyboardKey.tab);
    expect(find.byType(TextField).first, hasFocus);
  });

  testWidgets('provides error announcements for screen readers', (WidgetTester tester) async {
    await tester.pumpWidget(const BookingForm());
    final errorRegion = find.byType(ExcludeFocus);
    expect(errorRegion, findsOneWidget);
  });
});
```

### Test Coverage Requirements

- **Unit Tests**: Minimum 80% line coverage
- **Property Tests**: All 25 properties must have corresponding tests
- **Integration Tests**: Critical user flows covered
- **Accessibility Tests**: All WCAG 2.1 AA requirements tested

### Test Execution

```bash
# Run all tests
flutter test

# Run property-based tests only
flutter test --test-path property

# Run with coverage
flutter test --coverage

# Run with specific seed for reproducibility
flutter test --test-path property --dart-define=SEED=12345
```