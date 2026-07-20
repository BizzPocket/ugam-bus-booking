import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../routes/app_routes.dart';
import '../screens/main_shell.dart';

/// Top-level FCM background handler. A `notification`-payload message is shown
/// in the system tray by the OS automatically while the app is backgrounded or
/// killed, so there is nothing to draw here — this exists only because
/// firebase_messaging requires a registered background handler. Must be a
/// top-level (or static) function; the framework runs it in its own isolate.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Intentionally minimal. Deep-link handling happens on tap via
  // onMessageOpenedApp / getInitialMessage, not here.
  if (kDebugMode) {
    debugPrint('[push] bg message: ${message.messageId} ${message.data}');
  }
}

/// Owns the device-side push lifecycle for the authenticated admin:
/// OS permission, FCM token registration to Supabase, foreground display, and
/// notification-tap deep-linking. Delivery is gated server-side by the admin's
/// notification preferences (see send-push Edge Function); this class only
/// manages the device end.
///
/// Single home for push — see [[project_consolidate_not_patchwork]] in spirit:
/// every surface (login, logout, settings) routes through this one service.
class PushService {
  PushService._();
  static final PushService instance = PushService._();

  final FirebaseMessaging _fm = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _local =
      FlutterLocalNotificationsPlugin();

  bool _initialised = false;
  String? _lastToken;
  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _onMessageSub;
  StreamSubscription<RemoteMessage>? _onOpenedSub;

  SupabaseClient get _sb => Supabase.instance.client;

  /// Android channel — its id MUST match `channel_id` in the send-push Edge
  /// Function (`booking_requests`) or Android drops the notification.
  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'booking_requests',
    'Booking requests',
    description: 'New customer booking requests for your tours',
    importance: Importance.high,
  );

  /// Android channel for inbound WhatsApp customer messages — its id MUST match
  /// `channel_id` in `buildWaMessageFcm` (`messages`) or Android drops it.
  static const AndroidNotificationChannel _messagesChannel =
      AndroidNotificationChannel(
    'messages',
    'Customer messages',
    description: 'Inbound WhatsApp messages from your customers',
    importance: Importance.high,
  );

  /// Index of the Requests tab in MainShell's `_adminPages`
  /// ([Dashboard, Tours, Charts, Requests, Settings]) — Requests is index 3.
  /// (Was 2 before the Charts tab was inserted, which silently deep-linked
  /// booking taps onto Charts.) Tap deep-links for `booking_request` land here.
  static const int _requestsTabIndex = 3;

  // ── Lifecycle ────────────────────────────────────────────────────────

  /// One-time platform wiring: local-notification channel, foreground
  /// presentation, and message/tap listeners. Idempotent.
  Future<void> init() async {
    if (_initialised) return;
    _initialised = true;

    // Android display channel for foreground heads-up notifications.
    final androidLocal = _local.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidLocal?.createNotificationChannel(_channel);
    await androidLocal?.createNotificationChannel(_messagesChannel);

    await _local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (resp) {
        final payload = resp.payload;
        if (payload != null) _handleTapType(payload);
      },
    );

    // iOS: let the OS present the banner while the app is foregrounded.
    await _fm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    _onMessageSub = FirebaseMessaging.onMessage.listen(_onForegroundMessage);
    _onOpenedSub =
        FirebaseMessaging.onMessageOpenedApp.listen(_onNotificationOpened);

    // App launched cold from a notification tap.
    final initial = await _fm.getInitialMessage();
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _onNotificationOpened(initial),
      );
    }
  }

  /// Request OS permission, fetch the FCM token, and register it for the
  /// current admin. Call after admin login and on admin session restore.
  /// No-op (returns quietly) if permission is denied or the token is null.
  Future<void> register() async {
    try {
      await init();

      final settings = await _fm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        if (kDebugMode) debugPrint('[push] permission denied — not registering');
        return;
      }

      final token = await _fm.getToken();
      if (token == null || token.isEmpty) {
        if (kDebugMode) debugPrint('[push] null FCM token — skipping register');
        return;
      }
      await _registerToken(token);

      // Re-register whenever FCM rotates the token.
      await _tokenRefreshSub?.cancel();
      _tokenRefreshSub = _fm.onTokenRefresh.listen(_registerToken);
    } catch (e) {
      // Push is best-effort; never let it break the login flow.
      if (kDebugMode) debugPrint('[push] register failed: $e');
    }
  }

  /// Remove this device's token. Call on logout BEFORE the Supabase session is
  /// signed out — the delete RPC is scoped by auth.uid(), so it needs the live
  /// session.
  Future<void> unregister() async {
    try {
      await _tokenRefreshSub?.cancel();
      _tokenRefreshSub = null;
      final token = _lastToken ?? await _fm.getToken();
      if (token != null && token.isNotEmpty) {
        await _sb.rpc(
          'unregister_device_token',
          params: {'p_token': token},
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[push] unregister failed: $e');
    } finally {
      _lastToken = null;
    }
  }

  // ── Internals ────────────────────────────────────────────────────────

  Future<void> _registerToken(String token) async {
    _lastToken = token;
    final platform = Platform.isIOS ? 'ios' : 'android';
    await _sb.rpc(
      'register_device_token',
      params: {'p_token': token, 'p_platform': platform},
    );
    if (kDebugMode) debugPrint('[push] registered token ($platform)');
  }

  /// Foreground delivery. Android does NOT auto-display a notification-payload
  /// message in the foreground, so draw one via local notifications. iOS is
  /// handled by setForegroundNotificationPresentationOptions, so skip there to
  /// avoid a duplicate banner.
  Future<void> _onForegroundMessage(RemoteMessage message) async {
    if (!Platform.isAndroid) return;
    final n = message.notification;
    if (n == null) return;
    // Route the local heads-up onto the channel that matches the push type so
    // it inherits the right name/importance (and the user can mute each kind
    // independently).
    final ch =
        message.data['type'] == 'wa_message' ? _messagesChannel : _channel;
    await _local.show(
      id: n.hashCode,
      title: n.title,
      body: n.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          ch.id,
          ch.name,
          channelDescription: ch.description,
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
      payload: message.data['type'] as String?,
    );
  }

  void _onNotificationOpened(RemoteMessage message) {
    _handleTapType(message.data['type'] as String?);
  }

  /// Route a tapped notification to the right surface:
  ///   `booking_request` → the admin Requests tab.
  ///   `wa_message`      → the WhatsApp Inbox (a pushed route, not a tab).
  void _handleTapType(String? type) {
    if (type == 'booking_request') {
      if (Get.currentRoute != AppRoutes.home) {
        Get.offAllNamed(AppRoutes.home);
      }
      // The shell mounts asynchronously after navigation; select the Requests
      // tab once its controller exists.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Get.isRegistered<ShellController>()) {
          Get.find<ShellController>().switchTab(_requestsTabIndex);
        }
      });
    } else if (type == 'wa_message') {
      // Land on the home shell, then push the inbox over it so the back
      // affordance returns to home.
      if (Get.currentRoute != AppRoutes.home) {
        Get.offAllNamed(AppRoutes.home);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Get.currentRoute != AppRoutes.inbox) {
          Get.toNamed(AppRoutes.inbox);
        }
      });
    }
  }

  /// Tear down listeners (not normally needed — the service is a singleton for
  /// the app's lifetime — but available for tests/hot-restart hygiene).
  Future<void> dispose() async {
    await _onMessageSub?.cancel();
    await _onOpenedSub?.cancel();
    await _tokenRefreshSub?.cancel();
    _initialised = false;
  }
}
