/// Dart bridge to Android native system operations via MethodChannel.
library;

import 'package:flutter/services.dart';

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
