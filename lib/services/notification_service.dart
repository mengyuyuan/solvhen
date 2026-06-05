/// NotificationService — system notifications + in-app popup trigger.
/// Uses flutter_local_notifications for Android system notifications.
library;

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class PushEvent {
  final String title;
  final String body;
  final String? payload;
  const PushEvent({required this.title, required this.body, this.payload});
}

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// Stream for in-app overlay — UI listens to this.
  final StreamController<PushEvent> _pushController = StreamController<PushEvent>.broadcast();
  Stream<PushEvent> get onPush => _pushController.stream;

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    // Android 13+ notification permission
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      settings: const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onTap,
    );

    // Create notification channel for proactive messages
    await _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(
      const AndroidNotificationChannel(
        'solvhen_messages',
        'Solvhen 主动消息',
        description: 'Solvhen 主动联系你时的提醒',
        importance: Importance.high,
        enableVibration: true,
        playSound: true,
      ),
    );

    _initialized = true;
    debugPrint('[NotificationService] initialized');
  }

  void _onTap(NotificationResponse response) {
    debugPrint('[NotificationService] tapped: ${response.payload}');
    // Tapping a notification opens the app — handled by Android intent.
    // The payload can be used to route to a specific conversation, etc.
  }

  /// Show a system notification. Also emits to the in-app overlay stream.
  Future<void> show({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_initialized) {
      debugPrint('[NotificationService] not initialized, skipping push');
      return;
    }

    // System notification
    await _plugin.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'solvhen_messages',
          'Solvhen 主动消息',
          channelDescription: 'Solvhen 主动联系你时的提醒',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          enableVibration: true,
        ),
        iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
      ),
      payload: payload,
    );

    // In-app overlay
    _pushController.add(PushEvent(title: title, body: body, payload: payload));
  }

  void dispose() {
    _pushController.close();
  }
}
