part of '../conversation_screen.dart';

/// Subtle line above the composer telling the admin whether the free-form 24h
/// reply window is open (positive) or closed (muted — sends fall back to a
/// template).
class _WindowStatus extends StatelessWidget {
  final bool open;

  const _WindowStatus({required this.open});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xs,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: UgamStatusDot(
          label: open ? tr('inbox.window_open') : tr('inbox.window_closed'),
          tone: open ? UgamStatusTone.good : UgamStatusTone.neutral,
        ),
      ),
    );
  }
}

/// Persistent, retryable failure strip for the last send. Sits directly above
/// the composer, next to the draft it restored.
class _SendFailure extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _SendFailure({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Row(
        children: [
          // Wraps rather than truncating: Meta's own reason is the whole value
          // of this strip and Gujarati runs ~30% longer than the English.
          Expanded(
            child: UgamCaveat(
              message: message,
              tone: UgamCaveatTone.danger,
              icon: Icons.error_outline_rounded,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          UgamButton(
            label: tr('actions.retry'),
            kind: UgamButtonKind.dangerTonal,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

/// Bottom-pinned reply composer: multiline input + circular send button. The
/// enclosing [UgamScaffold] resizes for the keyboard, so this row rides just
/// above the on-screen keyboard; the hairline separates it from the transcript
/// scrolling behind it.
class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final bool canSend;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final UgamColorSet c;

  const _Composer({
    required this.controller,
    required this.sending,
    required this.canSend,
    required this.onChanged,
    required this.onSend,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final box = UgamScale.tap(context, 44);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            UgamSpacing.gutter,
            UgamSpacing.sm,
            UgamSpacing.gutter,
            UgamSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: UgamInput(
                  controller: controller,
                  hint: tr('inbox.reply_hint'),
                  keyboardType: TextInputType.multiline,
                  minLines: 1,
                  maxLines: 5,
                  enabled: !sending,
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // Circular send action. Disabled (muted) while empty or in-flight;
              // shows an inline spinner during the send round-trip.
              sending
                  ? Container(
                      width: box,
                      height: box,
                      decoration: BoxDecoration(
                        color: c.cardElev,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          valueColor: AlwaysStoppedAnimation(c.ink3),
                        ),
                      ),
                    )
                  : UgamIconButton(
                      icon: Icons.arrow_upward_rounded,
                      onTap: canSend ? onSend : null,
                      semanticLabel: tr('inbox.send'),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shimmer placeholder while the first message page loads.
///
/// Bottom-anchored and alternating side/width, so it stands where the real
/// transcript will stand instead of stacking three identical slabs at the top
/// of an otherwise empty screen.
class _ThreadSkeleton extends StatelessWidget {
  const _ThreadSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: const [
          _SkeletonBubble(alignEnd: false, width: 208, height: 56),
          SizedBox(height: UgamSpacing.md),
          _SkeletonBubble(alignEnd: true, width: 152, height: 40),
          SizedBox(height: UgamSpacing.xs),
          _SkeletonBubble(alignEnd: true, width: 224, height: 40),
          SizedBox(height: UgamSpacing.md),
          _SkeletonBubble(alignEnd: false, width: 176, height: 40),
        ],
      ),
    );
  }
}

class _SkeletonBubble extends StatelessWidget {
  final bool alignEnd;
  final double width;
  final double height;

  const _SkeletonBubble({
    required this.alignEnd,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment:
          alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        UgamSkeleton(
          // Decorative — never a tap target.
          width: UgamScale.px(context, width),
          height: UgamScale.px(context, height),
          radius: UgamRadius.row,
        ),
      ],
    );
  }
}
