part of '../customer_tour_list_screen.dart';

// ─── widget pieces ────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onMore;
  final VoidCallback onMyRequests;
  final int myRequestCount;

  const _TopBar({
    required this.c,
    required this.onMore,
    required this.onMyRequests,
    required this.myRequestCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            // Discreet, customer-invisible admin entry: long-press the
            // title to open the (otherwise unlinked) login route.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: () {
                HapticFeedback.mediumImpact();
                Get.toNamed(AppRoutes.login);
              },
              child: Text(
                tr('customer_tour_list.header_explore'),
                style: UgamText.titleXl.copyWith(color: c.ink),
              ),
            ),
          ),
          Tooltip(
            message: tr('customer_tour_list.my_requests_tooltip'),
            child: _IconCircle(
              // Filled, not outlined. At 19 px the outlined ticket read as a
              // generic rounded rectangle; the solid one is unmistakably a
              // ticket stub, which is what "my bookings" is.
              icon: Icons.confirmation_number_rounded,
              c: c,
              onTap: onMyRequests,
              badgeCount: myRequestCount,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Tooltip(
            message: tr('customer_more.title'),
            // Not a hamburger. Three stacked lines promise a slide-out drawer,
            // and this app has none — the icon opens a short pushed list whose
            // title is literally "More", so the ellipsis is the honest glyph.
            child: _IconCircle(
              icon: Icons.more_horiz_rounded,
              c: c,
              onTap: onMore,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconCircle extends StatelessWidget {
  final IconData icon;
  final UgamColorSet c;
  final VoidCallback onTap;

  /// When > 0, paints an accent badge in the top-right corner.
  final int badgeCount;

  const _IconCircle({
    required this.icon,
    required this.c,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final size = UgamScale.tap(context, 44);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 19, color: c.ink),
          ),
          if (badgeCount > 0)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                constraints: const BoxConstraints(minWidth: 18),
                height: 18,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  // The one amber on this screen's chrome, and it earns it:
                  // the badge counts the bookings that are LITERALLY yours,
                  // which is the whole definition of the accent.
                  color: c.accent,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: c.bg, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  badgeCount > 9 ? '9+' : '$badgeCount',
                  style: UgamText.tabular(
                    UgamText.micro.copyWith(
                      color: c.onAccent,
                      fontWeight: FontWeight.w700,
                      // Line-height, not a size override: a single digit has to
                      // sit dead-centre in an 18 px circle.
                      height: 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Find my seat", promoted out of the More menu and onto the first screen.
///
/// Sits collapsed as one prompt line — a returning rider recognises it without
/// reading, a first-time visitor loses ~56 px of tour list to it. Tapping it
/// opens the number field IN PLACE; the actual lookup, its errors and the
/// chart all stay in [FindMySeatScreen], so there is exactly one implementation
/// of the flow and this bar is only its doorway.
///
/// The medallion is NEUTRAL, not amber. Nothing is selected or owned yet — this
/// is a doorway, and the accent means "this is yours", never "press me". The
/// only amber above the fold is the my-bookings count, which is a real
/// ownership claim. The Find button is [UgamColorSet.action] for the same
/// reason: a control asking to be pressed never spends the brand hue.
class _FindMySeatBar extends StatelessWidget {
  final UgamColorSet c;
  final bool open;
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onToggle;
  final VoidCallback onSubmit;

  const _FindMySeatBar({
    required this.c,
    required this.open,
    required this.controller,
    required this.focusNode,
    required this.onToggle,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.tight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GestureDetector(
              onTap: onToggle,
              behavior: HitTestBehavior.opaque,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: UgamScale.tap(context, 44),
                ),
                child: Row(
                  children: [
                    Container(
                      width: UgamScale.px(context, 40),
                      height: UgamScale.px(context, 40),
                      decoration: BoxDecoration(
                        color: c.cardElev,
                        borderRadius: BorderRadius.circular(UgamRadius.input),
                      ),
                      alignment: Alignment.center,
                      child: Icon(kFindMySeatIcon, size: 20, color: c.ink2),
                    ),
                    const SizedBox(width: UgamSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr('find_seat.title'),
                            style: UgamText.titleS.copyWith(color: c.ink),
                          ),
                          const SizedBox(height: 2),
                          // Wraps rather than ellipsing. The Gujarati is
                          // "બુકિંગ થઈ ગયું છે? તમારી સીટ જુઓ" — ~30% longer
                          // than the English, and a one-line clamp cut it at
                          // the question mark, which is the half that explains
                          // who the bar is for.
                          Text(
                            tr('find_seat.home_subtitle'),
                            style: UgamText.caption.copyWith(color: c.ink2),
                            maxLines: 2,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Icon(
                      open
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: c.ink3,
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              alignment: Alignment.topCenter,
              child: open
                  ? Padding(
                      padding: const EdgeInsets.only(top: UgamSpacing.tight),
                      // 2:1. The button is FLEXIBLE, not natural-width: a
                      // trailing child sized to its own content is unbounded in
                      // a Row, so a long translation of "Find" would push the
                      // number field off the card instead of shrinking itself.
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Container(
                              height: UgamScale.tap(context, 44),
                              padding: const EdgeInsets.symmetric(
                                horizontal: UgamSpacing.md,
                              ),
                              decoration: BoxDecoration(
                                color: c.cardElev,
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.chip,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.phone_iphone_rounded,
                                    size: 16,
                                    color: c.ink3,
                                  ),
                                  const SizedBox(width: UgamSpacing.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: controller,
                                      focusNode: focusNode,
                                      keyboardType: TextInputType.phone,
                                      textInputAction: TextInputAction.search,
                                      onSubmitted: (_) => onSubmit(),
                                      inputFormatters: [
                                        FilteringTextInputFormatter.allow(
                                          RegExp(r'[0-9+ ]'),
                                        ),
                                      ],
                                      style: UgamText.tabular(
                                        UgamText.body.copyWith(color: c.ink),
                                      ),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        hintText: tr('find_seat.phone_hint'),
                                        hintStyle: UgamText.body.copyWith(
                                          color: c.ink3,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: UgamSpacing.sm),
                          Flexible(
                            child: GestureDetector(
                              onTap: onSubmit,
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                height: UgamScale.tap(context, 44),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: UgamSpacing.lg,
                                ),
                                decoration: BoxDecoration(
                                  color: c.action,
                                  borderRadius: BorderRadius.circular(
                                    UgamRadius.chip,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  tr('find_seat.home_action'),
                                  style: UgamText.bodyStrong.copyWith(
                                    color: c.onAction,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
