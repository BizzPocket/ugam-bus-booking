import 'package:flutter/foundation.dart';

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
  static bool get isWeb => kIsWeb;
}