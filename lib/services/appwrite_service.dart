import 'package:appwrite/appwrite.dart';
import 'package:http/http.dart' as http;
import '../config/appwrite_config.dart';

/// Singleton wrapper around the Appwrite Client, Databases, and Realtime services.
/// Access via [AppwriteService()].
class AppwriteService {
  static final AppwriteService _instance = AppwriteService._internal();
  factory AppwriteService() => _instance;

  late final Client client;
  late final Databases databases;
  late final Realtime realtime;
  late final Locale locale;

  AppwriteService._internal() {
    client = Client()
      ..setEndpoint(AppwriteConfig.endpoint)
      ..setProject(AppwriteConfig.projectId)
      ..setSelfSigned(status: true);
    databases = Databases(client);
    realtime = Realtime(client);
    locale = Locale(client);
  }

  /// Ping the Appwrite server to verify the project is reachable.
  /// Uses the public `/ping` endpoint — only requires project ID.
  /// Returns a status string on success, throws on failure.
  Future<String> ping() async {
    final uri = Uri.parse('${AppwriteConfig.endpoint}/ping');
    final resp = await http.get(
      uri,
      headers: {
        'X-Appwrite-Project': AppwriteConfig.projectId,
        'Content-Type': 'application/json',
      },
    ).timeout(const Duration(seconds: 10));

    if (resp.statusCode >= 200 && resp.statusCode < 400) {
      return resp.body.isNotEmpty ? resp.body : 'OK';
    }
    throw Exception('Ping failed: HTTP ${resp.statusCode} - ${resp.body}');
  }
}
