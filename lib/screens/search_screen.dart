import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../controllers/tour_controller.dart';
import '../models/tour.dart';
import '../models/passenger.dart';
import '../components/passenger_tile.dart';
import 'tour_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _textCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  List<_SearchResult> _search(TourController ctrl) {
    if (_query.isEmpty) return [];
    final q = _query.toLowerCase();
    final results = <_SearchResult>[];

    for (final tour in ctrl.tours) {
      for (final p in tour.passengers) {
        if (p.name.toLowerCase().contains(q) ||
            p.phone.contains(q)) {
          results.add(_SearchResult(tour: tour, passenger: p));
        }
      }
    }
    return results;
  }

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Text('Search', style: theme.textTheme.headlineLarge),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Find passengers across all tours',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withAlpha(120),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Search bar ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF334155)
                      : const Color(0xFFE2E8F0),
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Icon(Icons.search_rounded,
                      color: theme.colorScheme.onSurface.withAlpha(80),
                      size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      onChanged: (v) => setState(() => _query = v.trim()),
                      style: theme.textTheme.bodyLarge,
                      decoration: InputDecoration(
                        hintText: 'Name or phone number...',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 16),
                        hintStyle: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withAlpha(80),
                        ),
                      ),
                    ),
                  ),
                  if (_query.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _textCtrl.clear();
                        setState(() => _query = '');
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 12),
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.onSurface.withAlpha(15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.close_rounded,
                            size: 16,
                            color:
                                theme.colorScheme.onSurface.withAlpha(150)),
                      ),
                    )
                  else
                    const SizedBox(width: 12),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // ── Results ──
          Expanded(
            child: Obx(() {
              final results = _search(tourCtrl);

              if (_query.isEmpty) {
                return _Placeholder(
                  icon: Icons.search_rounded,
                  title: 'Start searching',
                  subtitle: 'Type a name or phone number',
                );
              }
              if (results.isEmpty) {
                return _Placeholder(
                  icon: Icons.person_off_rounded,
                  title: 'No results',
                  subtitle: 'Try a different search term',
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 100),
                physics: const BouncingScrollPhysics(),
                itemCount: results.length + 1, // +1 for count header
                separatorBuilder: (_, i) => const SizedBox(height: 10),
                itemBuilder: (ctx, i) {
                  if (i == 0) {
                    return Text(
                      '${results.length} result${results.length == 1 ? '' : 's'}',
                      style: theme.textTheme.titleSmall,
                    );
                  }
                  final r = results[i - 1];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Show tour name as a small label
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4, left: 4),
                        child: Text(
                          r.tour.route,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      PassengerTile(
                        passenger: r.passenger,
                        onTap: () => Get.to(
                          () => TourDetailScreen(tourId: r.tour.id),
                          transition: Transition.cupertino,
                        ),
                      ),
                    ],
                  );
                },
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _SearchResult {
  final Tour tour;
  final Passenger passenger;
  const _SearchResult({required this.tour, required this.passenger});
}

class _Placeholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _Placeholder({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: theme.colorScheme.primary.withAlpha(50)),
          const SizedBox(height: 16),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withAlpha(100),
            ),
          ),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}
