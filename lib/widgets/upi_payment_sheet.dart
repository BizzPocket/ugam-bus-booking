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

/// What the payer told us after scanning: that they paid, and optionally the
/// reference their own UPI app showed them.
///
/// This is an ASSERTION, never proof. A direct UPI deep-link to the organiser's
/// VPA is zero-MDR precisely because no gateway sits in the middle, so nothing
/// calls the app back to confirm the transfer. The agent verifies it against
/// their bank statement before it becomes money — see `confirm_payment_claim`
/// in migration 060.
class UpiClaimResult {
  /// The reference / UTR the payer copied from their UPI app. May be blank —
  /// it is a lookup aid for the agent, not a requirement.
  final String? reference;

  const UpiClaimResult({this.reference});
}

/// Show a UPI payment as a scannable QR + a one-tap open-my-UPI-app action.
///
/// Two callers, same sheet:
///   • COLLECT — show the customer a QR for their seat advance. They scan with
///     GPay / PhonePe / Paytm and pay. Costs nothing: UPI to a merchant is zero
///     MDR by law, so there is no gateway cut on this path.
///   • PAY OUT — the organiser settling bus rent, fuel or tolls. They tap
///     "Open UPI app" and their own app opens with the vendor and amount filled.
///
/// Set [askConfirmation] for the COLLECT case to add an "I've paid" step. It
/// resolves to a [UpiClaimResult] when the payer says they paid, or null when
/// they simply close the sheet. Without it the money is invisible to the app:
/// the handler prices from the fare alone and collects the advance a second
/// time. The PAY OUT caller leaves it off — nobody needs to claim their own
/// outgoing payment.
Future<UpiClaimResult?> showUpiPaymentSheet(
  BuildContext context, {
  required UpiRequest request,
  required String title,
  String? subtitle,
  bool askConfirmation = false,
}) {
  return UgamSheet.show<UpiClaimResult>(
    context,
    title: title,
    builder: (_) => _UpiPaymentSheet(
      request: request,
      subtitle: subtitle,
      askConfirmation: askConfirmation,
    ),
  );
}

class _UpiPaymentSheet extends StatefulWidget {
  final UpiRequest request;
  final String? subtitle;
  final bool askConfirmation;

  const _UpiPaymentSheet({
    required this.request,
    this.subtitle,
    this.askConfirmation = false,
  });

  @override
  State<_UpiPaymentSheet> createState() => _UpiPaymentSheetState();
}

class _UpiPaymentSheetState extends State<_UpiPaymentSheet> {
  final _ref = TextEditingController();

  @override
  void dispose() {
    _ref.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final request = widget.request;
    final subtitle = widget.subtitle;

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
          if (subtitle != null && subtitle.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
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

          // ── "I've paid" ────────────────────────────────────
          // Nothing calls this app back when the transfer lands, so the payer
          // telling us is the only signal there is. Recording it — even
          // unverified — is what stops the handler charging the advance a
          // second time on the bus.
          if (widget.askConfirmation) ...[
            const SizedBox(height: UgamSpacing.lg),
            Divider(height: 1, color: c.border),
            const SizedBox(height: UgamSpacing.md),
            Text(
              tr('upi.claim_hint'),
              style: UgamText.caption.copyWith(color: c.ink3),
            ),
            const SizedBox(height: UgamSpacing.sm),
            TextField(
              controller: _ref,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              style: UgamText.body.copyWith(color: c.ink),
              decoration: InputDecoration(
                labelText: tr('upi.claim_ref_label'),
                hintText: tr('upi.claim_ref_hint'),
                isDense: true,
              ),
            ),
            const SizedBox(height: UgamSpacing.md),
            UgamButton(
              label: tr('upi.claim_done'),
              icon: Icons.check_circle_outline,
              expand: true,
              onPressed: () {
                final ref = _ref.text.trim();
                Navigator.of(context).pop(
                  UpiClaimResult(reference: ref.isEmpty ? null : ref),
                );
              },
            ),
          ],
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
