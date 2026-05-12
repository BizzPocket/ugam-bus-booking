import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../utils/platform_detector.dart';

// Android Dialog
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
        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: Text(confirmText)),
      ],
    );
  }
}

// iOS Dialog
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
Future<dynamic> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String? confirmText,
  String? cancelText,
}) async {
  final resolvedConfirm = confirmText ?? tr('app.action.confirm');
  final resolvedCancel = cancelText ?? tr('app.action.cancel');
  if (PlatformDetector.isIOS) {
    return showCupertinoDialog<bool>(
      context: context,
      builder: (context) => IOSConfirmDialog(
        title: title,
        content: content,
        confirmText: resolvedConfirm,
        cancelText: resolvedCancel,
      ),
    );
  }
  return showDialog<bool>(
    context: context,
    builder: (context) => AndroidConfirmDialog(
      title: title,
      content: content,
      confirmText: resolvedConfirm,
      cancelText: resolvedCancel,
    ),
  );
}