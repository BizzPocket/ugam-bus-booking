import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../utils/platform_detector.dart';

// Android TextField
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

// iOS TextField
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