import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/ugam.dart';
import '../models/tour.dart';
import '../utils/party_fit.dart';
import 'seat_selection_screen.dart';

/// Three plain questions, asked before the chart is drawn.
///
/// *** WHAT THIS SCREEN IS FOR ***
/// A customer booking a pilgrimage for four relatives should not have to audit
/// 36 unlabelled cells to work out whether they can sit together. They answer
/// three questions, and the chart opens with seats ALREADY chosen.
///
/// An earlier version asked how many people and whether they had to share one
/// bus, then handed over the same blank puzzle — it added a step without
/// removing the hard one. The same-bus question is gone: keeping a party
/// together is what the picker tries first, and predicting when that is
/// impossible was the picker's job, not the customer's.
///
/// It fetches NOTHING. Every answer here is about the party, not the bus, so
/// the questions appear instantly instead of behind a spinner.
class PartyGateScreen extends StatefulWidget {
  final Tour tour;

  /// Injected by tests to capture the answers instead of navigating.
  final void Function(PartyIntent intent)? onContinue;

  const PartyGateScreen({super.key, required this.tour, this.onContinue});

  /// Matches the chart's cap, which is counted in berths (people).
  static const maxPeople = 6;

  static const peopleKey = Key('party_people');
  static const ladiesKey = Key('party_ladies');
  static const shareKey = Key('party_share');
  static const yesKey = Key('party_yes');
  static const noKey = Key('party_no');
  static const continueKey = Key('party_continue');

  @override
  State<PartyGateScreen> createState() => _PartyGateScreenState();
}

class _PartyGateScreenState extends State<PartyGateScreen> {
  int _people = 1;
  bool _hasLadies = false;

  /// Defaults to true so the picker is not hobbled for a customer who does not
  /// care. Saying NO is the deliberate act, because it is the one that costs
  /// money — a party that refuses to share must buy whole sofas.
  bool _shareOk = true;

  void _continue() {
    HapticFeedback.selectionClick();
    final intent = PartyIntent(
      people: _people,
      hasLadies: _hasLadies,
      shareOk: _shareOk,
    );

    final onContinue = widget.onContinue;
    if (onContinue != null) {
      onContinue(intent);
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute<bool>(
        builder: (_) => SeatSelectionScreen(tour: widget.tour, intent: intent),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(showBack: true, title: tr('party_gate.title')),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.md,
                  UgamSpacing.gutter,
                  UgamSpacing.xl,
                ),
                children: [
                  _Question(c: c, label: tr('party_gate.people_q')),
                  const SizedBox(height: UgamSpacing.md),
                  _peopleChips(c),
                  const SizedBox(height: UgamSpacing.xl),
                  _Question(c: c, label: tr('party_gate.ladies_q')),
                  const SizedBox(height: UgamSpacing.md),
                  _YesNo(
                    key: PartyGateScreen.ladiesKey,
                    c: c,
                    value: _hasLadies,
                    onChanged: (v) => setState(() => _hasLadies = v),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  _Question(c: c, label: tr('party_gate.share_q')),
                  const SizedBox(height: 4),
                  Text(
                    tr('party_gate.share_hint'),
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  _YesNo(
                    key: PartyGateScreen.shareKey,
                    c: c,
                    value: _shareOk,
                    onChanged: (v) => setState(() => _shareOk = v),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: UgamStickyCTA(
        child: UgamCTA(
          key: PartyGateScreen.continueKey,
          label: tr('party_gate.continue'),
          leadingIcon: Icons.arrow_forward_rounded,
          onPressed: _continue,
        ),
      ),
    );
  }

  Widget _peopleChips(UgamColorSet c) {
    return Wrap(
      key: PartyGateScreen.peopleKey,
      spacing: UgamSpacing.sm,
      runSpacing: UgamSpacing.sm,
      children: [
        for (var n = 1; n <= PartyGateScreen.maxPeople; n++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _people = n);
            },
            child: AnimatedContainer(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              width: 52,
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _people == n ? c.accentFill : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
                border: Border.all(
                  color:
                      _people == n ? c.accent.withValues(alpha: 0.32) : c.border,
                ),
              ),
              child: Text(
                '$n',
                style: UgamText.tabular(
                  UgamText.titleS.copyWith(
                    color: _people == n ? c.accent : c.ink2,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Question extends StatelessWidget {
  final UgamColorSet c;
  final String label;

  const _Question({required this.c, required this.label});

  @override
  Widget build(BuildContext context) => Text(
        label,
        style: UgamText.titleS.copyWith(color: c.ink),
      );
}

/// A two-button answer. Big targets and plain words — this is read by people
/// who are not confident with apps, on cheap phones, often in bright sun.
class _YesNo extends StatelessWidget {
  final UgamColorSet c;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _YesNo({
    super.key,
    required this.c,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget button({required bool mine, required Key key, required String text}) {
      final on = value == mine;
      return Expanded(
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: () {
            HapticFeedback.selectionClick();
            onChanged(mine);
          },
          child: AnimatedContainer(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? c.accentFill : c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.card),
              border: Border.all(
                color: on ? c.accent.withValues(alpha: 0.32) : c.border,
              ),
            ),
            child: Text(
              text,
              style: UgamText.bodyStrong.copyWith(
                color: on ? c.accent : c.ink2,
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        button(
          mine: true,
          key: PartyGateScreen.yesKey,
          text: tr('party_gate.yes'),
        ),
        const SizedBox(width: UgamSpacing.sm),
        button(
          mine: false,
          key: PartyGateScreen.noKey,
          text: tr('party_gate.no'),
        ),
      ],
    );
  }
}
