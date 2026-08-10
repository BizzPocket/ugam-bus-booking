import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/ugam.dart';
import '../models/tour.dart';
import '../utils/party_fit.dart';
import 'seat_selection_screen.dart';

/// A few plain questions, asked before the chart is drawn.
///
/// *** WHAT THIS SCREEN IS FOR ***
/// A customer booking a pilgrimage for four relatives should not have to audit
/// 36 unlabelled cells to work out whether they can sit together. They answer a
/// short list of questions, and the chart opens with seats ALREADY chosen.
///
/// *** WHAT THIS SCREEN DOES NOT ASK, AND WHY ***
/// Two questions have been removed, both for the same reason: the answer never
/// changed anything the customer could see.
///
///  - "Must you stay on one bus?" — keeping a party together is what the picker
///    tries first. Asking the customer to predict when that is impossible was
///    asking them to do the picker's job.
///  - "Any ladies in the group?" — this was collected, threaded through
///    [PartyIntent], and handed to the picker, which never read it. Gender is
///    still collected at checkout, and the lady marker on the chart comes from
///    occupancy data rather than from this answer.
///
/// Before adding a question here, check that something downstream actually
/// branches on it.
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
  static const bothWaysKey = Key('party_both_ways');
  static const splitKey = Key('party_split');
  static const roundTripKey = Key('party_split_round');
  static const outboundKey = Key('party_split_go');
  static const returnKey = Key('party_split_return');
  static const shareKey = Key('party_share');
  static const yesKey = Key('party_yes');
  static const noKey = Key('party_no');
  static const continueKey = Key('party_continue');

  @override
  State<PartyGateScreen> createState() => _PartyGateScreenState();
}

class _PartyGateScreenState extends State<PartyGateScreen> {
  int _people = 1;

  /// True until the customer says otherwise. Most parties travel both ways, so
  /// this is the answer that costs them no extra taps.
  bool _bothWays = true;

  /// The split, used only when [_bothWays] is false.
  ///
  /// All three start at ZERO rather than pre-filled. A pre-filled split already
  /// adds up, so the customer could walk straight past the very question this
  /// block exists to ask — and we would record a guess as if it were an answer.
  int _roundTrip = 0;
  int _outbound = 0;
  int _return = 0;

  /// Defaults to true so the picker is not hobbled for a customer who does not
  /// care. Saying NO is the deliberate act, because it is the one that costs
  /// money — a party that refuses to share must buy whole sofas.
  bool _shareOk = true;

  int get _splitTotal => _roundTrip + _outbound + _return;

  /// People still unaccounted for in the split. Negative means they have
  /// assigned more travellers than the party actually has.
  int get _unassigned => _people - _splitTotal;

  bool get _canContinue => _bothWays || _unassigned == 0;

  /// Wipes the split. Called whenever the headline count changes or the
  /// both-ways answer flips, so a stale answer from a previous count can never
  /// survive into the intent.
  void _resetSplit() {
    _roundTrip = 0;
    _outbound = 0;
    _return = 0;
  }

  void _continue() {
    if (!_canContinue) return;
    HapticFeedback.selectionClick();
    final intent = PartyIntent(
      roundTrip: _bothWays ? _people : _roundTrip,
      outboundOnly: _bothWays ? 0 : _outbound,
      returnOnly: _bothWays ? 0 : _return,
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
                  _Question(c: c, label: tr('party_gate.both_ways_q')),
                  const SizedBox(height: UgamSpacing.md),
                  _YesNo(
                    key: PartyGateScreen.bothWaysKey,
                    c: c,
                    value: _bothWays,
                    onChanged: (v) => setState(() {
                      _bothWays = v;
                      _resetSplit();
                    }),
                  ),
                  if (!_bothWays) ...[
                    const SizedBox(height: UgamSpacing.lg),
                    Column(
                      key: PartyGateScreen.splitKey,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _splitRow(
                          c,
                          rowKey: PartyGateScreen.roundTripKey,
                          label: tr('party_gate.split_round'),
                          value: _roundTrip,
                          onChanged: (n) => setState(() => _roundTrip = n),
                        ),
                        const SizedBox(height: UgamSpacing.md),
                        _splitRow(
                          c,
                          rowKey: PartyGateScreen.outboundKey,
                          label: tr('party_gate.split_go'),
                          value: _outbound,
                          onChanged: (n) => setState(() => _outbound = n),
                        ),
                        const SizedBox(height: UgamSpacing.md),
                        _splitRow(
                          c,
                          rowKey: PartyGateScreen.returnKey,
                          label: tr('party_gate.split_return'),
                          value: _return,
                          onChanged: (n) => setState(() => _return = n),
                        ),
                        const SizedBox(height: UgamSpacing.sm),
                        // The mismatch is stated in WORDS. A silently dead CTA
                        // teaches the customer nothing about why they are stuck.
                        if (_unassigned != 0)
                          Text(
                            _unassigned > 0
                                ? tr(
                                    'party_gate.split_short',
                                    namedArgs: {'n': '$_unassigned'},
                                  )
                                : tr(
                                    'party_gate.split_over',
                                    namedArgs: {'n': '${-_unassigned}'},
                                  ),
                            style: UgamText.caption.copyWith(color: c.warm),
                          ),
                      ],
                    ),
                  ],
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
          // Disabled while the split does not add up. The reason is printed
          // above the button, so this is never a dead control with no
          // explanation next to it.
          onPressed: _canContinue ? _continue : null,
        ),
      ),
    );
  }

  /// One labelled count row of the split.
  ///
  /// Offers 0..[_people] because no single bucket can exceed the party — an
  /// upper bound the customer can see beats a validation message they hit only
  /// after making the mistake.
  Widget _splitRow(
    UgamColorSet c, {
    required Key rowKey,
    required String label,
    required int value,
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: UgamText.caption.copyWith(color: c.ink2)),
        const SizedBox(height: 6),
        Wrap(
          key: rowKey,
          spacing: UgamSpacing.sm,
          runSpacing: UgamSpacing.sm,
          children: [
            for (var n = 0; n <= _people; n++)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onChanged(n);
                },
                child: AnimatedContainer(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
                  width: 44,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == n ? c.accentFill : c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                    border: Border.all(
                      color: value == n
                          ? c.accent.withValues(alpha: 0.32)
                          : c.border,
                    ),
                  ),
                  child: Text(
                    '$n',
                    style: UgamText.tabular(
                      UgamText.body.copyWith(
                        color: value == n ? c.accent : c.ink2,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
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
              // Re-zero the split: a breakdown of four people is nonsense the
              // moment the party becomes three, and silently carrying it over
              // would submit numbers the customer never agreed to.
              setState(() {
                _people = n;
                _resetSplit();
              });
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
