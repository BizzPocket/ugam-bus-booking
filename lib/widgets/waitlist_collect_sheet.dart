import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../services/waitlist_qr_share.dart';
import '../utils/app_snackbar.dart';
import '../utils/band_options.dart';
import '../utils/formatters.dart';
import '../utils/request_pricing.dart';
import '../utils/upi_uri.dart';
import '../utils/waitlist_pairing.dart';

/// Collect from a waitlisted one-leg rider: pair them, price them, send the QR,
/// and confirm once the money is in.
///
/// The four steps are one sheet on purpose. They are not independent — the band
/// decides the price, the pairing decides whether the berth's other leg is
/// earning, and confirming without either is the mistake the organiser most
/// wants to be warned about. Splitting them across screens would let a rider be
/// confirmed with no price ever quoted.
Future<void> showWaitlistCollectSheet(
  BuildContext context, {
  required Tour tour,
  required Passenger rider,
}) {
  return UgamSheet.show<void>(
    context,
    title: tr('waitlist_collect.title'),
    builder: (_) => _WaitlistCollectSheet(tour: tour, rider: rider),
  );
}

class _WaitlistCollectSheet extends StatefulWidget {
  final Tour tour;
  final Passenger rider;

  const _WaitlistCollectSheet({required this.tour, required this.rider});

  @override
  State<_WaitlistCollectSheet> createState() => _WaitlistCollectSheetState();
}

class _WaitlistCollectSheetState extends State<_WaitlistCollectSheet> {
  WaitlistPair? _pair;
  BandOption? _band;
  bool _busy = false;
  bool _qrSent = false;

  /// The seat type this rider wants. A one-leg request is a single type in
  /// practice; when it is not, the first line's type prices the quote and the
  /// organiser can still see every line on the row behind this sheet.
  SeatType get _type => widget.rider.requestLines.isNotEmpty
      ? widget.rider.requestLines.first.seatType
      : SeatType.singleSofa;

  List<WaitlistPair> get _candidates => pairCandidatesFor(
        widget.rider,
        widget.tour.passengers,
      );

  List<BandOption> get _bands =>
      bandOptionsFor(buses: widget.tour.buses, type: _type);

  int get _quotePaise => _band == null
      ? 0
      : waitlistQuotePaise(
          band: _band!.band,
          lines: widget.rider.requestLines,
        );

  /// The other rider in a chosen pairing, from this rider's point of view.
  Passenger? get _partner {
    final p = _pair;
    if (p == null) return null;
    return p.goRider.id == widget.rider.id ? p.retRider : p.goRider;
  }

  Future<void> _sendQr() async {
    final tour = widget.tour;
    final vpa = tour.collectVpa;
    if (vpa == null || vpa.trim().isEmpty) {
      AppSnackBar.error(tr('waitlist_collect.err_no_vpa'));
      return;
    }
    if (_quotePaise <= 0) {
      AppSnackBar.error(tr('waitlist_collect.err_pick_band'));
      return;
    }

    setState(() => _busy = true);
    final sent = await WaitlistQrShare.send(
      request: collectPayment(
        vpa: vpa,
        payeeName: (tour.collectPayeeName?.trim().isNotEmpty ?? false)
            ? tour.collectPayeeName!
            : tour.title,
        amountPaise: _quotePaise,
        note: '${tour.fromCity}-${tour.toCity} · ${widget.rider.name}',
        bookingRef: widget.rider.id,
      ),
      message: tr('waitlist_collect.wa_message', namedArgs: {
        'name': widget.rider.name,
        'trip': '${tour.fromCity} → ${tour.toCity}',
        'amount': Formatters.formatMoneyInr(_quotePaise / 100),
      }),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _qrSent = _qrSent || sent;
    });
  }

  /// Mark the money received and move the rider to Confirmed.
  ///
  /// Confirming an UNPAIRED rider is allowed — it is the organiser's call — but
  /// it gives away the berth's other leg, so it asks first.
  Future<void> _markPaidAndConfirm() async {
    if (_quotePaise <= 0) {
      AppSnackBar.error(tr('waitlist_collect.err_pick_band'));
      return;
    }
    if (_pair == null) {
      final ok = await UgamDialog.confirm(
        context,
        title: tr('waitlist_collect.unpaired_title'),
        message: tr('waitlist_collect.unpaired_body'),
        confirmLabel: tr('waitlist_collect.unpaired_confirm'),
        cancelLabel: tr('app.action.cancel'),
      );
      if (!ok || !mounted) return;
    }

    setState(() => _busy = true);
    final money = Get.isRegistered<MoneyController>()
        ? Get.find<MoneyController>()
        : null;
    final reason = await money?.recordWaitlistPayment(
      tourId: widget.tour.id,
      passengerId: widget.rider.id,
      amountPaise: _quotePaise,
    );

    // The money failing to post is NOT a reason to silently confirm anyway —
    // a confirmed rider whose payment never reached the ledger is a hole in the
    // tour's books that nobody will notice until settlement.
    if (reason != null) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppSnackBar.error(
        reason == 'no_request'
            ? tr('waitlist_collect.err_no_request')
            : tr('waitlist_collect.err_record'),
      );
      return;
    }

    if (Get.isRegistered<TourController>()) {
      await Get.find<TourController>()
          .setConfirmed(widget.tour.id, widget.rider.id, true);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop();
    AppSnackBar.success(
      tr('waitlist_collect.confirmed', namedArgs: {'name': widget.rider.name}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final bands = _bands;

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
          _riderLine(c),
          const SizedBox(height: UgamSpacing.lg),

          // ── 1. Pair ────────────────────────────────────────
          _eyebrow(c, tr('waitlist_collect.step_pair')),
          const SizedBox(height: UgamSpacing.sm),
          if (_candidates.isEmpty)
            _note(c, tr('waitlist_collect.no_partner'))
          else
            for (final p in _candidates) ...[
              _PairRow(
                key: Key('pair-${p.key}'),
                pair: p,
                rider: widget.rider,
                selected: _pair?.key == p.key,
                onTap: () => setState(
                  () => _pair = _pair?.key == p.key ? null : p,
                ),
              ),
              const SizedBox(height: UgamSpacing.xs),
            ],

          const SizedBox(height: UgamSpacing.lg),

          // ── 2. Band ────────────────────────────────────────
          _eyebrow(c, tr('waitlist_collect.step_band')),
          const SizedBox(height: UgamSpacing.sm),
          if (bands.isEmpty)
            _note(c, tr('waitlist_collect.no_bands'))
          else
            for (final b in bands) ...[
              _BandRow(
                key: Key('wlband-${b.key}'),
                option: b,
                type: _type,
                selected: _band?.key == b.key,
                onTap: b.soldOut ? null : () => setState(() => _band = b),
              ),
              const SizedBox(height: UgamSpacing.xs),
            ],

          // ── 3. Quote ───────────────────────────────────────
          if (_band != null) ...[
            const SizedBox(height: UgamSpacing.lg),
            Container(
              padding: const EdgeInsets.all(UgamSpacing.md),
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(UgamRadius.card),
                border: Border.all(color: c.accent),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('waitlist_collect.quote_label'),
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ),
                  Text(
                    Formatters.formatMoneyInr(_quotePaise / 100),
                    style: UgamText.tabular(
                      UgamText.titleM.copyWith(color: c.accent),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tr('waitlist_collect.quote_hint'),
              style: UgamText.micro.copyWith(color: c.ink3),
            ),
          ],

          const SizedBox(height: UgamSpacing.lg),

          // ── 4. Send + confirm ──────────────────────────────
          UgamButton(
            label: _qrSent
                ? tr('waitlist_collect.resend_qr')
                : tr('waitlist_collect.send_qr'),
            icon: Icons.qr_code_2_rounded,
            kind: UgamButtonKind.tonal,
            expand: true,
            onPressed: _busy || _band == null ? null : _sendQr,
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamButton(
            label: tr('waitlist_collect.mark_paid'),
            icon: Icons.verified_rounded,
            expand: true,
            loading: _busy,
            onPressed: _busy || _band == null ? null : _markPaidAndConfirm,
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(
            tr('waitlist_collect.mark_paid_hint'),
            textAlign: TextAlign.center,
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
        ],
      ),
    );
  }

  Widget _eyebrow(UgamColorSet c, String label) => Text(
        label.toUpperCase(),
        style: UgamText.micro.copyWith(color: c.ink3),
      );

  Widget _note(UgamColorSet c, String text) => Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Text(
          text,
          style: UgamText.caption.copyWith(color: c.ink2, height: 1.4),
        ),
      );

  Widget _riderLine(UgamColorSet c) {
    final partner = _partner;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.rider.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: UgamText.titleS.copyWith(color: c.ink),
        ),
        const SizedBox(height: 2),
        Text(
          [
            for (final l in widget.rider.requestLines) l.label,
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
        if (partner != null) ...[
          const SizedBox(height: 4),
          Text(
            tr('waitlist_collect.sharing_with',
                namedArgs: {'name': partner.name}),
            style: UgamText.caption.copyWith(color: c.accent),
          ),
        ],
      ],
    );
  }
}

/// One possible partner: who they are, and which leg they bring.
class _PairRow extends StatelessWidget {
  final WaitlistPair pair;
  final Passenger rider;
  final bool selected;
  final VoidCallback onTap;

  const _PairRow({
    super.key,
    required this.pair,
    required this.rider,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final other = pair.goRider.id == rider.id ? pair.retRider : pair.goRider;
    final otherGoes = pair.goRider.id == other.id;

    return UgamTappable(
      onTap: onTap,
      pressedScale: 0.98,
      child: Container(
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
          border: Border.all(color: selected ? c.accent : c.border),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_off_rounded,
              size: 18,
              color: selected ? c.accent : c.ink3,
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    other.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  Text(
                    tr(
                      otherGoes
                          ? 'waitlist_collect.partner_goes'
                          : 'waitlist_collect.partner_returns',
                      namedArgs: {'n': '${pair.units}'},
                    ),
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A band the organiser can put this rider in, priced at the HALF-leg rate.
class _BandRow extends StatelessWidget {
  final BandOption option;
  final SeatType type;
  final bool selected;
  final VoidCallback? onTap;

  const _BandRow({
    super.key,
    required this.option,
    required this.type,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final gone = option.soldOut;
    final half = (option.unitPricePaise / 2).round();

    return UgamTappable(
      onTap: onTap,
      pressedScale: gone ? 1.0 : 0.98,
      child: Container(
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
          border: Border.all(color: selected ? c.accent : c.border),
        ),
        child: Row(
          children: [
            Icon(
              gone
                  ? Icons.block_rounded
                  : (selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded),
              size: 18,
              color: gone ? c.ink3 : (selected ? c.accent : c.ink3),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                option.band.fromRow == option.band.toRow
                    ? tr('band_picker.row_one',
                        namedArgs: {'row': '${option.band.fromRow + 1}'})
                    : tr('band_picker.rows', namedArgs: {
                        'from': '${option.band.fromRow + 1}',
                        'to': '${option.band.toRow + 1}',
                      }),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              gone
                  ? tr('band_picker.sold_out')
                  : Formatters.formatMoneyInr(half / 100),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(
                  color: gone ? c.ink3 : (selected ? c.accent : c.ink),
                  decoration: gone ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
