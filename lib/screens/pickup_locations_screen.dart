import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/pickup_controller.dart';
import '../design/ugam.dart';
import '../models/pickup_location.dart';
import '../utils/app_snackbar.dart';

/// Settings → Pickup locations. The admin home for the GLOBAL list of pickup
/// points (migration 031's `pickup_locations`) that customers may OPTIONALLY
/// choose when they book. The list is shared across EVERY tour, so it lives
/// here once rather than per-tour.
///
/// Capabilities: add a point, drag-to-reorder the visible ones, show/hide a
/// point from the customer picker, rename, and delete. Hidden points stay in
/// this manager (dimmed + a "Hidden" badge) so a retired point can be brought
/// back, while past requests keep their snapshotted name regardless.
class PickupLocationsScreen extends StatefulWidget {
  const PickupLocationsScreen({super.key});

  @override
  State<PickupLocationsScreen> createState() => _PickupLocationsScreenState();
}

class _PickupLocationsScreenState extends State<PickupLocationsScreen> {
  PickupController get _ctrl => Get.find<PickupController>();

  final TextEditingController _codeField = TextEditingController();
  final TextEditingController _addField = TextEditingController();
  String? _addError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ctrl.ensureLoaded();
    });
  }

  @override
  void dispose() {
    _codeField.dispose();
    _addField.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _addField.text.trim();
    if (name.isEmpty) {
      setState(() => _addError = tr('pickup.name_required'));
      return;
    }
    setState(() {
      _addError = null;
      _busy = true;
    });
    try {
      await _ctrl.addLocation(name, code: _codeField.text);
      _codeField.clear();
      _addField.clear();
    } catch (_) {
      AppSnackBar.error(tr('settings_pages.save_error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _promptEdit(PickupLocation loc) async {
    final codeField = TextEditingController(text: loc.code ?? '');
    final nameField = TextEditingController(text: loc.name);
    final saved = await UgamDialog.show<bool>(
      context,
      title: tr('pickup.edit_title'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UgamInput(
            controller: codeField,
            label: tr('pickup.code_label'),
            hint: tr('pickup.code_hint'),
            maxLength: 6,
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            controller: nameField,
            label: tr('pickup.rename_hint'),
            hint: tr('pickup.rename_hint'),
            autofocus: true,
            onSubmitted: (_) => Navigator.of(context).pop(true),
          ),
        ],
      ),
      actions: (ctx) => [
        UgamButton(
          label: tr('app.action.cancel'),
          kind: UgamButtonKind.ghost,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        UgamButton(
          label: tr('settings_pages.save'),
          kind: UgamButtonKind.primary,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
    );
    final newName = nameField.text.trim();
    final newCode = codeField.text.trim();
    codeField.dispose();
    nameField.dispose();
    if (saved != true || newName.isEmpty) return;
    if (newName == loc.name && newCode == (loc.code ?? '')) return;
    try {
      await _ctrl.updateLocation(loc.id, name: newName, code: newCode);
    } catch (_) {
      AppSnackBar.error(tr('settings_pages.save_error'));
    }
  }

  Future<void> _confirmDelete(PickupLocation loc) async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('pickup.delete_title'),
      message: tr('pickup.delete_body'),
      confirmLabel: tr('pickup.delete'),
      cancelLabel: tr('app.action.cancel'),
      destructive: true,
    );
    if (!ok) return;
    try {
      await _ctrl.deleteLocation(loc.id);
    } catch (_) {
      AppSnackBar.error(tr('settings_pages.save_error'));
    }
  }

  Future<void> _toggleActive(PickupLocation loc) async {
    try {
      await _ctrl.setActive(loc.id, !loc.isActive);
    } catch (_) {
      AppSnackBar.error(tr('settings_pages.save_error'));
    }
  }

  /// Row overflow menu — Rename + Delete on a small on-brand sheet, so the
  /// per-row surface stays uncluttered.
  Future<void> _openMore(PickupLocation loc) async {
    final c = UgamColors.of(context);
    await UgamSheet.show<void>(
      context,
      title: loc.name,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MenuAction(
            c: c,
            icon: Icons.edit_outlined,
            label: tr('pickup.edit_title'),
            onTap: () {
              Navigator.of(ctx).pop();
              _promptEdit(loc);
            },
          ),
          const SizedBox(height: UgamSpacing.sm),
          _MenuAction(
            c: c,
            icon: Icons.delete_outline_rounded,
            label: tr('pickup.delete'),
            destructive: true,
            onTap: () {
              Navigator.of(ctx).pop();
              _confirmDelete(loc);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(title: tr('pickup.manage_title'), showBack: true),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.dockClearance,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildAddCard(c),
                    const SizedBox(height: UgamSpacing.xl),
                    Obx(() => _buildList(c)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddCard(UgamColorSet c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          SizedBox(
            width: 80,
            child: UgamInput(
              controller: _codeField,
              label: tr('pickup.code_label'),
              hint: tr('pickup.code_hint'),
              maxLength: 6,
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: UgamInput(
              controller: _addField,
              hint: tr('pickup.add_hint'),
              errorText: _addError,
              onChanged: (_) {
                if (_addError != null) setState(() => _addError = null);
              },
              onSubmitted: (_) => _add(),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          UgamButton(
            label: tr('pickup.add_button'),
            kind: UgamButtonKind.tonal,
            loading: _busy,
            onPressed: _busy ? null : _add,
          ),
        ],
      ),
    );
  }

  Widget _buildList(UgamColorSet c) {
    if (!_ctrl.loadedOnce.value && _ctrl.all.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: UgamSpacing.huge),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_ctrl.all.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: UgamSpacing.huge),
        child: _PickupEmpty(),
      );
    }

    final active = _ctrl.active;
    final hidden = _ctrl.all.where((p) => !p.isActive).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (active.isNotEmpty)
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: active.length,
            onReorder: _ctrl.reorder,
            proxyDecorator: (child, index, animation) => Material(
              color: Colors.transparent,
              child: child,
            ),
            itemBuilder: (ctx, i) {
              final loc = active[i];
              return Padding(
                key: ValueKey(loc.id),
                padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
                child: _row(c, loc, dragIndex: i),
              );
            },
          ),
        if (hidden.isNotEmpty) ...[
          if (active.isNotEmpty) const SizedBox(height: UgamSpacing.sm),
          for (final loc in hidden) ...[
            _row(c, loc),
            const SizedBox(height: UgamSpacing.sm),
          ],
        ],
      ],
    );
  }

  Widget _row(UgamColorSet c, PickupLocation loc, {int? dragIndex}) {
    final dimmed = !loc.isActive;
    final code = loc.code?.trim();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        children: [
          if (dragIndex != null)
            ReorderableDragStartListener(
              index: dragIndex,
              child: Padding(
                padding: const EdgeInsets.only(right: UgamSpacing.sm),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 20,
                  color: c.ink3,
                ),
              ),
            )
          else
            const SizedBox(width: UgamSpacing.md + 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (code != null && code.isNotEmpty) ...[
                      UgamReqChip(
                        label: code,
                        variant: UgamChipVariant.neutral,
                      ),
                      const SizedBox(width: UgamSpacing.sm),
                    ],
                    Expanded(
                      child: Text(
                        loc.name,
                        style: UgamText.titleS.copyWith(
                          color: dimmed ? c.ink3 : c.ink,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (dimmed) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tr('pickup.inactive_badge'),
                      style: UgamText.micro.copyWith(
                        color: c.ink3,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          _IconAction(
            c: c,
            icon: loc.isActive
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            tooltip: loc.isActive
                ? tr('pickup.deactivate')
                : tr('pickup.activate'),
            onTap: () => _toggleActive(loc),
          ),
          const SizedBox(width: UgamSpacing.xs),
          _IconAction(
            c: c,
            icon: Icons.more_horiz_rounded,
            tooltip: tr('pickup.edit_title'),
            onTap: () => _openMore(loc),
          ),
        ],
      ),
    );
  }
}

/// A compact circular icon button used for the per-row actions.
class _IconAction extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _IconAction({
    required this.c,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(UgamRadius.input),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: c.ink2),
        ),
      ),
    );
  }
}

/// A single row inside the overflow sheet (Rename / Delete).
class _MenuAction extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final bool destructive;
  final VoidCallback onTap;

  const _MenuAction({
    required this.c,
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? c.danger : c.ink;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md + 2,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: UgamSpacing.md),
            Text(
              label,
              style: UgamText.titleS.copyWith(color: fg, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

/// Empty state for when no pickup points have been created yet.
class _PickupEmpty extends StatelessWidget {
  const _PickupEmpty();

  @override
  Widget build(BuildContext context) {
    return UgamEmpty(
      icon: Icons.place_outlined,
      title: tr('pickup.empty_title'),
      body: tr('pickup.empty_body'),
    );
  }
}
