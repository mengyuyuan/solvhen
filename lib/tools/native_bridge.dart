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
  // UI 自动化内核 — 结构化读取 + 语义动作 + 原子序列
  // 与 SolvhenUiAutomator.kt 一一对应
  // ═══════════════════════════════════════

  /// 读取结构化 UI 树（节点带稳定 id，供 uiTapNode 精准点击）
  static Future<Map<String, dynamic>> uiDump({
    bool includeInvisible = false,
    int maxNodes = 600,
  }) => _invoke('uiDump', {
    'includeInvisible': includeInvisible,
    'maxNodes': maxNodes,
  });

  /// 多条件查找节点
  static Future<Map<String, dynamic>> uiFind({
    String text = '',
    String viewId = '',
    String className = '',
    bool clickableOnly = false,
    bool editableOnly = false,
    bool scrollableOnly = false,
    bool exact = false,
    int limit = 20,
  }) => _invoke('uiFind', {
    'text': text,
    'viewId': viewId,
    'className': className,
    'clickableOnly': clickableOnly,
    'editableOnly': editableOnly,
    'scrollableOnly': scrollableOnly,
    'exact': exact,
    'limit': limit,
  });

  /// 按 dump 得到的节点 id 点击
  static Future<Map<String, dynamic>> uiTapNode(int id) =>
      _invoke('uiTapNode', {'id': id});

  /// 查找并点击文字
  static Future<Map<String, dynamic>> uiTapText(String text, {bool exact = false}) =>
      _invoke('uiTapText', {'text': text, 'exact': exact});

  /// 向焦点输入框写入文字
  static Future<Map<String, dynamic>> uiTypeText(String text) =>
      _invoke('uiTypeText', {'text': text});

  /// 方向滑动：up / down / left / right
  static Future<Map<String, dynamic>> uiSwipe(String direction, {int duration = 300}) =>
      _invoke('uiSwipe', {'direction': direction, 'duration': duration});

  /// 滚动查找直到目标出现
  static Future<Map<String, dynamic>> uiScrollFind(String text, {int maxScrolls = 6}) =>
      _invoke('uiScrollFind', {'text': text, 'maxScrolls': maxScrolls});

  /// 等待文字出现
  static Future<Map<String, dynamic>> uiWaitText(String text, {int timeoutMs = 5000}) =>
      _invoke('uiWaitText', {'text': text, 'timeoutMs': timeoutMs});

  /// 等待界面稳定
  static Future<Map<String, dynamic>> uiWaitIdle({int timeoutMs = 4000}) =>
      _invoke('uiWaitIdle', {'timeoutMs': timeoutMs});

  /// 当前前台应用
  static Future<Map<String, dynamic>> uiForeground() => _invoke('uiForeground');

  /// 关闭挡路弹窗（allowPermissions=false 时不点「允许」）
  static Future<Map<String, dynamic>> uiDismiss({
    bool allowPermissions = false,
    int maxClicks = 2,
  }) => _invoke('uiDismiss', {
    'allowPermissions': allowPermissions,
    'maxClicks': maxClicks,
  });

  /// 原子序列：一次确认执行多步
  static Future<Map<String, dynamic>> uiSequence(List<Map<String, dynamic>> steps) =>
      _invoke('uiSequence', {'steps': steps});

  /// 截屏，返回 Base64 JPEG
  static Future<Map<String, dynamic>> screenshot({
    int quality = 70,
    int maxWidth = 900,
  }) => _invoke('screenshot', {
    'quality': quality,
    'maxWidth': maxWidth,
  });

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
