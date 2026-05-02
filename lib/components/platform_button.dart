import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../utils/platform_detector.dart';

// Android Button
class AndroidBookingButton extends StatelessWidget {
  final VoidCallback? onPressed;
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

// iOS Button
class IOSBookingButton extends StatelessWidget {
  final VoidCallback? onPressed;
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
      borderRadius: BorderRadius.circular(10),
      child: Text(label),
    );
  }
}

// Unified button
class PlatformButton extends StatelessWidget {
  final VoidCallback? onPressed;
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