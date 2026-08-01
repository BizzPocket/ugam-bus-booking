import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/ugam.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';
import '../utils/upi_uri.dart';

/// Opens the payer's own UPI app on [request], pre-filled.
///
/// Returns false when no UPI app could handle it (none installed, or the OS
/// refused the intent) so the caller can fall back to showing the QR instead of
/// claiming a payment screen opened that never did.
Future<bool> launchUpiApp(UpiRequest request) async {
  if (!request.isValid) return false;
  try {
    return await launchUrl(
      Uri.parse(request.build()),
      mode: LaunchMode.externalApplication,
    );
  } catch (_) {
    return false;
  }
}

/// Show a UPI payment as a scannable QR + a one-tap open-my-UPI-app action.
///
/// Two callers, same sheet:
///   • COLLECT — show the customer a QR for their seat advance. They scan with
///     GPay / PhonePe / Paytm and pay. Costs nothing: UPI to a merchant is zero
///     MDR by law, so there is no gateway cut on this path.
///   • PAY OUT — the organiser settling bus rent, fuel or tolls. They tap
///     "Open UPI app" and their own app opens with the vendor and amount filled.
Future<void> showUpiPaymentSheet(
  BuildContext context, {
  required UpiRequest request,
  required String title,
  String? subtitle,
}) {
  return UgamSheet.show<void>(
    context,
    title: title,
    builder: (_) => _UpiPaymentSheet(request: request, subtitle: subtitle),
  );
}

class _UpiPaymentSheet extends StatelessWidget {
  final UpiRequest request;
  final String? subtitle;

  const _UpiPaymentSheet({required this.request, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    if (!request.isValid) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.sm,
          UgamSpacing.gutter,
          UgamSpacing.xl,
        ),
        child: Text(
          tr('upi.err_invalid'),
          style: UgamText.body.copyWith(color: c.danger),
        ),
      );
    }

    final payload = request.build();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Amount leads — it is the one number that must be unmistakable
          // before anyone scans. Tabular so digits don't shift.
          Text(
            Formatters.formatMoneyInr(request.amountPaise / 100),
            textAlign: TextAlign.center,
            style: UgamText.tabular(
              UgamText.numXl.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            request.payee.name,
            textAlign: TextAlign.center,
            style: UgamText.bodyStrong.copyWith(color: c.ink2),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: UgamText.caption.copyWith(color: c.ink3),
            ),
          ],
          const SizedBox(height: UgamSpacing.lg),

          // THE QR IS ALWAYS DARK-ON-WHITE, in both themes.
          // A QR drawn in the app's dark palette loses the contrast ratio
          // scanners need, and the white margin around it is the spec's quiet
          // zone — without it many scanners simply never lock on. This is the
          // one place the design system is deliberately overridden.
          Center(
            child: Container(
              padding: const EdgeInsets.all(UgamSpacing.md),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(UgamRadius.card),
              ),
              child: QrImageView(
                data: payload,
                version: QrVersions.auto,
                size: 208,
                backgroundColor: Colors.white,
                // Medium correction: survives a scuffed phone screen or a
                // printed chart without inflating the module count.
                errorCorrectionLevel: QrErrorCorrectLevel.M,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Colors.black,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black,
                ),
              ),
            ),
          ),
          const SizedBox(height: UgamSpacing.md),

          Text(
            tr('upi.scan_hint'),
            textAlign: TextAlign.center,
            style: UgamText.caption.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.lg),

          _VpaRow(vpa: request.payee.vpa, c: c),
          const SizedBox(height: UgamSpacing.md),

          UgamButton(
            label: tr('upi.open_app'),
            icon: Icons.account_balance_wallet_outlined,
            expand: true,
            onPressed: () async {
              final opened = await launchUpiApp(request);
              if (!opened) AppSnackBar.error(tr('upi.err_no_app'));
            },
          ),
        ],
      ),
    );
  }
}

/// The VPA, copyable. The fallback path when a scan fails and the payer wants
/// to type the handle into their own app by hand.
class _VpaRow extends StatelessWidget {
  final String vpa;
  final UgamColorSet c;

  const _VpaRow({required this.vpa, required this.c});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: vpa));
        AppSnackBar.success(tr('upi.copied'));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                vpa,
                style: UgamText.body.copyWith(color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Icon(Icons.copy_rounded, size: 16, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
