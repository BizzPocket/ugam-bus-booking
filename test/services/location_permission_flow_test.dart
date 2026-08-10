import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:occubusbooking/services/location_tracker_service.dart';

void main() {
  group('resolveTrackingStatus', () {
    test('OS location switch off beats any permission state', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: false,
          permission: LocationPermission.always,
        ),
        TrackingStatus.serviceDisabled,
      );
    });

    test('always means fully live', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.always,
        ),
        TrackingStatus.live,
      );
    });

    test('whileInUse is honest about being foreground-only', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.whileInUse,
        ),
        TrackingStatus.foregroundOnly,
      );
    });

    test('denied is recoverable, deniedForever is not', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.denied,
        ),
        TrackingStatus.denied,
      );
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.deniedForever,
        ),
        TrackingStatus.deniedForever,
      );
    });

    test('unableToDetermine is treated as denied, never as live', () {
      expect(
        resolveTrackingStatus(
          serviceEnabled: true,
          permission: LocationPermission.unableToDetermine,
        ),
        TrackingStatus.denied,
      );
    });
  });

  group('buildLocationSettings', () {
    test('Android carries the foreground-service notification', () {
      final s =
          buildLocationSettings(
                isAndroid: true,
                notificationTitle: 'T',
                notificationText: 'B',
              )
              as AndroidSettings;

      expect(s.foregroundNotificationConfig, isNotNull);
      expect(s.foregroundNotificationConfig!.notificationTitle, 'T');
      expect(s.foregroundNotificationConfig!.notificationText, 'B');
      expect(s.foregroundNotificationConfig!.enableWakeLock, isTrue);
      expect(s.distanceFilter, 50);
      expect(s.intervalDuration, const Duration(seconds: 30));
      expect(s.accuracy, LocationAccuracy.high);
    });

    test('iOS enables background updates and never auto-pauses', () {
      final s =
          buildLocationSettings(
                isAndroid: false,
                notificationTitle: 'T',
                notificationText: 'B',
              )
              as AppleSettings;

      expect(s.allowBackgroundLocationUpdates, isTrue);
      expect(s.showBackgroundLocationIndicator, isTrue);
      expect(
        s.pauseLocationUpdatesAutomatically,
        isFalse,
        reason: 'a bus parked at a dhaba must still report',
      );
      expect(s.activityType, ActivityType.automotiveNavigation);
      expect(s.distanceFilter, 50);
    });
  });
}
