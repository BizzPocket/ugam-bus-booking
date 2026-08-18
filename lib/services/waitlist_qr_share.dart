import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../utils/upi_uri.dart';

/// Sends a waitlisted rider a scannable UPI QR through the organiser's OWN
/// WhatsApp.
///
/// *** WHY THE SHARE SHEET AND NOT THE CLOUD API ***
/// The Cloud API can only send an image inside a template Meta has APPROVED,
/// and the three approved here — `seat_allocation`, `seat_allotment`,
/// `bus_msg` — are none of them a payment request. Adding one means a new
/// submission and Meta's review queue, which would block this feature on an
/// external party for days.
///
/// The native share sheet needs no template at all: the organiser picks
/// WhatsApp, the rider receives a real image in a real chat. It also sidesteps
/// the 132012 image-header rejections this project has already been bitten by
/// on the Cloud API rail.
///
/// The UPI link is ALWAYS in the accompanying text, never only in the picture.
/// A QR is useless to someone reading on the same phone they'd pay from, and an
/// image that fails to render leaves them with nothing to act on.
class WaitlistQrShare {
  const WaitlistQrShare._();

  /// Renders [request] as a PNG QR and opens the share sheet with [message].
  ///
  /// Returns false when the QR could not be drawn or the sheet was dismissed
  /// without sending — the caller must NOT treat either as money requested.
  static Future<bool> send({
    required UpiRequest request,
    required String message,
    Rect? originForIpad,
  }) async {
    if (!request.isValid) return false;

    final payload = request.build();
    final bytes = await _renderQr(payload);
    // The text carries the link regardless, so a failed render still leaves the
    // organiser something to send rather than a dead action.
    final text = '$message\n\n$payload';
    if (bytes == null) {
      final result = await SharePlus.instance.share(
        ShareParams(text: text, sharePositionOrigin: originForIpad),
      );
      return result.status == ShareResultStatus.success;
    }

    final dir = await getTemporaryDirectory();
    // One stable filename per payee+amount: re-sending the same request reuses
    // the file instead of littering the cache with near-identical PNGs.
    final file = File(
      '${dir.path}/upi-${request.amountPaise}-${payload.hashCode}.png',
    );
    await file.writeAsBytes(bytes, flush: true);

    final result = await SharePlus.instance.share(
      ShareParams(
        text: text,
        files: [XFile(file.path, mimeType: 'image/png')],
        sharePositionOrigin: originForIpad,
      ),
    );
    return result.status == ShareResultStatus.success;
  }

  /// QR as PNG bytes, or null if it could not be rasterised.
  ///
  /// Drawn DARK-ON-WHITE with a quiet zone whatever the app theme is, for the
  /// same reason the in-app sheet overrides the design system: a QR in the
  /// dark palette loses the contrast scanners need, and without the white
  /// margin many never lock on at all.
  static Future<Uint8List?> _renderQr(String payload) async {
    try {
      final painter = QrPainter(
        data: payload,
        version: QrVersions.auto,
        gapless: true,
        // Medium: survives a photographed or re-compressed screenshot, which
        // is exactly what happens to an image sent over WhatsApp.
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Color(0xFF000000),
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Color(0xFF000000),
        ),
      );
      const size = 720.0;
      const quiet = 48.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      // WhatsApp composites received images on its own background; without an
      // explicitly painted white card the transparent PNG margin can end up
      // dark and swallow the quiet zone.
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, size + quiet * 2, size + quiet * 2),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      canvas.translate(quiet, quiet);
      painter.paint(canvas, const Size(size, size));
      final image = await recorder.endRecording().toImage(
            (size + quiet * 2).toInt(),
            (size + quiet * 2).toInt(),
          );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (e) {
      debugPrint('waitlist QR render failed — $e');
      return null;
    }
  }
}
