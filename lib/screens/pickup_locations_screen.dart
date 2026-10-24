import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/pickup_controller.dart';
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/pickup_location.dart';
import '../utils/app_snackbar.dart';
import '../utils/in_flight.dart';

part 'pickup_locations/pickup_widgets.dart';

/// Settings → Pickup locations. The admin home for the GLOBAL list of pickup
/// points (migration 031's `pickup_locations`) that customers may OPTIONALLY
/// choose when they book. The list is shared across EVERY tour, so it lives
/// here once rather than per-tour.
///
/// Capabilities: add a point, drag-to-reorder the visible ones, show/hide a
/// point from the customer picker, rename, and delete. Hidden points stay in
/// this manager (in their own labelled section) so a retired point can be
/// brought back, while past requests keep their snapshotted name regardless.
///
/// Destructive design: `deleteLocation` is a hard DB delete with no undo, so
/// **Hide** is presented as the reversible alternative directly above Delete in
/// the row menu, Delete carries its own tonal-danger surface and a separating
/// gap, and it still has to clear a confirm dialog.
class PickupLocationsScreen extends StatefulWidget {
  const PickupLocationsScreen({super.key});

  @override
  State<PickupLocationsScreen> createState() => _PickupLocationsScreenState();
}

class _PickupLocationsScreenState extends State<PickupLocationsScreen> {
  PickupController get _ctrl => Get.find<PickupController>();

  final TextEditingController _codeField = TextEditingController();
  final TextEditingController _addField = TextEditingController();
  final FocusNode _addFocus = FocusNode();

  // The edit dialog's fields are owned by THIS state, not created per-dialog.
  //
  // `UgamDialog.show` (like every `showDialog`) completes its future the moment
  // the route is popped — the dialog subtree is still mounted for the length of
  // the exit transition. Controllers created inside `_promptEdit` were disposed
  // immediately after that await, i.e. while two live `TextField`s still held
  // them. Owning them here removes the race entirely (only one edit dialog can
  // be open at a time) and they are disposed with the screen.
  final TextEditingController _editCodeField = TextEditingController();
  final TextEditingController _editNameField = TextEditingController();

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
    _addFocus.dispose();
    _editCodeField.dispose();
    _editNameField.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _addField.text.trim();
    if (name.isEmpty) {
      setState(() => _addError = tr('pickup.name_required'));
      _addFocus.requestFocus();
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
      // Straight back into the name field: this form is used to enter a whole
      // list of stops in one sitting.
      if (mounted) _addFocus.requestFocus();
    } catch (_) {
      AppSnackBar.error(tr('settings_pages.save_error'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _promptEdit(PickupLocation loc) async {
    _editCodeField.text = loc.code ?? '';
    _editNameField.text = loc.name;
    final saved = await UgamDialog.show<bool>(
      context,
      title: tr('pickup.edit_title'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UgamInput(
            controller: _editCodeField,
            label: tr('pickup.code_label'),
            hint: tr('pickup.code_hint'),
            maxLength: 6,
          ),
          const SizedBox(height: UgamSpacing.md),
          // Builder: pop with a context INSIDE the dialog route — the screen's
          // context resolves the screen's navigator, not the dialog's.
          Builder(
            builder: (fieldCtx) => UgamInput(
              controller: _editNameField,
              label: tr('pickup.form_label'),
              hint: tr('pickup.rename_hint'),
              autofocus: true,
              onSubmitted: (_) => Navigator.of(fieldCtx).pop(true),
            ),
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
    final newName = _editNameField.text.trim();
    final newCode = _editCodeField.text.trim();
    if (saved != true) return;
    // Saving a blank name used to discard the edit in total silence.
    if (newName.isEmpty) {
      AppSnackBar.error(tr('pickup.name_required'));
      return;
    }
    if (newName == loc.name && newCode == (loc.code ?? '')) return;
    await InFlight.run(_rowKey(loc), () async {
      try {
        await _ctrl.updateLocation(loc.id, name: newName, code: newCode);
      } catch (_) {
        AppSnackBar.error(tr('settings_pages.save_error'));
      }
    });
  }

  /// One write per pickup row at a time. A rename, a delete or a hide that is
  /// still on a slow link must not be raced by a second tap on the same row —
  /// a doubled delete reported "save failed" for a row that was in fact gone.
  static String _rowKey(PickupLocation loc) => 'pickup-row:${loc.id}';

  Future<void> _confirmDelete(PickupLocation loc) async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('pickup.delete_title'),
      message: tr('pickup.delete_body'),
      confirmLabel: tr('pickup.delete'),
      cancelLabel: tr('app.action.cancel'),
      destructive: true,
      confirmIcon: Icons.delete_outline_rounded,
    );
    if (!ok) return;
    await InFlight.run(_rowKey(loc), () async {
      try {
        await _ctrl.deleteLocation(loc.id);
      } catch (_) {
        AppSnackBar.error(tr('settings_pages.save_error'));
      }
    });
  }

  Future<void> _toggleActive(PickupLocation loc) async {
    await InFlight.run(_rowKey(loc), () async {
      try {
        await _ctrl.setActive(loc.id, !loc.isActive);
      } catch (_) {
        AppSnackBar.error(tr('settings_pages.save_error'));
      }
    });
  }

  /// Drag-to-reorder bridge.
  ///
  /// [ReorderableListView.onReorderItem] (the replacement for the deprecated
  /// `onReorder`) hands back a target index that has ALREADY been adjusted for
  /// the removal of the dragged row. [PickupController.reorder] still takes the
  /// legacy PRE-removal index and runs that same `if (target > oldIndex)
  /// target -= 1` normalisation itself, so the index is re-inflated here.
  /// Passing the adjusted index straight through would decrement it twice and
  /// land every downward drag one slot short of where it was dropped.
  void _handleReorder(int oldIndex, int newIndex) {
    _ctrl.reorder(oldIndex, newIndex > oldIndex ? newIndex + 1 : newIndex);
  }

  /// Row overflow menu. Rename first, then the reversible Hide/Show, then —
  /// after a deliberate gap and on its own danger surface — Delete.
  Future<void> _openMore(PickupLocation loc) async {
    final c = UgamColors.of(context);
    await UgamSheet.show<void>(
      context,
      title: loc.name,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
            icon: loc.isActive
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            label:
                loc.isActive ? tr('pickup.deactivate') : tr('pickup.activate'),
            subtitle: loc.isActive ? tr('pickup.hide_subtitle') : null,
            onTap: () {
              Navigator.of(ctx).pop();
              _toggleActive(loc);
            },
          ),
          // The gap is the separation: a destructive row must not sit in the
          // same rhythm as the reversible one directly above it.
          const SizedBox(height: UgamSpacing.xxl),
          _MenuAction(
            c: c,
            icon: Icons.delete_outline_rounded,
            label: tr('pickup.delete'),
            subtitle: tr('pickup.delete_subtitle'),
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

  /// "N visible · M hidden" — the list's shape in one app-bar line. Null until
  /// the first load lands, so a skeleton is never captioned with a real count.
  String? _summaryLine() {
    if (!_ctrl.loadedOnce.value) return null;
    final rows = _ctrl.all;
    if (rows.isEmpty) return null;
    final hidden = rows.where((p) => !p.isActive).length;
    final visible = rows.length - hidden;
    return [
      tr('pickup.count_visible', namedArgs: {'n': '$visible'}),
      if (hidden > 0) tr('pickup.count_hidden', namedArgs: {'n': '$hidden'}),
    ].join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // Bottom reserve, MEASURED rather than assumed.
    //
    // This screen has two entry points with different chrome: Settings pushes
    // it on the shell's nested navigator (floating dock visible), while
    // `AppRoutes.pickupLocations` opens it on the root navigator (no dock).
    // The shell Scaffold runs `extendBody`, so it reports the dock's height as
    // this route's bottom padding — which means one read covers both cases
    // exactly. The old code consumed that inset with `SafeArea` AND reserved a
    // flat `dockClearance` on top of it, stacking ~270px of blank under the
    // last row on the docked path while over-reserving ~110px on the other.
    final bottomReserve =
        MediaQuery.paddingOf(context).bottom + UgamSpacing.xl;

    return UgamScaffold(
      // `bottom: false`: the scroll runs under the dock (which is what the
      // dock's own gradient fade is drawn for) and pays for it exactly once,
      // in the list padding below.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Obx(
              () => UgamAppBar(
                title: tr('pickup.manage_title'),
                subtitle: _summaryLine(),
                showBack: true,
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  bottomReserve,
                ),
                children: [
                  _buildAddCard(c),
                  const SizedBox(height: UgamSpacing.lg),
                  Obx(() => _buildList(c)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddCard(UgamColorSet c) {
    return UgamCard.plain(
      // NOT `elev`: `UgamInput` fills itself with `cardElev`, so an elevated
      // card would paint the fields in exactly the card's own tone and the
      // form would read as one flat slab.
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Fixed, because a 6-character code needs a fixed slot; the name
              // takes everything else.
              SizedBox(
                width: 100,
                child: UgamInput(
                  controller: _codeField,
                  label: tr('pickup.code_label'),
                  hint: tr('pickup.code_hint'),
                  maxLength: 6,
                  onSubmitted: (_) => _addFocus.requestFocus(),
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: UgamInput(
                  controller: _addField,
                  focusNode: _addFocus,
                  label: tr('pickup.form_label'),
                  hint: tr('pickup.add_hint'),
                  errorText: _addError,
                  onChanged: (_) {
                    if (_addError != null) setState(() => _addError = null);
                  },
                  onSubmitted: (_) => _add(),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          // Full width, on its own line. As a natural-width trailing child of
          // the field row it squeezed the name input to ~120px at the Gujarati
          // label length, and less again at the 1.3x text scale the app allows.
          UgamButton(
            label: tr('pickup.add_button'),
            icon: Icons.add_rounded,
            kind: UgamButtonKind.tonal,
            expand: true,
            loading: _busy,
            onPressed: _busy ? null : _add,
          ),
        ],
      ),
    );
  }

  Widget _buildList(UgamColorSet c) {
    final loaded = _ctrl.loadedOnce.value;
    final failed = _ctrl.loadFailed.value;
    final rows = _ctrl.all.toList(growable: false);

    // "Couldn't load" is NOT "there are none" — the old code painted the empty
    // state over a failed fetch, telling the admin their list was gone.
    if (!loaded && failed) {
      return Padding(
        padding: const EdgeInsets.only(top: UgamSpacing.huge),
        child: UgamEmpty.error(onRetry: () => _ctrl.refresh()),
      );
    }
    if (!loaded) return const _PickupListSkeleton();

    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: UgamSpacing.huge),
        child: UgamEmpty(
          icon: Icons.place_outlined,
          title: tr('pickup.empty_title'),
          body: tr('pickup.empty_body'),
          // The one thing to do from zero is fill in the form directly above,
          // so the state points the cursor at it instead of just narrating.
          cta: UgamButton(
            label: tr('pickup.add_hint'),
            icon: Icons.add_rounded,
            onPressed: () => _addFocus.requestFocus(),
          ),
        ),
      );
    }

    final active = _ctrl.active;
    final hidden = rows.where((p) => !p.isActive).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (active.isNotEmpty) ...[
          _SectionHead(
            label: tr('pickup.section_visible'),
            // Drag-to-reorder is invisible until someone tries it, and it is
            // meaningless with a single row.
            hint: active.length > 1 ? tr('pickup.reorder_hint') : null,
          ),
          const SizedBox(height: UgamSpacing.sm),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: active.length,
            onReorderItem: _handleReorder,
            proxyDecorator: (child, index, animation) =>
                Material(color: Colors.transparent, child: child),
            itemBuilder: (ctx, i) {
              final loc = active[i];
              return Padding(
                key: ValueKey(loc.id),
                padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
                child: _row(c, loc, dragIndex: i),
              );
            },
          ),
        ],
        if (hidden.isNotEmpty) ...[
          if (active.isNotEmpty) const SizedBox(height: UgamSpacing.lg),
          _SectionHead(label: tr('pickup.section_hidden')),
          const SizedBox(height: UgamSpacing.sm),
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
    final handle = UgamScale.tap(context, 44);
    final toggleLabel =
        loc.isActive ? tr('pickup.deactivate') : tr('pickup.activate');

    return UgamCard.plain(
      elev: true,
      radius: UgamRadius.row,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.sm,
        vertical: UgamSpacing.xs,
      ),
      child: Row(
        children: [
          if (dragIndex != null)
            ReorderableDragStartListener(
              index: dragIndex,
              child: Semantics(
                label: tr('pickup.reorder_handle'),
                child: SizedBox(
                  // Was a 20pt glyph in an 8pt padding — a ~28pt grab target on
                  // the app's only drag affordance.
                  width: handle,
                  height: handle,
                  child: Center(
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 20,
                      color: c.ink3,
                    ),
                  ),
                ),
              ),
            )
          else
            const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: UgamTappable(
              onTap: () => _promptEdit(loc),
              semanticLabel: tr('pickup.edit_title'),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: handle),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
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
                            ),
                            // Wraps rather than truncating: a Gujarati place
                            // name runs ~30% longer than its English source and
                            // the name IS the row's identity.
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (dimmed) ...[
                      const SizedBox(height: UgamSpacing.xs),
                      UgamReqChip(
                        label: tr('pickup.inactive_badge'),
                        variant: UgamChipVariant.neutral,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.xs),
          Tooltip(
            message: toggleLabel,
            child: UgamIconButton(
              icon: loc.isActive
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              semanticLabel: toggleLabel,
              onTap: () => _toggleActive(loc),
            ),
          ),
          Tooltip(
            message: tr('pickup.more_actions'),
            child: UgamIconButton(
              icon: Icons.more_horiz_rounded,
              semanticLabel: tr('pickup.more_actions'),
              onTap: () => _openMore(loc),
            ),
          ),
        ],
      ),
    );
  }
}
