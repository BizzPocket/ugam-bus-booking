part of '../settings_screen.dart';

String _fmtSignedInr(num v) {
  String grp(int n) {
    final s = n.toString();
    if (s.length <= 3) return s;
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    return '${parts.join(',')},$last3';
  }

  final r = v.round();
  if (r == 0) return '₹0';
  return r > 0 ? '+₹${grp(r)}' : '−₹${grp(r.abs())}';
}

/// Prominent Profit & Loss entry inside Settings. Shows the lifetime realised
/// net across all completed tours and opens the full [FinanceScreen] report.
/// This is the one place the cross-tour P&L surfaces in the main flow, so it
/// leads the settings body rather than hiding in the list below.
class _FinanceCard extends StatefulWidget {
  final UgamColorSet c;
  const _FinanceCard({required this.c});

  @override
  State<_FinanceCard> createState() => _FinanceCardState();
}

class _FinanceCardState extends State<_FinanceCard> {
  FinanceController get _finance => Get.find<FinanceController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Refetch when money moved since the last load. Settings is a tab, so its
      // State survives every visit — with a plain ensureLoaded() the headline
      // figure froze at whatever it was on first open and never tracked the
      // expenses/collections logged afterwards.
      _finance.refreshIfStale();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Obx(() {
      final loaded = _finance.loadedOnce.value;
      // A failed first load must NOT keep pretending to load: without this the
      // card sat on "Loading…" forever with no way to retry, which is what the
      // whole finance entry point looked like when the read failed.
      final failed = _finance.loadFailed.value && !loaded;
      final net = loaded ? _finance.lifetimeNet : 0.0;
      final profit = net >= 0;
      final netColor = failed
          ? c.danger
          : !loaded
              ? c.ink3
              : (net.round() == 0 ? c.ink : (profit ? c.good : c.danger));

      return UgamCard.plain(
        elev: true,
        // Retry in place when the load failed — tapping through to a report
        // that would only show its own error state helps nobody.
        onTap: failed
            ? _finance.reload
            : () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const FinanceScreen()),
                ),
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: Row(
          children: [
            // Was a one-off 44/21/r13 medallion — the only one in the whole
            // cluster that missed the canonical 40/20/r12 spec.
            _RowIcon(
              icon: failed ? Icons.cloud_off_rounded : Icons.insights_rounded,
              background: failed ? c.dangerFill : c.accentFill,
              foreground: failed ? c.danger : c.accent,
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('finance.card_eyebrow'),
                    style: UgamText.micro.copyWith(color: c.ink3),
                  ),
                  const SizedBox(height: 3),
                  if (failed)
                    Text(
                      tr('finance.card_failed'),
                      style: UgamText.titleS.copyWith(color: c.danger),
                    )
                  else if (!loaded)
                    Text(
                      tr('finance.card_loading'),
                      style: UgamText.titleS.copyWith(color: c.ink3),
                    )
                  else
                    Text(
                      // Was a hand-set 22. `numLg` (20) is the ladder step for
                      // an in-card figure; `numXl` (26) is the hero size and
                      // would out-shout the page title. numLg is already
                      // tabular, so the tabular() wrapper was a no-op too.
                      _fmtSignedInr(net),
                      style: UgamText.numLg.copyWith(color: netColor),
                    ),
                  const SizedBox(height: 2),
                  Text(
                    failed
                        ? tr('finance.card_failed_hint')
                        : tr('finance.card_lifetime'),
                    style: UgamText.caption.copyWith(color: c.ink3),
                  ),
                ],
              ),
            ),
            Icon(
              failed ? Icons.refresh_rounded : Icons.chevron_right_rounded,
              size: 20,
              color: c.ink3,
            ),
          ],
        ),
      );
    });
  }
}

class _ProfileHero extends StatelessWidget {
  final AuthController authCtrl;
  final UgamColorSet c;
  const _ProfileHero({required this.authCtrl, required this.c});

  @override
  Widget build(BuildContext context) {
    final avatar = UgamScale.px(context, 48);
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Row(
        children: [
          Container(
            width: avatar,
            height: avatar,
            decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Obx(
              () => Text(
                authCtrl.initials.isNotEmpty ? authCtrl.initials : '👋',
                // `titleL` IS 22 — the hand-set size was already on the ladder,
                // just spelled as an override of the wrong step.
                style: UgamText.titleL.copyWith(color: c.onAccent),
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => Text(
                    authCtrl.userName.value.isNotEmpty
                        ? authCtrl.userName.value
                        : tr('settings.welcome'),
                    // Was 17 — no such step. `titleM` (18) is the nearest and
                    // is what every other in-card heading already uses.
                    style: UgamText.titleM.copyWith(color: c.ink),
                  ),
                ),
                const SizedBox(height: 6),
                UgamReqChip(label: tr('settings.admin_badge')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final String phone;
  final UgamColorSet c;
  const _AccountCard({
    required this.phone,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return _GroupCard(
      children: [
        _AccountRow(
          c: c,
          icon: Icons.phone_rounded,
          label: tr('settings.phone_label'),
          value: phone,
        ),
      ],
    );
  }
}

class _AccountRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final String value;

  const _AccountRow({
    required this.c,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: UgamScale.tap(context, _rowMinHeight),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md,
        ),
        child: Row(
          children: [
            _RowIcon(icon: icon, background: c.card, foreground: c.ink2),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Country-code badge. Uses the darker base `card` against
                      // the `cardElev` card so the pill actually reads — the old
                      // neutral chip was `cardElev` on `cardElev` (invisible).
                      // No border: the darker fill alone separates it (soft-card
                      // style — depth from fill, not strokes).
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: c.card,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '+${WhatsAppCloudConfig.defaultCountryCode}',
                          // `micro` IS 10 — the fontSize just restated the step.
                          // Weight/tracking stay as deliberate badge overrides.
                          style: UgamText.micro.copyWith(
                            color: c.ink2,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          value.isNotEmpty ? value : '—',
                          // `titleS` is the real 15px step (Sora, the numeral
                          // face). The old `bodyStrong` + fontSize:15 invented a
                          // step that does not exist on the ladder. Matches the
                          // locked phone field on the Account Details page.
                          style: UgamText.tabular(
                            UgamText.titleS.copyWith(color: c.ink),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
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

class _ThemeTriPicker extends StatelessWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onPick;
  final UgamColorSet c;
  const _ThemeTriPicker({
    required this.mode,
    required this.onPick,
    required this.c,
  });

  // Each segment: (mode, icon, label key). Order matches the visible row.
  static const _options = <(ThemeMode, IconData, String)>[
    (ThemeMode.system, Icons.brightness_auto_rounded, 'settings.theme_system'),
    (ThemeMode.light, Icons.light_mode_rounded, 'settings.theme_light'),
    (ThemeMode.dark, Icons.dark_mode_rounded, 'settings.theme_dark'),
  ];

  @override
  Widget build(BuildContext context) {
    // Same segmented-pill idiom as UgamTabPills, but tailored for the theme
    // choice: a stacked icon-over-label cell with a clearer selected state
    // (filled card + soft shadow + accent icon). Kept local so the shared
    // pill component used across the app is untouched.
    return UgamCard.plain(
      elev: true,
      radius: UgamRadius.input,
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final (m, icon, key) in _options)
            Expanded(
              child: _ThemeSegment(
                c: c,
                icon: icon,
                label: tr(key),
                active: mode == m,
                onTap: () => onPick(m),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThemeSegment extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ThemeSegment({
    required this.c,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.xs,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: active ? c.card : Colors.transparent,
          borderRadius: BorderRadius.circular(13),
          // Was a hand-rolled BoxShadow. The selected segment lifts off the
          // track using the app's own scale, so it tracks the theme.
          boxShadow: active ? UgamElevation.of(context).rest : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: UgamScale.px(context, 20),
              color: active ? c.accent : c.ink3,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              // Was `maxLines: 1, softWrap: false` + ellipsis. The three
              // Gujarati labels fit today, but the app allows a 1.3x
              // accessibility text scale, at which point they would clip —
              // wrapping grows the picker instead of hiding the word.
              maxLines: 2,
              textAlign: TextAlign.center,
              // `caption` is the 12px step; only the weight is an override.
              style: UgamText.caption.copyWith(
                color: active ? c.ink : c.ink2,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
