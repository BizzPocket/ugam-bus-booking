import 'dart:ui';
import 'package:flutter/material.dart';

import '../tokens.dart';

/// A premium, modern glassmorphic container using [BackdropFilter].
/// Useful for overlay cards, custom top bars, docks, or premium list items.
class UgamGlassContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final Color? color;
  final BoxBorder? border;

  const UgamGlassContainer({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(UgamSpacing.gutter),
    this.radius = UgamRadius.card,
    this.blur = 12.0,
    this.color,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final defaultBg = isDark
        ? Colors.white.withValues(alpha: 0.07)
        : Colors.black.withValues(alpha: 0.04);

    final defaultBorder = Border.all(
      color: isDark
          ? Colors.white.withValues(alpha: 0.09)
          : Colors.black.withValues(alpha: 0.07),
      width: 1.0,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color ?? defaultBg,
            borderRadius: BorderRadius.circular(radius),
            border: border ?? defaultBorder,
          ),
          child: child,
        ),
      ),
    );
  }
}
