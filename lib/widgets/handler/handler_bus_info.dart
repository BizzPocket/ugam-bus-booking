// Departure line, driver contact card and the live own-bus map.

import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../design/ugam.dart';
import '../../models/bus_details.dart';
import '../../services/whatsapp_service.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/time_format.dart';
import '../osm_map_layers.dart';
import 'handler_atoms.dart';

// ─── Bus departure header ──────────────────────────────────────────────

/// The selected bus's name plus its OWN departure: place + time, rendered as
/// `<boardingPoint> · <formatHhMm(departureTime)>` per the surfacing rule —
/// either half is omitted when empty/null, and the departure line is hidden
/// entirely when both are empty (the per-bus values override the tour-level /
/// chart-footer departure). Sits above the money summary so the handler reads
/// where and when THIS bus leaves at a glance.
class HandlerBusDeparture extends StatelessWidget {
  final Bus bus;
  final UgamColorSet c;

  const HandlerBusDeparture({super.key, required this.bus, required this.c});

  @override
  Widget build(BuildContext context) {
    final place = bus.boardingPoint.trim();
    final time = formatHhMm(bus.departureTime);
    final parts = <String>[
      if (place.isNotEmpty) place,
      if (time != null && time.isNotEmpty) time,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            bus.name,
            style: UgamText.titleS.copyWith(color: c.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (parts.isNotEmpty) ...[
            const SizedBox(height: 2),
            Row(
              children: [
                Icon(Icons.place_outlined, size: 14, color: c.ink2),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    parts.join(' · '),
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Driver name + phone for THIS bus, with one-tap call and WhatsApp so the
/// handler can reach the driver from the ground (running late, boarding-point
/// change, head-count). Hidden entirely when the bus has neither a driver name
/// nor a phone — there is nothing to show or contact. The phone line and the
/// action buttons only appear when a number exists; otherwise just the name is
/// shown so the handler at least knows who is driving.
class HandlerDriverContact extends StatelessWidget {
  final Bus bus;
  final UgamColorSet c;

  const HandlerDriverContact({super.key, required this.bus, required this.c});

  Future<void> _openWhatsApp(String phone) async {
    final cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return;
    try {
      final ok = await WhatsAppService().openChat(phone: phone, message: '');
      if (!ok) {
        AppSnackBar.error(
          tr('handler_chart.wa_open_failed', namedArgs: {'phone': phone}),
          title: tr('handler_chart.wa_failed_title'),
        );
      }
    } catch (e) {
      AppSnackBar.error(
        tr('handler_chart.wa_open_error', namedArgs: {'error': '$e'}),
        title: tr('handler_chart.wa_failed_title'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = bus.driverName.trim();
    final phone = bus.driverPhone.trim();
    if (name.isEmpty && phone.isEmpty) return const SizedBox.shrink();
    final hasPhone = phone.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.md),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.sm),
        child: Row(
          children: [
            // Decorative medallion (not tappable) -> px, so it tracks the same
            // curve the name/phone text beside it already rides.
            Container(
              width: UgamScale.px(context, 40),
              height: UgamScale.px(context, 40),
              decoration: BoxDecoration(
                color: c.accentFill,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.directions_bus_filled_rounded,
                size: UgamScale.px(context, 19),
                color: c.accent,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr('handler_chart.driver'),
                    style: UgamText.micro.copyWith(
                      color: c.ink3,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    name.isEmpty ? tr('handler_chart.driver_unnamed') : name,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hasPhone)
                    Text(
                      phone,
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(color: c.ink2),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (hasPhone) ...[
              const SizedBox(width: UgamSpacing.sm),
              // Was a second, byte-identical hand-rolled copy of HandlerCallButton.
              HandlerCallButton(phone: phone),
              const SizedBox(width: UgamSpacing.xs),
              // The WhatsApp twin had no Semantics at all while the call button
              // beside it announced itself; UgamIconButton supplies both.
              UgamIconButton(
                icon: Icons.chat_rounded,
                tone: UgamIconButtonTone.good,
                onTapFeedback: HapticFeedback.selectionClick,
                onTap: () => _openWhatsApp(phone),
                semanticLabel: tr(
                  'handler_chart.whatsapp_semantic',
                  namedArgs: {'phone': phone},
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A small "yes, your dot is moving" confirmation for the handler.
///
/// Non-interactive on purpose: this sits on a phone that is already running
/// GPS for hours, and pan/zoom gestures would cost battery and fight the
/// page's own scroll for no added information at this size. Tiles come from
/// the on-disk cache after the first draw.
///
/// Reads its own position stream rather than the tracker's buffer — the buffer
/// drains on every upload, so it is not a source of "where am I now".
class HandlerOwnBusMap extends StatefulWidget {
  const HandlerOwnBusMap({super.key});

  @override
  State<HandlerOwnBusMap> createState() => _HandlerOwnBusMapState();
}

class _HandlerOwnBusMapState extends State<HandlerOwnBusMap> {
  Position? _me;
  StreamSubscription<Position>? _sub;
  final _map = MapController();
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _sub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 50,
          ),
        ).listen(
          (p) {
            if (!mounted) return;
            setState(() => _me = p);
            // Follow the bus by moving the camera, not by rebuilding the map.
            if (_mapReady) {
              _map.move(LatLng(p.latitude, p.longitude), _map.camera.zoom);
            }
          },
          // A failure here costs a reassurance map, nothing more. The upload
          // path has its own stream and its own error reporting.
          onError: (_) {},
        );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    if (me == null) return const UgamSkeleton(height: 160);
    final here = LatLng(me.latitude, me.longitude);
    return ClipRRect(
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: SizedBox(
        height: 160,
        child: FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: here,
            initialZoom: 15,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.none,
            ),
            onMapReady: () => _mapReady = true,
          ),
          children: [
            osmTileLayer(context),
            MarkerLayer(
              markers: [
                Marker(
                  point: here,
                  width: 28,
                  height: 28,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: UgamColors.of(context).good,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: UgamColors.of(context).card,
                        width: 3,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const OsmAttribution(alignment: Alignment.bottomRight),
          ],
        ),
      ),
    );
  }
}
