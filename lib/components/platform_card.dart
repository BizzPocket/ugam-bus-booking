import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../utils/platform_detector.dart';

// Android Card
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

// iOS Card
class IOSBookingCard extends StatelessWidget {
  final VoidCallback? onTap;
  final Widget child;

  const IOSBookingCard({super.key, required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground,
        border: Border(
          bottom: BorderSide(color: Colors.grey.shade300),
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
  final VoidCallback? onTap;
  final Widget child;

  const PlatformBookingCard({super.key, required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (PlatformDetector.isIOS) {
      return IOSBookingCard(onTap: onTap, child: child);
    }
    return AndroidBookingCard(onTap: onTap, child: child);
  }
}