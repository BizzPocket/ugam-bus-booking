# Implementation Plan: Bus Booking Application

## Overview

This implementation plan converts the feature design into a series of prompts for a code-generation LLM that will implement each step with incremental progress. Each prompt builds on the previous prompts and ends with wiring things together. There is no hanging or orphaned code that isn't integrated into a previous step. The implementation uses Dart with Flutter framework and Riverpod for state management.

## Tasks

- [x] 1. Set up Flutter project structure and core configuration
  - Create Flutter project with `flutter create bus_booking_app`
  - Set up directory structure: lib/models, lib/services, lib/providers, lib/screens, lib/components, lib/utils
  - Add dependencies to pubspec.yaml: riverpod, flutter_riverpod, uuid, intl
  - Create main.dart with MaterialApp initialization
  - Create app.dart with app configuration and providers scope
  - Create theme.dart with Material Design 3 light and dark themes
  - _Requirements: 13.1, 13.4, 13.9_

- [x] 2. Implement core data models
  - [x] 2.1 Create enums (AgeGroup, SeatType, SeatPosition, PaymentStatus, BookingStatus)
    - Define AgeGroup enum with elder, young, other values
    - Define SeatType enum with singleSofa, doubleSofa values
    - Define SeatPosition enum with upper, bottom values
    - Define PaymentStatus enum with paid, notPaid values
    - Define BookingStatus enum with confirmed, cancelled, completed values
    - _Requirements: 1.3, 3.5, 4.1, 4.2, 11.1_

  - [x] 2.2 Create Seat model class
    - Define Seat with id, busId, seatNumber, seatType, position, isBooked, bookingId
    - Implement copyWith method for immutable updates
    - Add equality operators for comparison
    - _Requirements: 4.1, 4.2, 9.1, 9.2, 9.3_

  - [x] 2.3 Create Bus model class
    - Define Bus with id, name, seats list, totalCapacity, currentBookings
    - Implement SeatConfiguration as separate class for bus setup
    - Add methods to calculate available seats by type
    - _Requirements: 2.1, 2.3, 9.1, 9.2, 9.3_

  - [x] 2.4 Create Customer model class
    - Define Customer with id, name, mobileNumber, ageGroup, createdAt
    - Implement validation for required fields
    - _Requirements: 1.1, 3.5, 12.1, 12.2_

  - [x] 2.5 Create Booking model class
    - Define Booking with id, customerId, busId, seats list, paymentStatus, status, createdAt, updatedAt
    - Implement copyWith for status updates
    - Add factory constructor for creating new bookings
    - _Requirements: 1.5, 6.1, 11.1, 11.2, 11.3_

- [x] 3. Implement input parsing service
  - [x] 3.1 Create ParsedBookingInput class
    - Define fields: customerName, seatCount, seatTypes, ageGroup, mobileNumber
    - Add validation methods for input fields
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 8.1, 8.5_

  - [x] 3.2 Implement BookingInputParser service
    - Parse natural language input: "<name> <seat_count> <seat_type> [<seat_type>]"
    - Handle optional age group: "<name> [elder|young|other] <seat_count> <seat_type>"
    - Implement whitespace and casing normalization
    - Return descriptive error messages for invalid input
    - _Requirements: 1.4, 8.1, 8.2, 8.3, 8.4_

  - [x] 3.3 Implement ValidationResult and ParseError classes
    - Define ValidationResult with isValid and errorMessage fields
    - Define ParseError enum with error types
    - Create formatError method for user-friendly messages
    - _Requirements: 8.4, 17.1, 17.3_

- [x] 4. Implement seat allocation service
  - [x] 4.1 Create SeatAllocationRequest and SeatAllocationResult classes
    - Define SeatAllocationRequest with bookingId, seatCount, seatTypes, ageGroup, preferContiguous
    - Define SeatAllocationResult with success, busId, seatNumbers, partialAllocation, remainingSeats
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3_

  - [x] 4.2 Implement SeatAllocator core allocation logic
    - Filter buses by seat type availability
    - Apply age-based position preference (elder → bottom, young → upper)
    - Find contiguous seats matching requested types
    - Implement FIFO booking order processing
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 7.1, 7.2, 7.3_

  - [x] 4.3 Implement multi-seat booking logic
    - Keep all seats for same customer on same bus
    - Handle partial allocation when bus capacity insufficient
    - Log allocation decisions with reasoning
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7_

  - [x] 4.4 Implement best alternative selection
    - Find alternative seat when preferred unavailable
    - Apply fallback rules for age groups
    - Return clear error when no seats available
    - _Requirements: 3.4, 4.5, 7.5_

- [x] 5. Implement bus management service
  - [x] 5.1 Create BusManager class
    - Implement configureBus method with SeatConfiguration
    - Implement getBus, getAllBuses methods
    - Implement getBusStatus for capacity tracking
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5_

  - [x] 5.2 Implement BusStatus and SeatUtilization classes
    - Define BusStatus with availableSeats, bookedSeats, utilizationPercentage, availableByType
    - Define SeatUtilization with totalByType, bookedByType calculations
    - _Requirements: 2.5, 10.2_

  - [x] 5.3 Implement capacity validation
    - Check seat availability before booking
    - Prevent bookings exceeding total bus capacity
    - Provide real-time capacity updates
    - _Requirements: 9.4, 9.5_

- [x] 6. Implement booking management service
  - [x] 6.1 Create BookingManager class
    - Implement createBooking with ParsedBookingInput
    - Implement cancelBooking with seat release
    - Implement updatePaymentStatus method
    - _Requirements: 1.5, 6.5, 11.3_

  - [x] 6.2 Implement booking query methods
    - getBooking by bookingId
    - getBookingsByBus by bus identifier
    - getBookingsByCustomer by customer name
    - _Requirements: 6.2, 6.3, 6.4_

  - [x] 6.3 Implement payment tracking
    - Default payment status to Not_Paid on creation
    - Support status update from Not_Paid to Paid
    - Handle refund status on cancellation
    - _Requirements: 11.2, 11.3, 11.6_

- [x] 7. Implement search service
  - [x] 7.1 Create SearchResult class
    - Define fields: bookingId, customerName, mobileNumber, busId, seatDetails, paymentStatus
    - _Requirements: 12.5_

  - [x] 7.2 Implement SearchEngine class
    - searchByName with partial and full match support
    - searchByMobile with partial and full match support
    - searchAll combined search across all buses
    - Implement case-insensitive name matching
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.6_

- [x] 8. Implement report generation service
  - [x] 8.1 Create BookingSummary class
    - Define fields: totalBookings, paidBookings, pendingBookings, totalRevenue
    - _Requirements: 10.1, 10.5_

  - [x] 8.2 Implement ReportGenerator class
    - generateBookingSummary method
    - generateSeatUtilization method
    - generateBusPassengerList method
    - exportToText for readable format
    - _Requirements: 10.1, 10.2, 10.3, 10.4_

- [x] 9. Set up GetX state management
  - [x] 9.1 Create booking_controller.dart
    - Implement BookingController with GetX reactive state
    - Add createBooking, updatePaymentStatus, cancelBooking methods
    - Use .obs for reactive lists
    - Add Get.snackbar for success/error feedback
    - _Requirements: 6.1, 11.3, 11.4_

  - [x] 9.2 Create bus_controller.dart
    - Implement BusController with GetX reactive state
    - Add configureBus, getBusStatus, getAvailableBuses methods
    - Use .obs for reactive lists
    - _Requirements: 2.2, 2.5_

  - [x] 9.3 Create theme_controller.dart
    - Implement ThemeController for light/dark mode toggle
    - Use Get.changeThemeMode for theme switching
    - Persist theme preference
    - _Requirements: 13.9_

  - [x] 9.4 Create search_controller.dart
    - Implement SearchController with reactive search state
    - Add search, clearSearch methods with debounce
    - Use .obs for search query and results
    - _Requirements: 12.1, 12.2, 12.3_

  - [x] 9.5 Create app_binding.dart
    - Implement AppBinding for dependency injection
    - Use Get.lazyPut for all controllers and services
    - Register all services: BookingService, BusService, SeatAllocator, etc.
    - _Requirements: All_

  - [x] 9.6 Configure app_routes.dart
    - Define AppRoutes class with route constants
    - Create GetPage routes for all screens
    - Add binding to each route
    - _Requirements: All_

- [x] 10. Implement utility classes

- [x] 10. Implement utility classes
  - [x] 10.1 Create constants.dart
    - Define app constants (maxBuses, defaultSeatConfiguration)
    - Add regex patterns for validation
    - _Requirements: 2.1_

  - [x] 10.2 Create validators.dart
    - Implement name validation (non-empty string)
    - Implement seat count validation (positive integer)
    - Implement seat type validation
    - _Requirements: 1.1, 1.2, 1.3_

  - [x] 10.3 Create formatters.dart
    - Format date/time for display
    - Format seat details for reports
    - Format currency for revenue display
    - _Requirements: 10.4_

- [x] 11. Build UI components
  - [x] 11.1 Create platform_detector.dart
    - Implement PlatformDetector utility for platform detection
    - Add isAndroid, isIOS, isMobile, isWeb getters
    - _Requirements: 13.1, 13.2_

  - [x] 11.2 Create platform_navigation.dart
    - Implement AndroidNavigationShell with Drawer + NavigationBar
    - Implement IOSNavigationShell with CupertinoTabScaffold
    - Create unified navigation shell that adapts to platform
    - _Requirements: 13.1, 13.2_

  - [x] 11.3 Create platform_button.dart
    - Implement AndroidBookingButton with Material 3 FilledButton
    - Implement IOSBookingButton with CupertinoButton
    - Create unified PlatformButton widget
    - _Requirements: 13.1, 13.2_

  - [x] 11.4 Create platform_text_field.dart
    - Implement AndroidTextField with Material styling
    - Implement IOSTextField with Cupertino styling
    - Create unified PlatformTextField widget
    - _Requirements: 13.1, 13.2_

  - [x] 11.5 Create platform_card.dart
    - Implement AndroidBookingCard with elevation and InkWell
    - Implement IOSBookingCard with CupertinoListTile styling
    - Create unified PlatformBookingCard widget
    - _Requirements: 13.1, 13.2_

  - [x] 11.6 Create platform_dialog.dart
    - Implement AndroidConfirmDialog with AlertDialog
    - Implement IOSConfirmDialog with CupertinoAlertDialog
    - Create showConfirmDialog function with platform detection
    - _Requirements: 13.1, 13.2, 14.9_

  - [x] 11.7 Create platform_icons.dart
    - Define PlatformIcons class with platform-specific icon mappings
    - Provide consistent icon mapping for booking, search, dashboard, bus
    - _Requirements: 13.1, 13.2_

  - [x] 11.8 Create platform_typography.dart
    - Define AndroidTypography with Roboto fonts
    - Define IOSTypography with SF Pro fonts
    - Create unified PlatformTypography accessor
    - _Requirements: 13.1, 13.2, 13.10_

  - [x] 11.9 Create haptic_manager.dart
    - Implement HapticManager for platform-specific feedback
    - Add lightImpact, mediumImpact, heavyImpact, selectionClick methods
    - _Requirements: 13.1, 13.2_

  - [x] 11.10 Create platform_app_bar.dart
    - Implement AndroidAppBar with elevation
    - Implement IOSAppBar with CupertinoNavigationBar
    - Create unified PlatformAppBar widget
    - _Requirements: 13.1, 13.2_

  - [x] 11.11 Create booking_form.dart
    - Implement natural language input field
    - Add real-time parsing and preview
    - Show validation errors with suggestions
    - Support autocomplete for customer names
    - Use PlatformTextField for platform-adaptive input
    - _Requirements: 14.1, 14.2, 14.3, 14.4, 14.5, 14.6_

  - [x] 11.12 Create seat_map.dart visual component
    - Implement SeatWidget with color coding by type and position
    - Show booked vs available seats
    - Add tap handler for seat selection
    - Make responsive for different screen sizes
    - _Requirements: 15.3_

  - [x] 11.13 Create bus_card.dart
    - Display bus status with available/booked seats
    - Show utilization percentage
    - Add quick action buttons
    - Use PlatformCard for consistent styling
    - _Requirements: 2.5, 15.1, 15.6_

  - [x] 11.14 Create search_bar.dart
    - Implement search input with clear button
    - Add focus management for keyboard navigation
    - Show loading indicator during search
    - Use PlatformTextField for platform-adaptive input
    - _Requirements: 14.7, 14.8_

  - [x] 11.15 Create payment_toggle.dart
    - One-click payment status toggle
    - Visual feedback for status change
    - Use showConfirmDialog for destructive actions
    - Add haptic feedback on toggle
    - _Requirements: 14.7, 14.9, 14.10_

  - [x] 11.16 Create booking_list.dart
    - Display bookings with all details
    - Support sorting and filtering
    - Add swipe actions for quick operations
    - Use PlatformCard for consistent styling
    - _Requirements: 6.1, 6.2, 6.3_

- [x] 12. Build main screens
  - [x] 12.1 Create dashboard_screen.dart
    - Display stats overview (total, paid, pending bookings)
    - Show bus availability overview
    - Display recent booking activity
    - Add quick action buttons
    - Show alerts for low availability
    - _Requirements: 15.1, 15.2, 15.4, 15.5, 15.6_

  - [x] 12.2 Create booking_screen.dart
    - Integrate BookingForm component
    - Show seat map preview
    - Display booking confirmation
    - Handle booking submission
    - _Requirements: 1.1, 1.2, 1.3, 14.5_

  - [x] 12.3 Create search_screen.dart
    - Integrate SearchBar component
    - Display search results with BookingResultCard
    - Handle result tap for details view
    - Support filtering by bus
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5_

  - [x] 12.4 Create bus_list_screen.dart
    - Display all configured buses
    - Show bus status and capacity
    - Allow bus configuration
    - _Requirements: 2.1, 2.5, 9.1, 9.2, 9.3_

  - [x] 12.5 Create report_screen.dart
    - Display booking summary
    - Show seat utilization charts
    - List bus passenger details
    - Support export to text format
- [x] 13. Implement accessibility features
  - [x] 13.1 Ensure semantic structure
    - Wrap complex custom widgets in Semantics
    - Provide custom semantic labels where needed
    - _Requirements: 16.1_

  - [x] 13.2 Implement keyboard navigation
    - Set autofocus on first input field
    - Configure textInputAction for proper focus flow
    - Add keyboard shortcuts for common actions
    - _Requirements: 16.3, 16.10_

  - [x] 13.3 Add high contrast theme support
    - Detect high contrast mode
    - Provide high contrast color scheme
    - Ensure sufficient color contrast ratios
    - _Requirements: 16.4_

  - [x] 13.4 Implement RTL support
    - Add RTL text direction support
    - Mirror layout for RTL locales
    - _Requirements: 16.7_

  - [x] 13.5 Add tooltips and help text
    - Add Tooltip to all icon buttons
    - Add helper text to form fields
    - Provide contextual help for each input
    - _Requirements: 16.8_

  - [x] 13.6 Make error states distinguishable
    - Add icons to error messages
    - Use patterns/textures in addition to color
    - Ensure error text is readable
    - _Requirements: 16.9_

- [x] 14. Set up testing framework
  - [x] 14.1 Configure test directory structure
    - Create test/ directory with models, services, providers, widgets subdirectories
    - Add test helper files
    - Configure test coverage
    - _Requirements: All_

  - [x] 14.2 Set up property-based testing with fast_check
    - Add fast_check dependency
    - Create property test utilities
    - Configure test generators for all model types
    - _Requirements: All_

- [x] 15. Write unit tests for models
  - [x] 15.1 Write unit tests for Seat model
    - Test copyWith method
    - Test equality comparison
    - Test seat type and position accessors
    - _Requirements: 4.1, 4.2_

  - [x] 15.2 Write unit tests for Bus model
    - Test seat configuration
    - Test capacity calculations
    - Test available seat counting
    - _Requirements: 2.3, 9.1, 9.2, 9.3_

  - [x] 15.3 Write unit tests for Customer model
    - Test required field validation
    - Test age group assignment
    - _Requirements: 1.1, 3.5_

  - [x] 15.4 Write unit tests for Booking model
    - Test copyWith for status updates
    - Test payment status defaults
    - Test timestamp handling
    - _Requirements: 1.5, 6.1, 11.1, 11.2_

- [x] 16. Write unit tests for services
  - [x] 16.1 Write unit tests for BookingInputParser
    - Test valid input parsing
    - Test error handling for invalid input
    - Test whitespace and casing normalization
    - Test mixed seat type parsing
    - _Requirements: 1.4, 8.1, 8.2, 8.3, 8.4_

  - [x] 16.2 Write unit tests for SeatAllocator
    - Test age-based preference allocation
    - Test contiguous seat allocation
    - Test multi-seat booking logic
    - Test partial allocation handling
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 5.1, 5.2, 5.3, 5.4, 5.5_

  - [x] 16.3 Write unit tests for BusManager
    - Test bus configuration
    - Test capacity validation
    - Test status reporting
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 9.4, 9.5_

  - [x] 16.4 Write unit tests for BookingManager
    - Test booking creation
    - Test payment status updates
    - Test booking cancellation
    - Test query methods
    - _Requirements: 1.5, 6.2, 6.3, 6.4, 6.5, 11.3, 11.4_

  - [x] 16.5 Write unit tests for SearchEngine
    - Test name search (partial and full)
    - Test mobile search (partial and full)
    - Test case-insensitive matching
    - Test bus filtering

- [ ] 19. Integration testing
  - [ ] 19.1 Write integration test for complete booking flow
    - Create booking with valid input
    - Verify seat allocation
    - Verify payment status update
    - Verify booking appears in search
    - _Requirements: 1.5, 6.1, 11.3, 12.1_

  - [ ] 19.2 Write integration test for multi-seat booking
    - Create booking with multiple seats
    - Verify contiguous allocation
    - Verify all seats on same bus
    - _Requirements: 5.1, 5.2, 5.6_

  - [ ] 19.3 Write integration test for age-based allocation
    - Create elder booking, verify bottom seat
    - Create young booking, verify upper seat
    - Create other booking, verify availability-based
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

  - [ ] 19.4 Write integration test for cancellation flow
    - Create booking
    - Cancel booking
    - Verify seats released
    - Verify booking removed from lists
    - _Requirements: 6.5, 11.6_

- [ ] 20. Final checkpoint - Ensure all tests pass
  - Run full test suite with coverage
  - Verify all property tests pass
  - Verify all widget tests pass
  - Verify integration tests pass
  - Ask the user if questions arise

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties
- Unit tests validate specific examples and edge cases
- Widget tests validate UI behavior and accessibility
- Integration tests validate complete user flows