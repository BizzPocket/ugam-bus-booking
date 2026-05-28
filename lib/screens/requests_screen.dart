import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/request_line.dart';
import '../models/seat_type.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../routes/app_routes.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_normalize.dart';
import '../widgets/edit_request_sheet.dart';

/// Requests tab — passenger management workspace.
///
/// Layout top → bottom:
///   [Title + circle search + circle "+"]
///   [Collapsible search bar]
///   [Tour selector pills (active solid accent)]
///   [Stats strip: New / Waitlist / Assigned counts]
///   [Filter pills mirror the stats]
///   [Passenger list (dense _RequestCard with avatar / chips / actions)]
///   [Sticky bottom CTA → seat assignment]
///
/// Selection mode is entered via long-press. While active the bottom CTA
/// is replaced by a bulk-action bar (Waitlist / Send WA / Cancel).
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

enum _RequestFilter { newRequests, waitlist, assigned }

class _RequestsScreenState extends State<RequestsScreen> {
  final tourCtrl = Get.find<TourController>();
  final _searchCtrl = TextEditingController();

  int _selectedTourIndex = 0;
  _RequestFilter _filter = _RequestFilter.newRequests;
  bool _searchVisible = false;
  String _query = '';

  // ── Bulk selection state ─────────────────────────────────────
  bool _selectionMode = false;
  final Set<String> _selectedIds = <String>{};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    HapticFeedback.selectionClick();
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchCtrl.clear();
        _query = '';
      }
    });
  }

  void _openAddRequest(Tour tour) {
    UgamSheet.show(
      context,
      title: tr('requests.sheet.title'),
      builder: (_) => _AddRequestForm(tour: tour),
    );
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelect(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        if (_selectedIds.isEmpty) _selectionMode = false;
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _enterSelection(String id) {
    HapticFeedback.mediumImpact();
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  Future<void> _bulkWaitlist(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    for (final id in ids) {
      await tourCtrl.setWaitlisted(tour.id, id, true);
    }
    if (!mounted) return;
    AppSnackBar.success(
      'Moved ${ids.length} to waitlist',
    );
    _exitSelection();
  }

  Future<void> _bulkSendWA(Tour tour) async {
    final ids = List<String>.from(_selectedIds);
    int opened = 0;
    for (final id in ids) {
      final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
      if (p == null) continue;
      final ok = await WhatsAppService().sendAck(passenger: p, tour: tour);
      if (ok) opened++;
    }
    if (!mounted) return;
    if (opened > 0) {
      AppSnackBar.success('Opened $opened WhatsApp chats');
    } else {
      AppSnackBar.error(tr('requests.snack.ack_error'));
    }
    _exitSelection();
  }

  // ── Build ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          final activeTours = tourCtrl.activeTours;
          if (_selectedTourIndex >= activeTours.length) {
            _selectedTourIndex = 0;
          }
          final Tour? selectedTour =
              activeTours.isEmpty ? null : activeTours[_selectedTourIndex];

          return Stack(
            children: [
              Column(
                children: [
                  _TopBar(
                    c: c,
                    searchActive: _searchVisible,
                    onToggleSearch: _toggleSearch,
                    onAdd: selectedTour == null
                        ? null
                        : () => _openAddRequest(selectedTour),
                    selectionMode: _selectionMode,
                    selectedCount: _selectedIds.length,
                    onExitSelection: _exitSelection,
                  ),
                  AnimatedSize(
                    duration: UgamMotion.tab,
                    curve: UgamMotion.easeOut,
                    child: _searchVisible
                        ? _SearchField(
                            c: c,
                            controller: _searchCtrl,
                            onChanged: (v) =>
                                setState(() => _query = v.trim()),
                          )
                        : const SizedBox.shrink(),
                  ),
                  Expanded(
                    child: activeTours.isEmpty
                        ? UgamEmpty(
                            icon: Icons.chat_bubble_outline_rounded,
                            title: tr('requests.empty_no_tours.title'),
                            body: tr('requests.empty_no_tours.body'),
                          )
                        : _buildBody(activeTours, selectedTour!, c),
                  ),
                ],
              ),
              if (selectedTour != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _selectionMode
                      ? _BulkActionBar(
                          c: c,
                          count: _selectedIds.length,
                          onWaitlist: () => _bulkWaitlist(selectedTour),
                          onSendWA: () => _bulkSendWA(selectedTour),
                          onCancel: _exitSelection,
                        )
                      : _AssignmentCTA(
                          tour: selectedTour,
                          c: c,
                        ),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildBody(List<Tour> activeTours, Tour selectedTour, UgamColorSet c) {
    final allPassengers = selectedTour.passengers;

    final newList = allPassengers
        .where((p) => !p.isWaitlisted && !p.isFullyAssigned)
        .toList();
    final waitlistList =
        allPassengers.where((p) => p.isWaitlisted).toList();
    final assignedList =
        allPassengers.where((p) => p.isFullyAssigned).toList();

    final base = switch (_filter) {
      _RequestFilter.newRequests => newList,
      _RequestFilter.waitlist => waitlistList,
      _RequestFilter.assigned => assignedList,
    };

    final q = _query.toLowerCase();
    final passengers = q.isEmpty
        ? base
        : base
            .where((p) =>
                p.displayName.toLowerCase().contains(q) ||
                p.phone.toLowerCase().contains(q))
            .toList();

    return Column(
      children: [
        if (activeTours.length > 1) ...[
          const SizedBox(height: UgamSpacing.xs),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.gutter,
              ),
              itemCount: activeTours.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: UgamSpacing.sm),
              itemBuilder: (_, i) {
                final tour = activeTours[i];
                final isActive = i == _selectedTourIndex;
                return GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _selectedTourIndex = i;
                      _exitSelection();
                    });
                  },
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedContainer(
                    duration: UgamMotion.tab,
                    curve: UgamMotion.easeOut,
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.lg,
                      vertical: UgamSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: isActive ? c.accent : c.cardElev,
                      borderRadius:
                          BorderRadius.circular(UgamRadius.chip),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      tour.title,
                      style: UgamText.bodyStrong.copyWith(
                        color: isActive ? c.onAccent : c.ink2,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: UgamSpacing.md),
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
          child: _StatsStrip(
            c: c,
            newCount: newList.length,
            waitlistCount: waitlistList.length,
            assignedCount: assignedList.length,
            current: _filter,
            onTap: (f) {
              HapticFeedback.selectionClick();
              setState(() => _filter = f);
            },
          ),
        ),
        const SizedBox(height: UgamSpacing.md),
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
          child: UgamTabPills(
            currentIndex: _filter.index,
            onChanged: (i) =>
                setState(() => _filter = _RequestFilter.values[i]),
            items: [
              UgamTabItem(
                label: tr('requests.filter.new'),
                count: newList.length,
              ),
              UgamTabItem(
                label: tr('requests.filter.waitlist'),
                count: waitlistList.length,
              ),
              UgamTabItem(
                label: tr('requests.filter.assigned'),
                count: assignedList.length,
              ),
            ],
          ),
        ),
        const SizedBox(height: UgamSpacing.lg),
        Expanded(
          child: RefreshIndicator(
            color: c.accent,
            onRefresh: tourCtrl.refreshTours,
            child: passengers.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    children: [
                      SizedBox(
                        height:
                            MediaQuery.of(context).size.height * 0.45,
                        child: UgamEmpty(
                          icon: _query.isNotEmpty
                              ? Icons.search_off_rounded
                              : switch (_filter) {
                                  _RequestFilter.newRequests =>
                                    Icons.people_outline_rounded,
                                  _RequestFilter.waitlist =>
                                    Icons.hourglass_empty_rounded,
                                  _RequestFilter.assigned =>
                                    Icons.check_circle_outline_rounded,
                                },
                          title: _query.isNotEmpty
                              ? 'No matches'
                              : switch (_filter) {
                                  _RequestFilter.newRequests =>
                                    tr('requests.empty_new.title'),
                                  _RequestFilter.waitlist =>
                                    tr('requests.empty_waitlist.title'),
                                  _RequestFilter.assigned =>
                                    tr('requests.empty_assigned.title'),
                                },
                          body: _query.isNotEmpty
                              ? 'No passengers match "$_query".'
                              : switch (_filter) {
                                  _RequestFilter.newRequests =>
                                    tr('requests.empty_new.body'),
                                  _RequestFilter.waitlist =>
                                    tr('requests.empty_waitlist.body'),
                                  _RequestFilter.assigned =>
                                    tr('requests.empty_assigned.body'),
                                },
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      0,
                      UgamSpacing.gutter,
                      _selectionMode ? 110 : 160,
                    ),
                    itemCount: passengers.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UgamSpacing.md),
                    itemBuilder: (_, i) {
                      final p = passengers[i];
                      final selected = _selectedIds.contains(p.id);
                      return _RequestCard(
                        passenger: p,
                        tour: selectedTour,
                        c: c,
                        selectionMode: _selectionMode,
                        selected: selected,
                        onLongPress: () => _enterSelection(p.id),
                        onSelectTap: () => _toggleSelect(p.id),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

// ─── Top bar ──────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final bool searchActive;
  final VoidCallback onToggleSearch;
  final VoidCallback? onAdd;
  final bool selectionMode;
  final int selectedCount;
  final VoidCallback onExitSelection;

  const _TopBar({
    required this.c,
    required this.searchActive,
    required this.onToggleSearch,
    required this.onAdd,
    required this.selectionMode,
    required this.selectedCount,
    required this.onExitSelection,
  });

  @override
  Widget build(BuildContext context) {
    if (selectionMode) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.lg,
          UgamSpacing.gutter,
          UgamSpacing.md,
        ),
        child: Row(
          children: [
            _CircleBtn(
              icon: Icons.close_rounded,
              c: c,
              onTap: onExitSelection,
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                '$selectedCount selected',
                style: UgamText.titleM.copyWith(color: c.ink, fontSize: 18),
              ),
            ),
          ],
        ),
      );
    }

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
            child: Text(
              tr('requests.title'),
              style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 28),
            ),
          ),
          _CircleBtn(
            icon: searchActive ? Icons.close_rounded : Icons.search_rounded,
            c: c,
            onTap: onToggleSearch,
            active: searchActive,
          ),
          const SizedBox(width: UgamSpacing.sm),
          GestureDetector(
            onTap: onAdd,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: onAdd == null
                    ? c.accent.withValues(alpha: 0.4)
                    : c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.person_add_alt_rounded,
                  size: 19, color: c.onAccent),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final UgamColorSet c;
  final VoidCallback onTap;
  final bool active;
  const _CircleBtn({
    required this.icon,
    required this.c,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: active ? c.accentFill : c.cardElev,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 19, color: active ? c.accent : c.ink),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final UgamColorSet c;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({
    required this.c,
    required this.controller,
    required this.onChanged,
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
      child: Container(
        height: 48,
        padding:
            const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          children: [
            Icon(Icons.search_rounded, size: 18, color: c.ink2),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                onChanged: onChanged,
                style: UgamText.body.copyWith(color: c.ink, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Search name or phone…',
                  hintStyle:
                      UgamText.body.copyWith(color: c.ink3, fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Stats strip ──────────────────────────────────────────────────────

class _StatsStrip extends StatelessWidget {
  final UgamColorSet c;
  final int newCount;
  final int waitlistCount;
  final int assignedCount;
  final _RequestFilter current;
  final ValueChanged<_RequestFilter> onTap;

  const _StatsStrip({
    required this.c,
    required this.newCount,
    required this.waitlistCount,
    required this.assignedCount,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatTile(
            c: c,
            value: newCount,
            label: 'New',
            tone: UgamStatusTone.accent,
            active: current == _RequestFilter.newRequests,
            onTap: () => onTap(_RequestFilter.newRequests),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Expanded(
          child: _StatTile(
            c: c,
            value: waitlistCount,
            label: 'Waitlist',
            tone: UgamStatusTone.warm,
            active: current == _RequestFilter.waitlist,
            onTap: () => onTap(_RequestFilter.waitlist),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Expanded(
          child: _StatTile(
            c: c,
            value: assignedCount,
            label: 'Assigned',
            tone: UgamStatusTone.good,
            active: current == _RequestFilter.assigned,
            onTap: () => onTap(_RequestFilter.assigned),
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final UgamColorSet c;
  final int value;
  final String label;
  final UgamStatusTone tone;
  final bool active;
  final VoidCallback onTap;

  const _StatTile({
    required this.c,
    required this.value,
    required this.label,
    required this.tone,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = switch (tone) {
      UgamStatusTone.accent => c.accent,
      UgamStatusTone.good => c.good,
      UgamStatusTone.warm => c.warm,
      UgamStatusTone.neutral => c.ink2,
    };
    final fill = switch (tone) {
      UgamStatusTone.accent => c.accentFill,
      UgamStatusTone.good => c.goodFill,
      UgamStatusTone.warm => c.warmFill,
      UgamStatusTone.neutral => c.cardElev,
    };
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: active ? fill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.stat),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$value',
              style: UgamText.tabular(
                UgamText.numLg.copyWith(
                  color: active ? accent : c.ink,
                  fontSize: 22,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label.toUpperCase(),
              style: UgamText.micro.copyWith(
                color: active ? accent : c.ink3,
                fontSize: 9.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Assignment CTA ───────────────────────────────────────────────────

class _AssignmentCTA extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _AssignmentCTA({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final remaining =
        (tour.totalSeatsRequested - tour.totalSeatsAssigned).clamp(0, 99999);
    final hasBus = tour.buses.isNotEmpty;
    return UgamStickyCTA(
      child: UgamCTA(
        label: hasBus
            ? 'Seat assignment · ${tour.title}'
            : 'Add a bus to start assigning',
        leadingIcon: Icons.grid_view_rounded,
        trailingValue: hasBus && remaining > 0 ? '$remaining left' : null,
        onPressed: hasBus
            ? () {
                HapticFeedback.lightImpact();
                Get.toNamed(
                  AppRoutes.seatAssignment,
                  arguments: {'tourId': tour.id},
                );
              }
            : null,
      ),
    );
  }
}

// ─── Bulk action bar ──────────────────────────────────────────────────

class _BulkActionBar extends StatelessWidget {
  final UgamColorSet c;
  final int count;
  final VoidCallback onWaitlist;
  final VoidCallback onSendWA;
  final VoidCallback onCancel;

  const _BulkActionBar({
    required this.c,
    required this.count,
    required this.onWaitlist,
    required this.onSendWA,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.xxl,
          UgamSpacing.gutter,
          UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [c.bg.withValues(alpha: 0), c.bg],
            stops: const [0, 0.35],
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.sm),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Expanded(
                child: _BulkBtn(
                  icon: Icons.hourglass_top_rounded,
                  label: 'Waitlist',
                  onTap: count == 0 ? null : onWaitlist,
                  c: c,
                ),
              ),
              Expanded(
                child: _BulkBtn(
                  icon: Icons.chat_rounded,
                  label: 'Send WA',
                  primary: true,
                  onTap: count == 0 ? null : onSendWA,
                  c: c,
                ),
              ),
              Expanded(
                child: _BulkBtn(
                  icon: Icons.close_rounded,
                  label: 'Cancel',
                  onTap: onCancel,
                  c: c,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BulkBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final UgamColorSet c;
  const _BulkBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.c,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final bg = primary
        ? (enabled ? c.accent : c.accent.withValues(alpha: 0.4))
        : Colors.transparent;
    final fg = primary ? c.onAccent : (enabled ? c.ink : c.ink3);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: UgamText.bodyStrong.copyWith(color: fg, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Passenger card ───────────────────────────────────────────────────

class _RequestCard extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final UgamColorSet c;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onLongPress;
  final VoidCallback onSelectTap;

  const _RequestCard({
    required this.passenger,
    required this.tour,
    required this.c,
    required this.selectionMode,
    required this.selected,
    required this.onLongPress,
    required this.onSelectTap,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) {
      return tr('requests.time.days_ago',
          namedArgs: {'n': '${diff.inDays}'});
    }
    if (diff.inHours > 0) {
      return tr('requests.time.hours_ago',
          namedArgs: {'n': '${diff.inHours}'});
    }
    if (diff.inMinutes > 0) {
      return tr('requests.time.minutes_ago',
          namedArgs: {'n': '${diff.inMinutes}'});
    }
    return tr('requests.time.just_now');
  }

  @override
  Widget build(BuildContext context) {
    final isAssigned = passenger.isFullyAssigned;
    final isWaitlisted = passenger.isWaitlisted;

    Widget leading;
    if (selectionMode) {
      leading = Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: selected ? c.accent : c.cardElev,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? c.accent : c.border,
            width: 1.5,
          ),
        ),
        alignment: Alignment.center,
        child: selected
            ? Icon(Icons.check_rounded, size: 18, color: c.onAccent)
            : null,
      );
    } else {
      leading = Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: c.cardElev,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text(
          _initials(passenger.name),
          style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12),
        ),
      );
    }

    final card = AnimatedContainer(
      duration: UgamMotion.tab,
      curve: UgamMotion.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(
          color: selected ? c.accent : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: UgamCard.plain(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                leading,
                const SizedBox(width: UgamSpacing.sm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        passenger.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: UgamText.titleS
                            .copyWith(color: c.ink, fontSize: 14),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _timeAgo(passenger.createdAt),
                        style: UgamText.caption
                            .copyWith(color: c.ink3, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                UgamReqChip(
                  label: isAssigned
                      ? tr('requests.status.seats_assigned').toUpperCase()
                      : isWaitlisted
                          ? tr('requests.status.waitlist').toUpperCase()
                          : tr('requests.status.new').toUpperCase(),
                  variant: isAssigned
                      ? UgamChipVariant.good
                      : isWaitlisted
                          ? UgamChipVariant.warm
                          : UgamChipVariant.accent,
                ),
              ],
            ),
            if (passenger.note != null && passenger.note!.isNotEmpty) ...[
              const SizedBox(height: UgamSpacing.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md,
                  vertical: UgamSpacing.sm + 2,
                ),
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.chat_bubble_outline_rounded,
                        size: 16, color: c.ink3),
                    const SizedBox(width: UgamSpacing.sm),
                    Expanded(
                      child: Text(
                        '"${passenger.note}"',
                        style: UgamText.caption.copyWith(
                          color: c.ink2,
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (passenger.requestLines.isNotEmpty) ...[
              const SizedBox(height: UgamSpacing.md),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  UgamReqChip(
                    label: passenger.isPartiallyAssigned
                        ? '${passenger.totalSeatsAssigned}/${passenger.totalSeatsRequested} SEATS'
                        : '${passenger.totalSeatsRequested} SEATS',
                    variant: isAssigned
                        ? UgamChipVariant.good
                        : UgamChipVariant.accent,
                  ),
                  UgamReqChip(
                    label: passenger.requestLines
                        .map((l) => l.label)
                        .join(' + ')
                        .toUpperCase(),
                    variant: isAssigned
                        ? UgamChipVariant.good
                        : UgamChipVariant.accent,
                  ),
                  if (passenger.tripType.isOneWay)
                    UgamReqChip(
                      label: passenger.tripType == TripType.outboundOnly
                          ? tr('requests.chip.trip_outbound', namedArgs: {
                              'from': tour.fromCity,
                              'to': tour.toCity,
                            }).toUpperCase()
                          : tr('requests.chip.trip_return', namedArgs: {
                              'from': tour.toCity,
                              'to': tour.fromCity,
                            }).toUpperCase(),
                      variant: UgamChipVariant.warm,
                    ),
                ],
              ),
            ],
            if (!selectionMode) ...[
              const SizedBox(height: UgamSpacing.md),
              _CardActions(
                passenger: passenger,
                tour: tour,
                isAssigned: isAssigned,
                isWaitlisted: isWaitlisted,
                c: c,
              ),
            ],
          ],
        ),
      ),
    );

    return GestureDetector(
      onLongPress: selectionMode ? null : onLongPress,
      onTap: selectionMode ? onSelectTap : null,
      behavior: HitTestBehavior.opaque,
      child: card,
    );
  }
}

class _CardActions extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final bool isAssigned;
  final bool isWaitlisted;
  final UgamColorSet c;

  const _CardActions({
    required this.passenger,
    required this.tour,
    required this.isAssigned,
    required this.isWaitlisted,
    required this.c,
  });

  TourController get _ctrl => Get.find<TourController>();

  Future<void> _sendAck() async {
    final sent = await WhatsAppService().sendAck(
      passenger: passenger,
      tour: tour,
    );
    if (sent) {
      AppSnackBar.success(
        tr('requests.snack.ack_opened',
            namedArgs: {'name': passenger.displayName}),
        title: tr('requests.snack.ack_title'),
      );
    } else {
      AppSnackBar.error(tr('requests.snack.ack_error'));
    }
  }

  Future<void> _toWaitlist() async {
    await _ctrl.setWaitlisted(tour.id, passenger.id, true);
    AppSnackBar.success(tr('requests.snack.moved_to_waitlist',
        namedArgs: {'name': passenger.displayName}));
  }

  Future<void> _promote() async {
    await _ctrl.setWaitlisted(tour.id, passenger.id, false);
    AppSnackBar.success(tr('requests.snack.promoted_to_new',
        namedArgs: {'name': passenger.displayName}));
  }

  Future<void> _unassignAll() async {
    await _ctrl.unassignSeats(tour.id, passenger.id);
    AppSnackBar.success(tr('requests.snack.seats_cleared',
        namedArgs: {'name': passenger.displayName}));
  }

  Future<void> _confirmDecline() async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: Text(tr('requests.decline_dialog.title')),
        content: Text(tr('requests.decline_dialog.body',
            namedArgs: {'name': passenger.displayName})),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: Text(tr('app.action.cancel')),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            style: TextButton.styleFrom(foregroundColor: c.danger),
            child: Text(tr('requests.decline_dialog.confirm')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _ctrl.removePassenger(tour.id, passenger.id);
    AppSnackBar.success(
      tr('requests.snack.declined_body',
          namedArgs: {'name': passenger.displayName}),
      title: tr('requests.snack.declined_title'),
    );
  }

  void _openAssignment() {
    Get.toNamed('/seat-assignment', arguments: {
      'tourId': tour.id,
      'passengerId': passenger.id,
    });
  }

  void _openEdit(BuildContext context) {
    EditRequestSheet.show(
      context: context,
      tour: tour,
      passenger: passenger,
    );
  }

  @override
  Widget build(BuildContext context) {
    final String primaryLabel;
    final IconData primaryIcon;
    final VoidCallback primaryAction;
    final List<_MenuItem> menu;

    final editItem = _MenuItem(
      tr('requests.action.edit_request'),
      Icons.edit_rounded,
      () => _openEdit(context),
    );

    if (isAssigned) {
      primaryLabel = tr('requests.action.view_assignment');
      primaryIcon = Icons.visibility_rounded;
      primaryAction = _openAssignment;
      menu = [
        editItem,
        _MenuItem(tr('requests.action.send_wa_ack'), Icons.chat_rounded,
            _sendAck),
        _MenuItem(tr('requests.action.unassign_all'), Icons.replay_rounded,
            _unassignAll),
      ];
    } else if (isWaitlisted) {
      primaryLabel = tr('requests.action.back_to_new');
      primaryIcon = Icons.arrow_back_rounded;
      primaryAction = _promote;
      menu = [
        editItem,
        _MenuItem(tr('requests.action.send_wa_ack'), Icons.chat_rounded,
            _sendAck),
        _MenuItem(tr('requests.action.decline_request'),
            Icons.close_rounded, _confirmDecline,
            isDanger: true),
      ];
    } else {
      primaryLabel = tr('requests.action.assign_seats');
      primaryIcon = Icons.grid_view_rounded;
      primaryAction = _openAssignment;
      menu = [
        editItem,
        _MenuItem(tr('requests.action.send_wa_ack'), Icons.chat_rounded,
            _sendAck),
        _MenuItem(tr('requests.action.move_to_waitlist'),
            Icons.hourglass_top_rounded, _toWaitlist),
        _MenuItem(tr('requests.action.decline_request'),
            Icons.close_rounded, _confirmDecline,
            isDanger: true),
      ];
    }

    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: primaryAction,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: isAssigned ? c.goodFill : c.accent,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(primaryIcon,
                      size: 16, color: isAssigned ? c.good : c.onAccent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      primaryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UgamText.bodyStrong.copyWith(
                        color: isAssigned ? c.good : c.onAccent,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.cardElev,
            shape: BoxShape.circle,
          ),
          child: PopupMenuButton<_MenuItem>(
            tooltip: tr('requests.action.more_actions'),
            icon: Icon(Icons.more_vert_rounded, size: 18, color: c.ink2),
            position: PopupMenuPosition.under,
            onSelected: (item) => item.onTap(),
            color: c.card,
            itemBuilder: (_) => [
              for (final item in menu)
                PopupMenuItem<_MenuItem>(
                  value: item,
                  child: Row(
                    children: [
                      Icon(item.icon,
                          size: 16,
                          color: item.isDanger ? c.danger : c.ink2),
                      const SizedBox(width: UgamSpacing.sm + 2),
                      Text(
                        item.label,
                        style: UgamText.body.copyWith(
                          color: item.isDanger ? c.danger : c.ink,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MenuItem {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDanger;

  const _MenuItem(this.label, this.icon, this.onTap,
      {this.isDanger = false});
}

// ─── Add request sheet ────────────────────────────────────────────────

/// Bottom-sheet form for the agent-side direct-add flow.
class _AddRequestForm extends StatefulWidget {
  final Tour tour;

  const _AddRequestForm({required this.tour});

  @override
  State<_AddRequestForm> createState() => _AddRequestFormState();
}

class _AddRequestFormState extends State<_AddRequestForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _note = TextEditingController();
  int _doubleSofa = 0;
  int _singleSofa = 0;
  TripType _tripType = TripType.roundTrip;
  bool _saving = false;

  int get _totalSeats => _doubleSofa + _singleSofa;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    if (name.isEmpty) {
      AppSnackBar.error(tr('requests.validation.name_required'));
      return;
    }
    if (phone.length != 10) {
      AppSnackBar.error(tr('requests.validation.phone_invalid'));
      return;
    }
    if (_totalSeats == 0) {
      AppSnackBar.error(tr('requests.validation.seat_required'));
      return;
    }
    setState(() => _saving = true);
    try {
      final note = _note.text.trim();
      final requestLines = <RequestLine>[
        if (_doubleSofa > 0)
          RequestLine(seatType: SeatType.doubleSofa, qty: _doubleSofa),
        if (_singleSofa > 0)
          RequestLine(seatType: SeatType.singleSofa, qty: _singleSofa),
      ];
      final passenger = Passenger(
        tourId: widget.tour.id,
        name: name,
        phone: '+91${normalisePhone(phone)}',
        requestLines: requestLines,
        note: note.isEmpty ? null : note,
        tripType: _tripType,
      );
      await Get.find<TourController>()
          .addPassenger(widget.tour.id, passenger);
      if (!mounted) return;
      Get.back();
      AppSnackBar.success(
        _totalSeats == 1
            ? tr('requests.snack.added_one', namedArgs: {'name': name})
            : tr('requests.snack.added_many',
                namedArgs: {'name': name, 'count': '$_totalSeats'}),
      );
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('requests.snack.add_error'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            tr('requests.sheet.subtitle',
                namedArgs: {'tourTitle': widget.tour.title}),
            style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('requests.sheet.name_label'),
            hint: tr('requests.sheet.name_hint'),
            controller: _name,
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamPhoneInput(
            controller: _phone,
            label: tr('requests.sheet.phone_label'),
          ),
          const SizedBox(height: UgamSpacing.lg),
          Text(
            tr('requests.sheet.trip_type_label').toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamTabPills(
            currentIndex: TripType.values.indexOf(_tripType),
            onChanged: (i) =>
                setState(() => _tripType = TripType.values[i]),
            items: [
              UgamTabItem(label: tr('requests.sheet.trip_round')),
              UgamTabItem(
                label: tr('requests.sheet.trip_outbound', namedArgs: {
                  'from': widget.tour.fromCity,
                  'to': widget.tour.toCity,
                }),
              ),
              UgamTabItem(
                label: tr('requests.sheet.trip_return', namedArgs: {
                  'from': widget.tour.toCity,
                  'to': widget.tour.fromCity,
                }),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          _SeatCounter(
            label: tr('requests.sheet.double_sofa'),
            value: _doubleSofa,
            onChanged: (v) => setState(() => _doubleSofa = v),
            c: c,
          ),
          const SizedBox(height: UgamSpacing.sm),
          _SeatCounter(
            label: tr('requests.sheet.single_sofa'),
            value: _singleSofa,
            onChanged: (v) => setState(() => _singleSofa = v),
            c: c,
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('requests.sheet.note_label'),
            hint: tr('requests.sheet.note_hint'),
            controller: _note,
            maxLength: 160,
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving
                ? tr('requests.sheet.saving')
                : tr('requests.sheet.save'),
            leadingIcon: Icons.check_rounded,
            loading: _saving,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}

class _SeatCounter extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final UgamColorSet c;

  const _SeatCounter({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: UgamText.body.copyWith(color: c.ink, fontSize: 14),
            ),
          ),
          GestureDetector(
            onTap: value > 0
                ? () {
                    HapticFeedback.lightImpact();
                    onChanged(value - 1);
                  }
                : null,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: value > 0 ? c.accent : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.remove_rounded,
                  size: 16, color: value > 0 ? c.onAccent : c.ink3),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: UgamText.tabular(
                UgamText.titleS.copyWith(color: c.ink, fontSize: 16),
              ),
            ),
          ),
          GestureDetector(
            onTap: value < 10
                ? () {
                    HapticFeedback.lightImpact();
                    onChanged(value + 1);
                  }
                : null,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: value < 10 ? c.accent : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.add_rounded,
                  size: 16, color: value < 10 ? c.onAccent : c.ink3),
            ),
          ),
        ],
      ),
    );
  }
}
