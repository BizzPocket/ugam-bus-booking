import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../models/tour.dart';
import '../design/components/ugam_card.dart';
import '../design/tokens.dart';
import 'tour_status_badge.dart';

class TourCard extends StatelessWidget {
  final Tour tour;
  final VoidCallback? onTap;

  const TourCard({super.key, required this.tour, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = UgamColors.of(context);

    // Was a hand-rolled Container that predated the design system and so missed
    // the whole depth upgrade: a raw 20 px corner, its own hairline border, and
    // `boxShadow: isDark ? [] : [...]` — the precise bug that was removed from
    // [UgamCard], which left the app's most-seen surface completely flat in
    // Midnight and at a different height from every card beside it in Daylight.
    //
    // [UgamCard.plain] now supplies all of it: the `card` surface, level-1
    // [UgamElevationSet.rest] in BOTH themes, [UgamRadius.card] (16, the
    // app-wide corner), and the press-scale + haptic that every other tappable
    // card already had and this one did not.
    //
    // The hairline border is intentionally NOT carried over — no [UgamCard]
    // wears one at `tone: none`, and keeping it here would make this the one
    // card in the list with an outline. Separation comes from the tonal step
    // (`card` on `bg`) plus the elevation, exactly as everywhere else.
    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Top row: title + status ──
          Row(
            children: [
              Expanded(
                child: Text(
                  tour.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              TourStatusBadge(status: tour.status, compact: true),
            ],
          ),

          const SizedBox(height: 12),

          // ── Route ──
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: c.accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                tour.fromCity,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurface.withAlpha(100),
                ),
              ),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: c.good,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                tour.toCity,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // ── Bottom row: date, passengers, price ──
          Row(
            children: [
              _Chip(
                icon: Icons.calendar_today_rounded,
                text: DateFormat('dd MMM').format(tour.departureDate),
                theme: theme,
              ),
              const SizedBox(width: 10),
              _Chip(
                icon: Icons.people_rounded,
                text: '${tour.passengerCount} pax',
                theme: theme,
              ),
              const SizedBox(width: 10),
              _Chip(
                icon: Icons.event_seat_rounded,
                text: '${tour.totalSeatsRequested} seats',
                theme: theme,
              ),
              const Spacer(),
              Text(
                '₹${tour.pricePerSeat.toStringAsFixed(0)}',
                style: GoogleFonts.outfit(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                '/seat',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withAlpha(100),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final ThemeData theme;

  const _Chip({
    required this.icon,
    required this.text,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.onSurface.withAlpha(100)),
        const SizedBox(width: 3),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withAlpha(130),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
