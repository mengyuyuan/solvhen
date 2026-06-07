// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// Android原生桥接——通过MethodChannel调用Android系统API
// ═══════════════════════════════════════════════════════════════

library;

import 'package:flutter/services.dart';

/// Android原生桥接——通过MethodChannel调用Android系统API
/// 通信协议：Dart→MethodChannel→Kotlin→Android API
class NativeBridge {
  static const _channel = MethodChannel('solvhen/system');

  static Future<Map<String, dynamic>> getBattery() =>
      _invoke('getBattery');

  static Future<Map<String, dynamic>> getDeviceInfo() =>
      _invoke('getDeviceInfo');

  static Future<Map<String, dynamic>> getVolume() =>
      _invoke('getVolume');

  static Future<Map<String, dynamic>> setVolume(int level) =>
      _invoke('setVolume', {'level': level});

  static Future<Map<String, dynamic>> getBrightness() =>
      _invoke('getBrightness');

  static Future<Map<String, dynamic>> setBrightness(int level) =>
      _invoke('setBrightness', {'level': level});

  static Future<Map<String, dynamic>> toggleWifi(bool enable) =>
      _invoke('toggleWifi', {'enable': enable});

  static Future<Map<String, dynamic>> toggleBluetooth(bool enable) =>
      _invoke('toggleBluetooth', {'enable': enable});

  static Future<Map<String, dynamic>> openApp(String package) =>
      _invoke('openApp', {'package': package});

  static Future<Map<String, dynamic>> listInstalledApps({
    int maxResults = 100,
    String filter = '',
  }) => _invoke('listInstalledApps', {
    'maxResults': maxResults,
    'filter': filter,
  });

  static Future<Map<String, dynamic>> setRingerMode(String mode) =>
      _invoke('setRingerMode', {'mode': mode});

  static Future<Map<String, dynamic>> getClipboard() =>
      _invoke('getClipboard');

  static Future<Map<String, dynamic>> setClipboard(String text) =>
      _invoke('setClipboard', {'text': text});

  static Future<Map<String, dynamic>> toggleFlashlight(bool enable) =>
      _invoke('toggleFlashlight', {'enable': enable});

  static Future<Map<String, dynamic>> lockScreen() =>
      _invoke('lockScreen');

  static Future<Map<String, dynamic>> keepScreenOn(bool enable) =>
      _invoke('keepScreenOn', {'enable': enable});

  // ═══════════════════════════════════════
  // 无障碍服务 — AI操控应用内部UI
  // ═══════════════════════════════════════

  static Future<Map<String, dynamic>> isAccessibilityEnabled() =>
      _invoke('isAccessibilityEnabled');

  static Future<Map<String, dynamic>> openAccessibilitySettings() =>
      _invoke('openAccessibilitySettings');

  static Future<Map<String, dynamic>> inputTap(double x, double y) =>
      _invoke('inputTap', {'x': x, 'y': y});

  static Future<Map<String, dynamic>> inputSwipe(double x1, double y1, double x2, double y2, {int duration = 300}) =>
      _invoke('inputSwipe', {'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2, 'duration': duration});

  static Future<Map<String, dynamic>> inputText(String text) =>
      _invoke('inputText', {'text': text});

  static Future<Map<String, dynamic>> pressBack() =>
      _invoke('pressBack');

  static Future<Map<String, dynamic>> pressHome() =>
      _invoke('pressHome');

  static Future<Map<String, dynamic>> pressEnter() =>
      _invoke('pressEnter');

  static Future<Map<String, dynamic>> pressRecents() =>
      _invoke('pressRecents');

  static Future<Map<String, dynamic>> longPress(double x, double y) =>
      _invoke('longPress', {'x': x, 'y': y});

  static Future<Map<String, dynamic>> getScreenText() =>
      _invoke('getScreenText');

  static Future<Map<String, dynamic>> findText(String text) =>
      _invoke('findText', {'text': text});

  static Future<Map<String, dynamic>> clickText(String text) =>
      _invoke('clickText', {'text': text});

  // ═══════════════════════════════════════
  // 通知监听 — 读取微信/QQ等App的通知
  // ═══════════════════════════════════════

  static Future<Map<String, dynamic>> getNotifications({String filter = ''}) =>
      _invoke('getNotifications', {'filter': filter});

  static Future<Map<String, dynamic>> isNotificationListenerEnabled() =>
      _invoke('isNotificationListenerEnabled');

  static Future<Map<String, dynamic>> openNotificationListenerSettings() =>
      _invoke('openNotificationListenerSettings');

  static Future<Map<String, dynamic>> clearNotifications() =>
      _invoke('clearNotifications');

  static Future<Map<String, dynamic>> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      final result = args != null
          ? await _channel.invokeMethod(method, args)
          : await _channel.invokeMethod(method);
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return {'value': result};
    } on MissingPluginException catch (e) {
      return {'error': '原生功能不可用: ${e.message ?? 'MissingPlugin'}'};
    } on PlatformException catch (e) {
      return {'error': e.message ?? 'Unknown error'};
    }
  }
}
