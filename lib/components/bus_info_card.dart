import 'package:flutter/material.dart';
import '../models/bus_details.dart';
import '../config/theme.dart';

class BusInfoCard extends StatelessWidget {
  final Bus details;
  final VoidCallback? onEdit;

  const BusInfoCard({super.key, required this.details, this.onEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.brand.withAlpha(15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.directions_bus_rounded,
                    color: AppTheme.brand, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      details.busNumber,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Row(
                      children: [
                        _Tag(
                          label: details.busType,
                          color: AppTheme.brand,
                          isDark: isDark,
                        ),
                        const SizedBox(width: 6),
                        _Tag(
                          label: details.isAC ? 'AC' : 'Non-AC',
                          color: details.isAC ? AppTheme.success : AppTheme.warning,
                          isDark: isDark,
                        ),
                        const SizedBox(width: 6),
                        _Tag(
                          label: '${details.totalSeats} seats',
                          color: AppTheme.info,
                          isDark: isDark,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onEdit != null)
                IconButton(
                  onPressed: onEdit,
                  icon: Icon(
                    Icons.edit_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurface.withAlpha(100),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          ),
          const SizedBox(height: 12),
          _InfoRow(
            icon: Icons.person_rounded,
            label: 'Driver',
            value: details.driverName,
            theme: theme,
          ),
          const SizedBox(height: 8),
          _InfoRow(
            icon: Icons.phone_rounded,
            label: 'Driver Phone',
            value: details.driverPhone,
            theme: theme,
          ),
          if (details.ownerName != null) ...[
            const SizedBox(height: 8),
            _InfoRow(
              icon: Icons.business_rounded,
              label: 'Owner',
              value: details.ownerName!,
              theme: theme,
            ),
          ],
          if (details.notes != null && details.notes!.isNotEmpty) ...[
            const SizedBox(height: 8),
            _InfoRow(
              icon: Icons.note_rounded,
              label: 'Notes',
              value: details.notes!,
              theme: theme,
            ),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  final bool isDark;

  const _Tag({
    required this.label,
    required this.color,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final ThemeData theme;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurface.withAlpha(100)),
        const SizedBox(width: 8),
        Text(
          '$label:  ',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withAlpha(100),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
