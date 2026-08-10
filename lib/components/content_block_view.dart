import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/ugam.dart';
import '../models/content_block.dart';
import '../routes/app_routes.dart';
import '../services/remote_content_service.dart';

// Re-exported so a screen placing a slot needs one import, not two. The slot
// names and the widget that renders them belong together at the call site.
export '../models/content_block.dart' show ContentSlots;

/// Renders the server-driven content slot, or nothing at all.
///
/// Nothing is the normal state: with no content configured, no cached
/// document, or a document that parses to zero blocks, this occupies zero
/// space and the host screen looks exactly as it did before the feature
/// existed.
class ContentSlot extends StatelessWidget {
  /// Which named slot to render. See [ContentSlots].
  final String slot;

  /// Set on surfaces where the role is known, so blocks can target it. The
  /// customer surface leaves it null because that is the service default.
  final String? role;

  const ContentSlot(this.slot, {super.key, this.role});

  @override
  Widget build(BuildContext context) {
    // Absent in every test that does not run AppBinding, and on any surface
    // that mounts before it. Degrade to nothing rather than throwing.
    if (!Get.isRegistered<RemoteContentService>()) {
      return const SizedBox.shrink();
    }
    final service = Get.find<RemoteContentService>();
    if (role != null && service.role.value != role) {
      // Post-frame: this is a build method, and writing to an Rx during build
      // would trigger a rebuild-in-build assertion.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        service.role.value = role!;
      });
    }

    return Obx(() {
      // Read through forSlot so targeting is evaluated per build: a scheduled
      // promo starts, the locale changes, the app updates — all without the
      // document changing or a refetch.
      final blocks = service.forSlot(
        slot,
        locale: context.locale.languageCode,
      );
      if (blocks.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final b in blocks) ...[
            ContentBlockView(block: b),
            if (b.type != 'divider') const SizedBox(height: UgamSpacing.md),
          ],
        ],
      );
    });
  }
}

/// One block, rendered by a CLOSED registry of native widgets.
///
/// The server picks which of these to show and what text to put in it. It
/// cannot introduce a new one — an unrecognised type never reaches here,
/// because [ContentBlock.tryParse] drops it. That is the whole safety model:
/// remote data choosing between compiled-in widgets, never remote UI.
class ContentBlockView extends StatelessWidget {
  final ContentBlock block;

  const ContentBlockView({super.key, required this.block});

  /// In-app destinations a remote document may point at.
  ///
  /// The KEY is remote; the destination is compiled in. Without this, a
  /// content document could route a user into any screen in the app — a
  /// remote navigation primitive, which is not what content is for. Keep this
  /// list to places that are safe to arrive at cold, with no arguments.
  static const Map<String, String> _allowedRoutes = {
    'my_bookings': AppRoutes.customerMyRequests,
    'home': AppRoutes.customerHome,
  };

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final onTap = _resolveTap();

    final content = switch (block.type) {
      'banner' => _Banner(block: block, c: c),
      'link' => _LinkRow(block: block, c: c, hasTap: onTap != null),
      'cta' => _Cta(block: block, onTap: onTap),
      'faq' => _Faq(block: block, c: c),
      'stat' => _Stat(block: block, c: c),
      'divider' => _Divider(c: c),
      _ => _Notice(block: block, c: c),
    };

    // These own their own tap surface (a button) or must not have one at all
    // (an expander swallows the tap; a divider is decoration). Wrapping either
    // in an InkWell would either double-handle or make a rule tappable.
    if (const {'cta', 'faq', 'divider'}.contains(block.type)) return content;

    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: content,
    );
  }

  VoidCallback? _resolveTap() {
    switch (block.action) {
      case BlockAction.none:
        return null;

      case BlockAction.url:
        final target = block.actionTarget;
        if (target == null) return null;
        return () async {
          try {
            await launchUrl(
              Uri.parse(target),
              mode: LaunchMode.externalApplication,
            );
          } catch (_) {
            // No browser, or the launch was refused. Nothing useful to say
            // beyond what is already on screen.
          }
        };

      case BlockAction.route:
        final route = _allowedRoutes[block.actionTarget];
        // An unlisted route name is inert, not an error: a newer document may
        // name a destination this build does not have.
        if (route == null) return null;
        return () => Get.toNamed(route);
    }
  }

  static Color toneColor(String tone, UgamColorSet c) => switch (tone) {
        'warn' => c.danger,
        'info' => c.accent,
        _ => c.ink2,
      };
}

class _Notice extends StatelessWidget {
  final ContentBlock block;
  final UgamColorSet c;
  const _Notice({required this.block, required this.c});

  @override
  Widget build(BuildContext context) {
    final accent = ContentBlockView.toneColor(block.tone, c);
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (block.title != null)
            Text(block.title!, style: UgamText.titleS.copyWith(color: c.ink)),
          if (block.title != null && block.body != null)
            const SizedBox(height: UgamSpacing.xs),
          if (block.body != null)
            Text(block.body!, style: UgamText.body.copyWith(color: c.ink2)),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final ContentBlock block;
  final UgamColorSet c;
  const _Banner({required this.block, required this.c});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: Container(
        color: c.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (block.imageUrl != null)
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Image.network(
                  block.imageUrl!,
                  fit: BoxFit.cover,
                  // A dead image URL must degrade to nothing, not to a broken
                  // icon on the customer's first screen.
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  loadingBuilder: (ctx, child, progress) =>
                      progress == null ? child : const SizedBox.shrink(),
                ),
              ),
            if (block.title != null || block.body != null)
              Padding(
                padding: const EdgeInsets.all(UgamSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (block.title != null)
                      Text(block.title!,
                          style: UgamText.titleS.copyWith(color: c.ink)),
                    if (block.title != null && block.body != null)
                      const SizedBox(height: UgamSpacing.xs),
                    if (block.body != null)
                      Text(block.body!,
                          style: UgamText.body.copyWith(color: c.ink2)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A primary button. The action is resolved by the same constrained rules as
/// every other block — https URL or whitelisted route — so a CTA cannot reach
/// anywhere a link could not.
class _Cta extends StatelessWidget {
  final ContentBlock block;
  final VoidCallback? onTap;
  const _Cta({required this.block, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return UgamCTA(
      label: block.title!,
      // An inert CTA is a bug in the document, not something to render as a
      // dead button: UgamCTA renders disabled on a null callback, which is the
      // honest presentation.
      onPressed: onTap,
    );
  }
}

/// Collapsed question, expanded answer. The single highest-value block for
/// support content: it costs no vertical space until someone wants it.
class _Faq extends StatelessWidget {
  final ContentBlock block;
  final UgamColorSet c;
  const _Faq({required this.block, required this.c});

  @override
  Widget build(BuildContext context) {
    return UgamExpander(
      title: block.title ?? '',
      child: Padding(
        padding: const EdgeInsets.only(bottom: UgamSpacing.md),
        child: Text(
          block.body ?? '',
          style: UgamText.body.copyWith(color: c.ink2),
        ),
      ),
    );
  }
}

/// A large figure with a label — "12 seats left", "3 tours this week".
///
/// The VALUE IS A STRING and is rendered verbatim. It is deliberately not
/// computed on device: a server-supplied figure that the app also calculated
/// would be a second source of truth for a number, which is the exact class of
/// bug that cost this app a week.
class _Stat extends StatelessWidget {
  final ContentBlock block;
  final UgamColorSet c;
  const _Stat({required this.block, required this.c});

  @override
  Widget build(BuildContext context) {
    return UgamHeroStat(
      label: block.title ?? '',
      value: block.value!,
      tone: ContentBlockView.toneColor(block.tone, c),
      secondary: block.body,
    );
  }
}

class _Divider extends StatelessWidget {
  final UgamColorSet c;
  const _Divider({required this.c});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.md),
        child: Divider(height: 1, thickness: 1, color: c.border),
      );
}

class _LinkRow extends StatelessWidget {
  final ContentBlock block;
  final UgamColorSet c;
  final bool hasTap;
  const _LinkRow({required this.block, required this.c, required this.hasTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.md,
      ),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (block.title != null)
                  Text(block.title!,
                      style: UgamText.body.copyWith(color: c.ink)),
                if (block.body != null)
                  Text(block.body!,
                      style: UgamText.caption.copyWith(color: c.ink3)),
              ],
            ),
          ),
          if (hasTap)
            Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
        ],
      ),
    );
  }
}
