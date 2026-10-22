import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

/// The one OpenStreetMap tile source every map in the app draws on.
///
/// Free and keyless — it replaced Google Maps, which needed a billing account
/// before it would render anything but grey. Two obligations come with the
/// OSM tile servers, and both live here so no screen can forget them:
///
///   * a real User-Agent (the app id), or the servers block the app;
///   * visible attribution — see [OsmAttribution].
///
/// Tiles are cached on disk by flutter_map's built-in caching provider (the
/// default on Android/iOS), so a re-opened map costs no data and no tile load.
///
/// Dark mode inverts the tiles once on the container rather than per tile —
/// the cheaper of flutter_map's two dark builders on old phones.
Widget osmTileLayer(BuildContext context) {
  final layer = TileLayer(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    userAgentPackageName: 'com.occubitsolution.ugambooking',
    maxNativeZoom: 19,
  );
  if (Theme.of(context).brightness != Brightness.dark) return layer;
  return darkModeTilesContainerBuilder(context, layer);
}

/// "© OpenStreetMap contributors", tappable to the copyright page. Required by
/// the OSM licence on every map that shows its tiles.
class OsmAttribution extends StatelessWidget {
  final Alignment alignment;

  const OsmAttribution({super.key, this.alignment = Alignment.topRight});

  @override
  Widget build(BuildContext context) {
    return SimpleAttributionWidget(
      alignment: alignment,
      source: const Text('OpenStreetMap contributors'),
      onTap: () => launchUrl(
        Uri.parse('https://www.openstreetmap.org/copyright'),
        mode: LaunchMode.externalApplication,
      ),
    );
  }
}
