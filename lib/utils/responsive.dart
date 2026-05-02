import 'package:flutter/material.dart';

/// Responsive breakpoint utilities for consistent layout across devices.
class Responsive {
  Responsive._();

  /// Small phones (< 360dp width)
  static bool isSmallPhone(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 360;

  /// Standard phones (360-400dp)
  static bool isPhone(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 400;

  /// Large phones / small tablets (400-600dp)
  static bool isLargePhone(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 400 &&
      MediaQuery.sizeOf(context).width < 600;

  /// Tablets (>= 600dp)
  static bool isTablet(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= 600;

  /// Screen width
  static double width(BuildContext context) =>
      MediaQuery.sizeOf(context).width;

  /// Screen height
  static double height(BuildContext context) =>
      MediaQuery.sizeOf(context).height;

  /// Horizontal padding that scales with screen size
  static double horizontalPadding(BuildContext context) {
    final w = width(context);
    if (w < 360) return 16;
    if (w < 400) return 20;
    if (w < 600) return 24;
    return 32;
  }

  /// Grid cross-axis count based on width
  static int gridColumns(BuildContext context, {int phoneColumns = 2}) {
    final w = width(context);
    if (w < 600) return phoneColumns;
    if (w < 900) return phoneColumns + 1;
    return phoneColumns + 2;
  }

  /// Stat card aspect ratio that works across screen sizes
  static double statCardAspectRatio(BuildContext context) {
    final w = width(context);
    if (w < 340) return 1.1;
    if (w < 380) return 1.25;
    if (w < 600) return 1.4;
    return 1.6;
  }
}
