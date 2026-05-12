import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../config/theme.dart';
import '../services/app_updater.dart';

/// Top-level entry point used by [MyApp] on startup. Fires the GitHub
/// Releases check in the background; if a newer version is available we
/// open a Get.dialog so the user can install it. Failures are swallowed —
/// the updater must never block app launch.
Future<void> runStartupUpdateCheck() async {
  final info = await AppUpdater.instance.checkForUpdate();
  if (info == null) return;
  // Defer one tick so the dialog has a live overlay to attach to.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!Get.isDialogOpen!) {
      Get.dialog(
        _UpdateDialog(info: info),
        barrierDismissible: false,
      );
    }
  });
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  const _UpdateDialog({required this.info});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double _progress = 0;
  bool _downloading = false;
  String? _error;

  Future<void> _install() async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      await AppUpdater.instance.downloadAndInstall(
        widget.info,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _progress = p);
        },
      );
      // The Android installer takes over; the dialog can close.
      if (mounted) Get.back();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Update available — ${widget.info.tag}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _downloading
                ? 'Downloading… ${(_progress * 100).toStringAsFixed(0)}%'
                : 'A newer version of Ugam Booking is available. Install now?',
          ),
          if (_downloading) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress,
              color: AppTheme.brand,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.red)),
          ],
        ],
      ),
      actions: [
        if (!_downloading)
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('Later'),
          ),
        if (!_downloading)
          FilledButton(
            onPressed: _install,
            child: const Text('Install'),
          ),
      ],
    );
  }
}
