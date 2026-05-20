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
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/passenger_display.dart';
import '../utils/phone_normalize.dart';
import '../widgets/edit_request_sheet.dart';

class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

enum _RequestFilter { newRequests, waitlist, assigned }

class _RequestsScreenState extends State<RequestsScreen> {
  final tourCtrl = Get.find<TourController>();
  int _selectedTourIndex = 0;
  _RequestFilter _filter = _RequestFilter.newRequests;

  void _openAddRequest(Tour tour) {
    UgamSheet.show(
      context,
      title: tr('requests.sheet.title'),
      builder: (_) => _AddRequestForm(tour: tour),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
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
                      style: UgamText.titleXl.copyWith(color: c.ink),
                    ),
                  ),
                  Obx(() {
                    final tours = tourCtrl.activeTours;
                    if (tours.isEmpty) return const SizedBox.shrink();
                    if (_selectedTourIndex >= tours.length) {
                      _selectedTourIndex = 0;
                    }
                    return GestureDetector(
                      onTap: () =>
                          _openAddRequest(tours[_selectedTourIndex]),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: c.accent,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Icon(Icons.person_add_alt_rounded,
                            size: 18, color: c.onAccent),
                      ),
                    );
                  }),
                ],
              ),
            ),
            Expanded(
              child: Obx(() {
                final activeTours = tourCtrl.activeTours;
                if (activeTours.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.chat_bubble_outline_rounded,
                    title: tr('requests.empty_no_tours.title'),
                    body: tr('requests.empty_no_tours.body'),
                  );
                }

                if (_selectedTourIndex >= activeTours.length) {
                  _selectedTourIndex = 0;
                }

                final selectedTour = activeTours[_selectedTourIndex];
                final allPassengers = selectedTour.passengers;

                final newCount = allPassengers
                    .where((p) => !p.isWaitlisted && !p.isFullyAssigned)
                    .length;
                final waitlistCount =
                    allPassengers.where((p) => p.isWaitlisted).length;
                final assignedCount =
                    allPassengers.where((p) => p.isFullyAssigned).length;

                final passengers = switch (_filter) {
                  _RequestFilter.newRequests => allPassengers
                      .where((p) => !p.isWaitlisted && !p.isFullyAssigned)
                      .toList(),
                  _RequestFilter.waitlist => allPassengers
                      .where((p) => p.isWaitlisted)
                      .toList(),
                  _RequestFilter.assigned => allPassengers
                      .where((p) => p.isFullyAssigned)
                      .toList(),
                };

                return Column(
                  children: [
                    if (activeTours.length > 1)
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
                              onTap: () => setState(() {
                                _selectedTourIndex = i;
                              }),
                              behavior: HitTestBehavior.opaque,
                              child: AnimatedContainer(
                                duration: UgamMotion.tab,
                                curve: UgamMotion.easeOut,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: UgamSpacing.lg,
                                  vertical: UgamSpacing.sm,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      isActive ? c.accent : c.cardElev,
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
                    const SizedBox(height: UgamSpacing.md),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: UgamSpacing.gutter),
                      child: UgamTabPills(
                        currentIndex: _filter.index,
                        onChanged: (i) => setState(() =>
                            _filter = _RequestFilter.values[i]),
                        items: [
                          UgamTabItem(
                            label: tr('requests.filter.new'),
                            count: newCount,
                          ),
                          UgamTabItem(
                            label: tr('requests.filter.waitlist'),
                            count: waitlistCount,
                          ),
                          UgamTabItem(
                            label: tr('requests.filter.assigned'),
                            count: assignedCount,
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
                                    height: MediaQuery.of(context).size.height *
                                        0.5,
                                    child: UgamEmpty(
                                      icon: switch (_filter) {
                                        _RequestFilter.newRequests =>
                                          Icons.people_outline_rounded,
                                        _RequestFilter.waitlist =>
                                          Icons.hourglass_empty_rounded,
                                        _RequestFilter.assigned =>
                                          Icons.check_circle_outline_rounded,
                                      },
                                      title: switch (_filter) {
                                        _RequestFilter.newRequests =>
                                          tr('requests.empty_new.title'),
                                        _RequestFilter.waitlist =>
                                          tr('requests.empty_waitlist.title'),
                                        _RequestFilter.assigned =>
                                          tr('requests.empty_assigned.title'),
                                      },
                                      body: switch (_filter) {
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
                                padding: const EdgeInsets.fromLTRB(
                                  UgamSpacing.gutter,
                                  0,
                                  UgamSpacing.gutter,
                                  120,
                                ),
                                itemCount: passengers.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: UgamSpacing.md),
                                itemBuilder: (_, i) => _RequestCard(
                                  passenger: passengers[i],
                                  tour: selectedTour,
                                  c: c,
                                ),
                              ),
                      ),
                    ),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final UgamColorSet c;

  const _RequestCard({
    required this.passenger,
    required this.tour,
    required this.c,
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

    return UgamCard.plain(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.cardElev,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  _initials(passenger.name),
                  style: UgamText.bodyStrong
                      .copyWith(color: c.ink, fontSize: 12),
                ),
              ),
              const SizedBox(width: UgamSpacing.sm + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      passenger.displayName,
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
          const SizedBox(height: UgamSpacing.md),
          _CardActions(
            passenger: passenger,
            tour: tour,
            isAssigned: isAssigned,
            isWaitlisted: isWaitlisted,
            c: c,
          ),
        ],
      ),
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
                      size: 16,
                      color: isAssigned ? c.good : c.onAccent),
                  const SizedBox(width: 8),
                  Text(
                    primaryLabel,
                    style: UgamText.bodyStrong.copyWith(
                      color: isAssigned ? c.good : c.onAccent,
                      fontSize: 12.5,
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
