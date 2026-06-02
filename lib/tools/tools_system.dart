/// System operation tools — Solvhen reads and controls the phone.
/// Backed by NativeBridge → Android MethodChannel.
library;

import 'dart:convert';
import 'dart:io';
import 'tool_registry.dart';
import 'tool_utils.dart';
import 'native_bridge.dart';

void registerSystemTools() {
  final registry = ToolRegistry();

  registry.register(ToolEntry(
    name: 'get_time',
    toolset: 'system',
    schema: {
      'name': 'get_time', 'description': '获取当前时间。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final now = DateTime.now();
      return jsonEncode({
        'time': now.toIso8601String(),
        'hour': now.hour, 'minute': now.minute,
        'weekday': ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1],
      });
    },
  ));

  registry.register(ToolEntry(
    name: 'get_battery',
    toolset: 'system',
    schema: {
      'name': 'get_battery', 'description': '获取手机电池电量和充电状态。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getBattery()),
  ));

  registry.register(ToolEntry(
    name: 'get_volume',
    toolset: 'system',
    schema: {
      'name': 'get_volume', 'description': '获取媒体音量和响铃模式。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getVolume()),
  ));

  registry.register(ToolEntry(
    name: 'set_volume',
    toolset: 'system',
    schema: {
      'name': 'set_volume', 'description': '设置媒体音量（0-100）。',
      'parameters': {
        'type': 'object',
        'properties': {
          'level': {'type': 'integer', 'description': '音量 0-100'},
        },
        'required': ['level'],
      },
    },
    handler: (args) async =>
        jsonEncode(await NativeBridge.setVolume(clampInt(parseArgInt(args['level'], 50), 0, 100))),
  ));

  registry.register(ToolEntry(
    name: 'get_brightness',
    toolset: 'system',
    schema: {
      'name': 'get_brightness', 'description': '获取屏幕亮度。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getBrightness()),
  ));

  registry.register(ToolEntry(
    name: 'set_brightness',
    toolset: 'system',
    schema: {
      'name': 'set_brightness', 'description': '设置屏幕亮度。',
      'parameters': {
        'type': 'object',
        'properties': {
          'level': {'type': 'integer', 'description': '亮度 0-255'},
        },
        'required': ['level'],
      },
    },
    handler: (args) async =>
        jsonEncode(await NativeBridge.setBrightness(clampInt(parseArgInt(args['level'], 128), 0, 255))),
  ));

  registry.register(ToolEntry(
    name: 'toggle_wifi',
    toolset: 'system',
    schema: {
      'name': 'toggle_wifi', 'description': '打开或关闭 WiFi。',
      'parameters': {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean', 'description': 'true=开, false=关'},
        },
        'required': ['enable'],
      },
    },
    handler: (args) async =>
        jsonEncode(await NativeBridge.toggleWifi(_parseBool(args['enable']))),
  ));

  registry.register(ToolEntry(
    name: 'toggle_bluetooth',
    toolset: 'system',
    schema: {
      'name': 'toggle_bluetooth', 'description': '打开或关闭蓝牙。',
      'parameters': {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean', 'description': 'true=开, false=关'},
        },
        'required': ['enable'],
      },
    },
    handler: (args) async =>
        jsonEncode(await NativeBridge.toggleBluetooth(_parseBool(args['enable']))),
  ));

  registry.register(ToolEntry(
    name: 'open_app',
    toolset: 'system',
    schema: {
      'name': 'open_app', 'description': '''★ 打开手机上的应用。★ 必须先调用 list_installed_apps 搜索包名再调用本工具！★ 禁止猜包名！
传入包名（如 com.tencent.mm）或已知中文名（微信/QQ/淘宝等）。
如果你不知道应用的包名，先用 list_installed_apps 查询，然后用返回的 package 字段调用本工具。
已知应用: 微信(com.tencent.mm), QQ(com.tencent.mobileqq), 百度地图(com.baidu.BaiduMap),
高德地图(com.autonavi.minimap), 淘宝(com.taobao.taobao), 支付宝(com.eg.android.AlipayGphone),
设置(com.android.settings), 相机(com.android.camera), 抖音(com.ss.android.ugc.aweme),
B站(com.bilibili.app.in), 微博(com.sina.weibo), 网易云(com.netease.cloudmusic)''',
      'parameters': {
        'type': 'object',
        'properties': {
          'package': {'type': 'string', 'description': '应用中文名或包名'},
        },
        'required': ['package'],
      },
    },
    handler: (args) async {
      final input = (args['package'] ?? args['app'] ?? args['packageName']) as String?;
      if (input == null || input.isEmpty) {
        return jsonEncode({'error': '缺少 package 参数', 'hint': '需要传入应用中文名或包名'});
      }
      final pkg = resolveAppPackage(input);
      return jsonEncode(await NativeBridge.openApp(pkg));
    },
  ));

  registry.register(ToolEntry(
    name: 'list_installed_apps',
    toolset: 'system',
    schema: {
      'name': 'list_installed_apps',
      'description': '''★ 打开应用前必须先用此工具搜索包名！★ 列出手机上已安装的应用（仅限有启动图标的用户应用）。
返回应用中文名和包名，用于后续通过 open_app 打开。
当用户要求打开某个应用但你不知道其确切包名时，先调用此工具查询。
调用示例：list_installed_apps(filter="小红书") 会返回名称含"小红书"的应用。''',
      'parameters': {
        'type': 'object',
        'properties': {
          'max_results': {
            'type': 'integer',
            'description': '最多返回多少条结果，默认100（返回全部）',
          },
          'filter': {
            'type': 'string',
            'description': '按应用名称或包名过滤。例如 filter="微信" 返回名称含微信的所有应用。不传则返回全部。',
          },
        },
        'required': [],
      },
    },
    handler: (args) async => jsonEncode(await NativeBridge.listInstalledApps(
      maxResults: (args['max_results'] as int?) ?? 100,
      filter: (args['filter'] as String?) ?? '',
    )),
  ));

  registry.register(ToolEntry(
    name: 'set_ringer_mode',
    toolset: 'system',
    schema: {
      'name': 'set_ringer_mode', 'description': '设置响铃模式。',
      'parameters': {
        'type': 'object',
        'properties': {
          'mode': {'type': 'string', 'enum': ['normal', 'vibrate', 'silent']},
        },
        'required': ['mode'],
      },
    },
    handler: (args) async =>
        jsonEncode(await NativeBridge.setRingerMode(args['mode'] as String)),
  ));

  registry.register(ToolEntry(
    name: 'get_device_info',
    toolset: 'system',
    schema: {
      'name': 'get_device_info', 'description': '获取手机型号和系统版本。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getDeviceInfo()),
  ));

  registry.register(ToolEntry(
    name: 'get_clipboard',
    toolset: 'system',
    schema: {
      'name': 'get_clipboard', 'description': '读取剪贴板文字内容。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getClipboard()),
  ));

  registry.register(ToolEntry(
    name: 'set_clipboard',
    toolset: 'system',
    schema: {
      'name': 'set_clipboard', 'description': '将文字写入剪贴板。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '要写入的文字'},
        },
        'required': ['text'],
      },
    },
    handler: (args) async =>
        jsonEncode(await NativeBridge.setClipboard(args['text'] as String)),
  ));

  registry.register(ToolEntry(
    name: 'toggle_flashlight',
    toolset: 'system',
    schema: {
      'name': 'toggle_flashlight', 'description': '打开或关闭手电筒。需要相机权限。',
      'parameters': {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean', 'description': 'true=开, false=关'},
        },
        'required': ['enable'],
      },
    },
    handler: (args) async =>
        jsonEncode(await NativeBridge.toggleFlashlight(_parseBool(args['enable']))),
  ));

  registry.register(ToolEntry(
    name: 'lock_screen',
    toolset: 'system',
    schema: {
      'name': 'lock_screen', 'description': '锁定屏幕。类似于按电源键。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.lockScreen()),
  ));

  registry.register(ToolEntry(
    name: 'keep_screen_on',
    toolset: 'system',
    schema: {
      'name': 'keep_screen_on', 'description': '保持屏幕常亮（不自动息屏）。传入 false 恢复默认。',
      'parameters': {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean', 'description': 'true=常亮, false=恢复'},
        },
        'required': ['enable'],
      },
    },
    handler: (args) async =>
        jsonEncode(await NativeBridge.keepScreenOn(_parseBool(args['enable']))),
  ));

  // ═══════════════════════════════════════════════
  // logcat — read Android system logs (debug tool)
  // ═══════════════════════════════════════════════
  registry.register(ToolEntry(
    name: 'logcat',
    toolset: 'system',
    schema: {
      'name': 'logcat',
      'description': '读取 Android 系统日志。调试利器——看错误、崩溃、异常。'
          '\nlines: 返回最近 N 行（默认100，最大500）。'
          '\nfilter: 过滤关键词，如 "Flutter|flutter|ERROR|Exception"。'
          '\n使用场景：画布没反应时读日志，看有没有报错。',
      'parameters': {
        'type': 'object',
        'properties': {
          'lines': {'type': 'integer', 'description': '返回行数，默认100'},
          'filter': {'type': 'string', 'description': 'grep 过滤关键词，支持 | 分隔'},
        },
        'required': [],
      },
    },
    handler: (args) async {
      try {
        final lines = ((args['lines'] as int?) ?? 100).clamp(10, 500);
        final filter = (args['filter'] as String?) ?? '';
        // Reject filter strings with shell metacharacters — security measure
        if (RegExp(r'[`$(){};|&!<>]').hasMatch(filter)) {
          return jsonEncode({'error': 'filter 包含不允许的特殊字符', 'hint': '仅支持字母、数字、冒号、点和管道符'});
        }
        // Run logcat and filter in pure Dart — no shell injection risk
        final result = await Process.run('logcat', ['-d', '-t', lines.toString()],
            runInShell: true).timeout(const Duration(seconds: 15));
        var output = result.stdout.toString();
        if (filter.isNotEmpty) {
          // Filter lines containing any of the pipe-separated terms
          final terms = filter.split('|').map((t) => t.trim()).where((t) => t.isNotEmpty);
          output = output.split('\n')
              .where((line) => terms.any((t) => line.contains(t)))
              .join('\n');
        }
        final truncated = output.length > 8000
            ? output.substring(output.length - 8000)
            : output;
        return jsonEncode({
          'lines': truncated.split('\n').where((l) => l.isNotEmpty).length,
          'text': truncated,
        });
      } catch (e) {
        return jsonEncode({'error': 'logcat 不可用: $e'});
      }
    },
  ));
}

/// Resolve app name or package name to package name.
/// Shared between tools_system.dart and command_executor.dart.
String resolveAppPackage(String input) {
  // If it looks like a package name (contains dots), return as-is
  if (input.contains('.')) return input;
  const map = {
    '微信': 'com.tencent.mm',
    'qq': 'com.tencent.mobileqq',
    '地图': 'com.baidu.BaiduMap', '百度地图': 'com.baidu.BaiduMap',
    '高德': 'com.autonavi.minimap', '高德地图': 'com.autonavi.minimap',
    '设置': 'com.android.settings',
    '相机': 'com.android.camera',
    '淘宝': 'com.taobao.taobao',
    '支付宝': 'com.eg.android.AlipayGphone',
    '抖音': 'com.ss.android.ugc.aweme',
    'b站': 'com.bilibili.app.in', '哔哩哔哩': 'com.bilibili.app.in',
    '微博': 'com.sina.weibo',
    '网易云': 'com.netease.cloudmusic', '网易云音乐': 'com.netease.cloudmusic',
    'chrome': 'com.android.chrome', '浏览器': 'com.android.chrome',
    '计算器': 'com.android.calculator2',
    '日历': 'com.android.calendar',
    '时钟': 'com.android.deskclock',
  };
  return map[input.toLowerCase()] ?? input;
}

/// Parse boolean from dynamic value (supports DeepSeek XML string "true"/"false").
bool _parseBool(dynamic v) => v == true || v == 'true' || v == 1;
