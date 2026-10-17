// Per-passenger cash collection sheet.

import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../components/seat_chart_tile.dart';
import '../../design/group_color.dart';
import '../../design/ugam.dart';
import '../../models/collection.dart';
import '../../models/passenger.dart';
import '../../models/payment_claim.dart';
import '../../services/sync_service.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/formatters.dart';
import '../../utils/phone_dialer.dart';
import '../../utils/seat_money_state.dart';
import 'handler_atoms.dart';

// ─── Collect sheet ─────────────────────────────────────────────────────

/// Per-passenger collect form, mirroring collection_screen._openCollectSheet.
/// Keeps the call header (name + handler chip + age + phone + Call) and adds
/// the money form below. [onSave] persists the collection and updates the
/// chart; this widget owns the field controllers and pops on success.
class HandlerCollectSheet extends StatefulWidget {
  final Passenger passenger;
  final String seatId;
  final double due;
  final Collection? existing;

  /// The rider's UPI advance claims on this tour (pending and confirmed), so
  /// the sheet can say what they already paid online before the handler asks
  /// for the fare. Empty when there are none.
  final List<PaymentClaim> claims;

  final Future<void> Function(
    double received,
    double returned,
    String collectedBy,
    String note,
  )
  onSave;

  const HandlerCollectSheet({
    super.key,
    required this.passenger,
    required this.seatId,
    required this.due,
    required this.existing,
    this.claims = const [],
    required this.onSave,
  });

  @override
  State<HandlerCollectSheet> createState() => _HandlerCollectSheetState();
}

class _HandlerCollectSheetState extends State<HandlerCollectSheet> {
  late final TextEditingController _receivedCtrl;
  late final TextEditingController _returnedCtrl;
  late final TextEditingController _collectedByCtrl;
  late final TextEditingController _noteCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final col = widget.existing;
    _receivedCtrl = TextEditingController(
      text: (col?.amountReceived ?? 0) == 0
          ? ''
          : col!.amountReceived.toStringAsFixed(0),
    );
    // Only pre-seed "returned" with a GENUINE manual return; auto-recorded
    // change stays blank so a re-open re-derives it from the typed received
    // amount. Shared with the admin collect sheet so the two never drift.
    final seedReturn = manualReturnToSeed(col);
    _returnedCtrl = TextEditingController(
      text: seedReturn == null ? '' : seedReturn.toStringAsFixed(0),
    );
    _collectedByCtrl = TextEditingController(text: col?.collectedBy ?? '');
    _noteCtrl = TextEditingController(text: col?.note ?? '');
  }

  @override
  void dispose() {
    _receivedCtrl.dispose();
    _returnedCtrl.dispose();
    _collectedByCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  double _parse(TextEditingController ctl) =>
      double.tryParse(ctl.text.trim()) ?? 0;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(
        _parse(_receivedCtrl),
        _parse(_returnedCtrl),
        _collectedByCtrl.text.trim(),
        _noteCtrl.text.trim(),
      );
      // Dismiss the keyboard so it animates out cleanly with the sheet.
      FocusManager.instance.primaryFocus?.unfocus();
      // `true` tells the shared-seat chooser the collection landed, so it can
      // close behind us. Backing out pops with null and leaves it open.
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      // NAME the fault. This used to be `catch (_)` behind a generic "please
      // try again", which is how a hard server error (42P10 — the ON CONFLICT
      // arbiter stopped matching once 054 made the index partial, fixed in 091)
      // read to the handler as nothing more than a spinner that went nowhere.
      // The reason the server gives is the one thing worth showing here.
      AppSnackBar.error(
        tr(
          'handler_chart.error_save_collection_reason',
          namedArgs: {'reason': SyncService.describeReadError(e)},
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final passenger = widget.passenger;
    final hasPhone = passenger.phone.trim().isNotEmpty;
    final due = widget.due;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header: avatar, name, handler chip, age group ──
          Row(
            children: [
              // Decorative avatar -> px. Left at 48 it held its full footprint
              // while the initial inside it shrank with the text scaler, so the
              // circle visibly ballooned around the letter on a small phone.
              Container(
                width: UgamScale.px(context, 48),
                height: UgamScale.px(context, 48),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  passenger.name.trim().isNotEmpty
                      ? passenger.name.trim().characters.first.toUpperCase()
                      : '?',
                  style: UgamText.titleL.copyWith(color: c.accent),
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            passenger.name.trim().isNotEmpty
                                ? passenger.name
                                : tr('handler_chart.passenger_fallback'),
                            style: UgamText.titleL.copyWith(color: c.ink),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (passenger.isHandler) ...[
                          const SizedBox(width: UgamSpacing.sm),
                          UgamReqChip(
                            label: tr('handler_chart.handler_badge'),
                            variant: UgamChipVariant.warm,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      passenger.ageGroup.displayName,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Phone + Call ──
          // Was a hand-rolled cardElev slab at UgamRadius.input (14) sitting
          // inside a sheet whose other surfaces are UgamRadius.card (16).
          UgamCard.plain(
            elev: true,
            padding: const EdgeInsets.all(UgamSpacing.md),
            child: Row(
              children: [
                Icon(Icons.phone_outlined, size: 18, color: c.ink2),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    hasPhone ? passenger.phone : tr('handler_chart.no_phone'),
                    style: UgamText.body.copyWith(
                      color: hasPhone ? c.ink : c.ink3,
                    ),
                  ),
                ),
                if (hasPhone)
                  UgamButton(
                    label: tr('handler_chart.call'),
                    icon: Icons.call_rounded,
                    kind: UgamButtonKind.tonal,
                    onPressed: () => PhoneDialer.call(passenger.phone),
                  ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Collect form ──
          HandlerReadOnlyLine(
            label: tr('handler_chart.seat'),
            value: widget.seatId,
          ),
          const SizedBox(height: UgamSpacing.sm),
          HandlerReadOnlyLine(
            label: tr('handler_chart.amount_due'),
            value: Formatters.formatMoneyInr(due),
          ),
          // One-way leg → the due above is already HALVED. Spell that out so the
          // handler knows the amount differs from a full round-trip seat.
          if (passenger.tripType.isOneWay) ...[
            const SizedBox(height: UgamSpacing.sm),
            Builder(
              builder: (_) {
                final isRet =
                    passenger.tripType.usesReturn &&
                    !passenger.tripType.usesOutbound;
                final tint = isRet ? kReturnTint : kOneWayTint;
                return Row(
                  children: [
                    SeatLegPill(
                      label: isRet
                          ? tr('handler_chart.badge_ret')
                          : tr('handler_chart.badge_go'),
                      tint: tint,
                      half: true,
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Expanded(
                      child: Text(
                        tr('handler_chart.half_fare_note'),
                        style: UgamText.micro.copyWith(color: c.ink2),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
          // ── UPI advances the rider already sent ──
          // Named here, before the cash fields, because this is the moment
          // the handler decides how much to ask for. A pending claim is the
          // rider's word (the agent verifies it against the bank later); a
          // confirmed one is money the agent already holds.
          for (final claim in widget.claims) ...[
            const SizedBox(height: UgamSpacing.sm),
            _ClaimLine(claim: claim, c: c),
          ],
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('handler_chart.field_received'),
            controller: _receivedCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: (_) => setState(() {}),
          ),
          // The common case — the rider hands over exactly the fare — in one
          // tap instead of typing four digits on a moving bus. Hidden once the
          // field already reads the full fare, so it never offers a no-op.
          if (due > Collection.kMoneyEpsilon &&
              (_parse(_receivedCtrl) - due).abs() > Collection.kMoneyEpsilon) ...[
            const SizedBox(height: UgamSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: UgamButton(
                key: const ValueKey('collect-paid-in-full'),
                label: tr(
                  'handler_chart.paid_in_full',
                  namedArgs: {'amount': Formatters.formatMoneyInr(due)},
                ),
                icon: Icons.done_all_rounded,
                kind: UgamButtonKind.goodTonal,
                onPressed: () => setState(() {
                  _receivedCtrl.text = due.toStringAsFixed(0);
                  _receivedCtrl.selection = TextSelection.collapsed(
                    offset: _receivedCtrl.text.length,
                  );
                }),
              ),
            ),
          ],
          const SizedBox(height: UgamSpacing.md),
          // Returned / collected-by / note are the rare paths, so they fold
          // away rather than standing as three always-open empty fields between
          // the amount and Save. A re-opened row that already carries any of
          // them opens unfolded, so nothing saved is ever hidden.
          UgamExpander(
            key: const ValueKey('collect-more-details'),
            title: tr('handler_chart.collect_more_details'),
            icon: Icons.tune_rounded,
            initiallyExpanded:
                _returnedCtrl.text.isNotEmpty ||
                _collectedByCtrl.text.isNotEmpty ||
                _noteCtrl.text.isNotEmpty,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UgamInput(
                  label: tr('handler_chart.field_returned'),
                  controller: _returnedCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                  ],
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: UgamSpacing.md),
                UgamInput(
                  label: tr('handler_chart.field_collected_by'),
                  controller: _collectedByCtrl,
                ),
                const SizedBox(height: UgamSpacing.md),
                UgamInput(
                  label: tr('handler_chart.field_note'),
                  controller: _noteCtrl,
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.lg),
          // ── Live balance pill ──
          Builder(
            builder: (_) {
              final balance =
                  _parse(_receivedCtrl) - _parse(_returnedCtrl) - due;
              // The pill carries its own tonal FILL out of the branch rather
              // than deriving one with a hand-picked alpha, so it sits at the
              // same weight as every other good/warm/danger surface.
              final (
                String balLabel,
                Color balColor,
                Color balFill,
              ) = balance > 0
                  ? (
                      tr(
                        'handler_chart.balance_change',
                        namedArgs: {
                          'amount': Formatters.formatMoneyInr(balance),
                        },
                      ),
                      c.warm,
                      c.warmFill,
                    )
                  : balance < 0
                  ? (
                      tr(
                        'handler_chart.balance_still_to_collect',
                        namedArgs: {
                          'amount': Formatters.formatMoneyInr(-balance),
                        },
                      ),
                      // Neutral, not danger: a part-payment is the normal
                      // state of a fare mid-trip, not an error.
                      c.ink,
                      c.cardElev,
                    )
                  : (tr('handler_chart.balance_settled'), c.good, c.goodFill);
              // Smooth the color/text transitions as the amount field changes;
              // the balance VALUE/logic is unchanged, only the visual is eased.
              return AnimatedContainer(
                duration: UgamMotion.sheet,
                curve: UgamMotion.easeOut,
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.lg,
                  vertical: UgamSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: balFill,
                  borderRadius: BorderRadius.circular(UgamRadius.row),
                ),
                child: AnimatedDefaultTextStyle(
                  duration: UgamMotion.sheet,
                  curve: UgamMotion.easeOut,
                  style: UgamText.bodyStrong.copyWith(color: balColor),
                  child: Text(balLabel),
                ),
              );
            },
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving ? tr('handler_chart.saving') : tr('app.action.save'),
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}

/// One UPI claim on the collect sheet: verified reads as settled money (good
/// tone), unverified as the rider's claim (warm tone), with the UPI reference
/// when the rider gave one so the agent can be asked to match it.
class _ClaimLine extends StatelessWidget {
  final PaymentClaim claim;
  final UgamColorSet c;

  const _ClaimLine({required this.claim, required this.c});

  @override
  Widget build(BuildContext context) {
    final confirmed = claim.isConfirmed;
    final amount = Formatters.formatMoneyInr(claim.amountRupees);
    final ref = (claim.upiRef ?? '').trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: confirmed ? c.goodFill : c.warmFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            confirmed
                ? tr(
                    'handler_chart.upi_claim_confirmed',
                    namedArgs: {'amount': amount},
                  )
                : tr(
                    'handler_chart.upi_claim_pending',
                    namedArgs: {'amount': amount},
                  ),
            style: UgamText.caption.copyWith(
              color: confirmed ? c.good : c.warm,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (ref.isNotEmpty)
            Text(
              tr('handler_chart.upi_claim_ref', namedArgs: {'ref': ref}),
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink2),
              ),
            ),
        ],
      ),
    );
  }
}
