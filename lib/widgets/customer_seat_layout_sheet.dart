import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../models/bus_details.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../services/customer_requests_store.dart';

/// Read-only seat layout viewer for the customer "My Requests" screen.
/// Shows the customer's assigned seats highlighted on the actual bus
/// layout. Seats from other passengers render as neutral, since the
/// customer should not see who else is on the bus.
Future<void> showCustomerSeatLayoutSheet(
  BuildContext context, {
  required CustomerRequestEntry entry,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _CustomerSeatLayoutSheet(entry: entry),
  );
}

class _CustomerSeatLayoutSheet extends StatefulWidget {
  final CustomerRequestEntry entry;

  const _CustomerSeatLayoutSheet({required this.entry});

  @override
  State<_CustomerSeatLayoutSheet> createState() =>
      _CustomerSeatLayoutSheetState();
}

class _CustomerSeatLayoutSheetState extends State<_CustomerSeatLayoutSheet> {
  final _store = CustomerRequestsStore();
  bool _loading = true;
  String? _error;
  List<Bus> _buses = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final buses = await _store.busLayoutsForRequest(widget.entry.id);
      if (!mounted) return;
      setState(() {
        _buses = buses;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = tr('customer_my_requests.layout_load_error');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * 0.85;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) {
        return Container(
          constraints: BoxConstraints(maxHeight: maxHeight),
          decoration: BoxDecoration(
            color: AppColors.surface(context),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _grabHandle(),
              _header(),
              Divider(height: 1, color: AppColors.border(context)),
              Expanded(child: _body(scrollController)),
            ],
          ),
        );
      },
    );
  }

  Widget _grabHandle() {
    return Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.only(top: 12, bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.border(context),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _header() {
    final assignedCount = widget.entry.assignedSeats.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('customer_my_requests.layout_sheet_title'),
                  style: GoogleFonts.inter(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  tr(
                    'customer_my_requests.layout_sheet_subtitle',
                    namedArgs: {'count': assignedCount.toString()},
                  ),
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: AppColors.textMuted(context),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 22),
            onPressed: () => Navigator.of(context).maybePop(),
            color: AppColors.textMuted(context),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _body(ScrollController controller) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _state(
        icon: Icons.cloud_off_rounded,
        title: tr('customer_my_requests.layout_load_error_title'),
        body: _error!,
      );
    }
    if (_buses.isEmpty) {
      return _state(
        icon: Icons.event_seat_outlined,
        title: tr('customer_my_requests.layout_empty_title'),
        body: tr('customer_my_requests.layout_empty_body'),
      );
    }

    final mySeats = widget.entry.assignedSeats;
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      itemCount: _buses.length,
      separatorBuilder: (_, _) => const SizedBox(height: 20),
      itemBuilder: (_, i) {
        final bus = _buses[i];
        final mineOnThisBus = mySeats
            .where((s) => s.busId == bus.id)
            .map((s) => s.seatId)
            .toSet();
        return _BusLayoutCard(bus: bus, mySeatIds: mineOnThisBus);
      },
    );
  }

  Widget _state({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textMuted(context)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.text(context),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                color: AppColors.textMuted(context),
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BusLayoutCard extends StatefulWidget {
  final Bus bus;
  final Set<String> mySeatIds;

  const _BusLayoutCard({required this.bus, required this.mySeatIds});

  @override
  State<_BusLayoutCard> createState() => _BusLayoutCardState();
}

class _BusLayoutCardState extends State<_BusLayoutCard> {
  bool _showUpper = false;

  @override
  Widget build(BuildContext context) {
    final layout = widget.bus.layout;
    final hasLower = layout != null && layout.lowerDeck.any((c) => c.hasSeat);
    final hasUpper = layout != null && layout.upperDeck.any((c) => c.hasSeat);
    // If only upper has seats, default to that.
    if (!hasLower && hasUpper && !_showUpper) {
      _showUpper = true;
    }

    return Container(
      decoration: BoxDecoration(
        color: AppColors.bg(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border(context)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _busHeader(),
          if (layout == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                tr('customer_my_requests.layout_unavailable'),
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: AppColors.textMuted(context),
                ),
              ),
            )
          else ...[
            if (hasLower && hasUpper) ...[
              const SizedBox(height: 10),
              _deckToggle(),
            ],
            const SizedBox(height: 12),
            _SeatGrid(
              layout: layout,
              isUpper: _showUpper,
              mySeatIds: widget.mySeatIds,
            ),
            const SizedBox(height: 12),
            _legend(),
          ],
        ],
      ),
    );
  }

  Widget _busHeader() {
    final mine = widget.mySeatIds.toList()..sort();
    return Row(
      children: [
        const Icon(
          Icons.directions_bus_rounded,
          size: 18,
          color: AppTheme.brand,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.bus.busNumber.isNotEmpty
                    ? '${widget.bus.name} · ${widget.bus.busNumber}'
                    : widget.bus.name,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text(context),
                ),
              ),
              if (mine.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    tr(
                      'customer_my_requests.layout_your_seats',
                      namedArgs: {'seats': mine.join(', ')},
                    ),
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.brand,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _deckToggle() {
    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Row(
        children: [
          _deckChip(
            label: tr('customer_my_requests.layout_deck_lower'),
            active: !_showUpper,
            onTap: () => setState(() => _showUpper = false),
          ),
          _deckChip(
            label: tr('customer_my_requests.layout_deck_upper'),
            active: _showUpper,
            onTap: () => setState(() => _showUpper = true),
          ),
        ],
      ),
    );
  }

  Widget _deckChip({
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: active ? AppTheme.brand : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.white : AppColors.textMuted(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _legend() {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        _legendItem(
          color: AppTheme.brand,
          textColor: Colors.white,
          label: tr('customer_my_requests.layout_legend_mine'),
        ),
        _legendItem(
          color: const Color(0xFFE2E8F0),
          textColor: AppColors.textMuted(context),
          label: tr('customer_my_requests.layout_legend_other'),
        ),
      ],
    );
  }

  Widget _legendItem({
    required Color color,
    required Color textColor,
    required String label,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            color: AppColors.textMuted(context),
          ),
        ),
      ],
    );
  }
}

class _SeatGrid extends StatelessWidget {
  final BusLayout layout;
  final bool isUpper;
  final Set<String> mySeatIds;

  const _SeatGrid({
    required this.layout,
    required this.isUpper,
    required this.mySeatIds,
  });

  @override
  Widget build(BuildContext context) {
    final deck = isUpper ? layout.upperDeck : layout.lowerDeck;
    final cols = layout.cols;
    var maxRow = -1;
    for (final c in deck) {
      if (c.hasSeat && c.row > maxRow) maxRow = c.row;
    }
    if (maxRow < 0) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          tr('customer_my_requests.layout_deck_empty'),
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 12,
            color: AppColors.textMuted(context),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border(context)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(
                Icons.account_circle_rounded,
                size: 18,
                color: AppColors.textMuted(context),
              ),
              const SizedBox(width: 6),
              Text(
                tr('customer_my_requests.layout_driver'),
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                  color: AppColors.textMuted(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: AppColors.border(context)),
          const SizedBox(height: 10),
          for (int r = 0; r <= maxRow; r++) ...[
            _row(context, deck, r, cols),
            if (r < maxRow) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, List<SeatCell> deck, int row, int cols) {
    final children = <Widget>[];
    final aisleAt = cols ~/ 2;
    for (int c = 0; c < cols; c++) {
      if (c == aisleAt) {
        children.add(const SizedBox(width: 18));
      }
      final cell = deck.firstWhere(
        (s) => s.row == row && s.col == c,
        orElse: () => SeatCell(row: row, col: c),
      );
      children.add(_cellWidget(context, cell));
      if (c < cols - 1 && c != aisleAt - 1) {
        children.add(const SizedBox(width: 6));
      }
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: children,
    );
  }

  Widget _cellWidget(BuildContext context, SeatCell cell) {
    const double w = 46;
    const double h = 40;
    if (cell.isEmpty) {
      return const SizedBox(width: w, height: h);
    }
    final isMine = cell.seatId != null && mySeatIds.contains(cell.seatId);
    final bg = isMine ? AppTheme.brand : const Color(0xFFF1F5F9);
    final border = isMine ? AppTheme.brand : AppColors.border(context);
    final fg = isMine ? Colors.white : AppColors.textMuted(context);
    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: isMine ? 1.5 : 1),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            cell.seatId ?? '',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
          if (cell.seatType != null)
            Text(
              _shortType(cell.seatType!),
              style: GoogleFonts.inter(
                fontSize: 8,
                fontWeight: FontWeight.w600,
                color: fg.withValues(alpha: 0.85),
                letterSpacing: 0.4,
              ),
            ),
        ],
      ),
    );
  }

  String _shortType(SeatType t) {
    switch (t) {
      case SeatType.singleSofa:
        return 'SINGLE';
      case SeatType.doubleSofa:
        return 'DOUBLE';
      case SeatType.seater:
        return 'SEATER';
    }
  }
}
