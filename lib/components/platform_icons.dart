import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../utils/platform_detector.dart';

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