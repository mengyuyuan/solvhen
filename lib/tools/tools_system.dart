/// Solvhen AI手机智能体 — 系统操作工具集
/// 通过 NativeBridge → Android MethodChannel 实现手机系统控制。
/// 功能：时间、电量、音量、亮度、WiFi/蓝牙、应用管理、剪贴板、手电筒、锁屏、日志读取。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'tool_registry.dart';
import 'tool_utils.dart';
import '../core/security/onebot_credentials.dart';
import 'native_bridge.dart';
import '../services/onebot_bridge.dart' as ob;
import '../services/database_service.dart' as dbs;

/// 注册系统操作工具集
/// 工具：get_clipboard/set_clipboard(剪切板)/toggle_flashlight(闪光灯)/
///       lock_screen(锁屏)/keep_screen_on(亮屏)/list_installed_apps(应用列表)/
///       open_app(打开应用)/eval_math(数学计算)/get_device_info(设备信息)等
/// ⚠️ 安全：eval_math使用正则白名单而非eval；filter regex禁用shell特殊字符
void registerSystemTools() {
  final registry = ToolRegistry();

  // ── get_time — 获取当前时间 ──
  registry.register(ToolEntry(
    name: 'get_time',
    toolset: 'system',
    schema: {
      'name': 'get_time',
      'description': '获取当前时间。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final now = DateTime.now();
      return jsonEncode({
        'time': now.toIso8601String(),
        'hour': now.hour, 'minute': now.minute,
        // Dart 的 weekday: 1=周一, 7=周日。直接映射中文。
        'weekday': ['一', '二', '三', '四', '五', '六', '日'][now.weekday - 1],
      });
    },
  ));

  // ── get_battery — 获取电池状态 ──
  registry.register(ToolEntry(
    name: 'get_battery',
    toolset: 'system',
    schema: {
      'name': 'get_battery',
      'description': '获取手机电池电量和充电状态。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getBattery()),
  ));

  // ── get_volume — 获取媒体音量 ──
  registry.register(ToolEntry(
    name: 'get_volume',
    toolset: 'system',
    schema: {
      'name': 'get_volume',
      'description': '获取媒体音量和响铃模式。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getVolume()),
  ));

  // ── set_volume — 设置媒体音量 ──
  registry.register(ToolEntry(
    name: 'set_volume',
    toolset: 'system',
    schema: {
      'name': 'set_volume',
      'description': '设置媒体音量（0-100）。',
      'parameters': {
        'type': 'object',
        'properties': {
          'level': {'type': 'integer', 'description': '音量 0-100'},
        },
        'required': ['level'],
      },
    },
    handler: (args) async =>
        // clamp 保证值在合法范围内，防止 NativeBridge 收到非法值崩溃
        jsonEncode(await NativeBridge.setVolume(
            clampInt(parseArgInt(args['level'], 50), 0, 100))),
  ));

  // ── get_brightness — 获取屏幕亮度 ──
  registry.register(ToolEntry(
    name: 'get_brightness',
    toolset: 'system',
    schema: {
      'name': 'get_brightness',
      'description': '获取屏幕亮度。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getBrightness()),
  ));

  // ── set_brightness — 设置屏幕亮度 ──
  registry.register(ToolEntry(
    name: 'set_brightness',
    toolset: 'system',
    schema: {
      'name': 'set_brightness',
      'description': '设置屏幕亮度。',
      'parameters': {
        'type': 'object',
        'properties': {
          'level': {'type': 'integer', 'description': '亮度 0-255'},
        },
        'required': ['level'],
      },
    },
    handler: (args) async => jsonEncode(await NativeBridge.setBrightness(
        clampInt(parseArgInt(args['level'], 128), 0, 255))),
  ));

  // ── toggle_wifi — 开关 WiFi ──
  registry.register(ToolEntry(
    name: 'toggle_wifi',
    toolset: 'system',
    schema: {
      'name': 'toggle_wifi',
      'description': '打开或关闭 WiFi。',
      'parameters': {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean', 'description': 'true=开, false=关'},
        },
        'required': ['enable'],
      },
    },
    handler: (args) async =>
        // _parseBool 兼容 DeepSeek XML 模式中 bool 被序列化为字符串 "true"/"false" 的情况
        jsonEncode(await NativeBridge.toggleWifi(_parseBool(args['enable']))),
  ));

  // ── toggle_bluetooth — 开关蓝牙 ──
  registry.register(ToolEntry(
    name: 'toggle_bluetooth',
    toolset: 'system',
    schema: {
      'name': 'toggle_bluetooth',
      'description': '打开或关闭蓝牙。',
      'parameters': {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean', 'description': 'true=开, false=关'},
        },
        'required': ['enable'],
      },
    },
    handler: (args) async => jsonEncode(
        await NativeBridge.toggleBluetooth(_parseBool(args['enable']))),
  ));

  // ── open_app — 打开手机应用 ──
  registry.register(ToolEntry(
    name: 'open_app',
    toolset: 'system',
    schema: {
      'name': 'open_app',
      'description':
          '''★ 打开手机上的应用。★ 必须先调用 list_installed_apps 搜索包名再调用本工具！★ 禁止猜包名！
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
      // 兼容多种参数名（package/app/packageName），防止 LLM 使用非标准字段名
      final input =
          (args['package'] ?? args['app'] ?? args['packageName']) as String?;
      if (input == null || input.isEmpty) {
        return jsonEncode({'error': '缺少 package 参数', 'hint': '需要传入应用中文名或包名'});
      }
      final pkg = resolveAppPackage(input);
      return jsonEncode(await NativeBridge.openApp(pkg));
    },
  ));

  // ── list_installed_apps — 列出已安装应用（必须先调用此工具再 open_app）──
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

  // ── set_ringer_mode — 设置响铃模式 ──
  registry.register(ToolEntry(
    name: 'set_ringer_mode',
    toolset: 'system',
    schema: {
      'name': 'set_ringer_mode',
      'description': '设置响铃模式。',
      'parameters': {
        'type': 'object',
        'properties': {
          'mode': {
            'type': 'string',
            'enum': ['normal', 'vibrate', 'silent']
          },
        },
        'required': ['mode'],
      },
    },
    handler: (args) async =>
        jsonEncode(await NativeBridge.setRingerMode(args['mode'] as String)),
  ));

  // ── get_device_info — 获取设备信息 ──
  registry.register(ToolEntry(
    name: 'get_device_info',
    toolset: 'system',
    schema: {
      'name': 'get_device_info',
      'description': '获取手机型号和系统版本。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getDeviceInfo()),
  ));

  // ── get_clipboard — 读取剪贴板 ──
  registry.register(ToolEntry(
    name: 'get_clipboard',
    toolset: 'system',
    schema: {
      'name': 'get_clipboard',
      'description': '读取剪贴板文字内容。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.getClipboard()),
  ));

  // ── set_clipboard — 写入剪贴板 ──
  registry.register(ToolEntry(
    name: 'set_clipboard',
    toolset: 'system',
    schema: {
      'name': 'set_clipboard',
      'description': '将文字写入剪贴板。',
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

  // ── toggle_flashlight — 开关手电筒 ──
  registry.register(ToolEntry(
    name: 'toggle_flashlight',
    toolset: 'system',
    schema: {
      'name': 'toggle_flashlight',
      'description': '打开或关闭手电筒。需要相机权限。',
      'parameters': {
        'type': 'object',
        'properties': {
          'enable': {'type': 'boolean', 'description': 'true=开, false=关'},
        },
        'required': ['enable'],
      },
    },
    handler: (args) async => jsonEncode(
        await NativeBridge.toggleFlashlight(_parseBool(args['enable']))),
  ));

  // ── lock_screen — 锁定屏幕 ──
  registry.register(ToolEntry(
    name: 'lock_screen',
    toolset: 'system',
    schema: {
      'name': 'lock_screen',
      'description': '锁定屏幕。类似于按电源键。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async => jsonEncode(await NativeBridge.lockScreen()),
  ));

  // ── keep_screen_on — 保持屏幕常亮 ──
  registry.register(ToolEntry(
    name: 'keep_screen_on',
    toolset: 'system',
    schema: {
      'name': 'keep_screen_on',
      'description': '保持屏幕常亮（不自动息屏）。传入 false 恢复默认。',
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
  // logcat — 读取 Android 系统日志（调试工具）
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
        // 安全措施：拒绝包含 Shell 特殊字符的 filter 字符串
        // 注意：正则 [(`$(){};&!<>] 不包含 |，因此管道符被允许用于多关键词过滤
        // 这是有意设计的——| 是合法的分隔符且不会导致命令注入
        if (RegExp(r'[`$(){};&!<>]').hasMatch(filter)) {
          return jsonEncode(
              {'error': 'filter 包含不允许的特殊字符', 'hint': '仅支持字母、数字、冒号、点和管道符(|)'});
        }
        // 使用纯 Dart 做过滤，不依赖 shell grep，消除注入风险
        // runInShell: true 可能带来额外风险，但 filter 已经过验证
        final result = await Process.run(
                'logcat', ['-d', '-t', lines.toString()],
                runInShell: true)
            .timeout(const Duration(seconds: 15));
        var output = result.stdout.toString();
        if (filter.isNotEmpty) {
          // 按 | 分割多个过滤词，每行只要包含任意一个词就保留
          final terms =
              filter.split('|').map((t) => t.trim()).where((t) => t.isNotEmpty);
          output = output
              .split('\n')
              .where((line) => terms.any((t) => line.contains(t)))
              .join('\n');
        }
        // 截断超长输出，保留最后 8000 字符——最新日志通常更有价值
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

  // ═══════════════════════════════════════════════
  // 无障碍服务工具 — AI操控应用内部UI
  // ═══════════════════════════════════════════════

  // ── input_tap — 点击屏幕坐标 ──
  registry.register(ToolEntry(
    name: 'input_tap',
    toolset: 'system',
    schema: {
      'name': 'input_tap',
      'description':
          '点击屏幕指定坐标。需先开启无障碍服务（设置→无障碍→Solvhen）。获取坐标：先用 get_screen_text 读屏幕内容，从返回的 bounds 中取x/y。',
      'parameters': {
        'type': 'object',
        'properties': {
          'x': {'type': 'number', 'description': 'X坐标'},
          'y': {'type': 'number', 'description': 'Y坐标'},
        },
        'required': ['x', 'y'],
      },
    },
    handler: (args) async {
      final result = await NativeBridge.inputTap(
        (args['x'] as num).toDouble(),
        (args['y'] as num).toDouble(),
      );
      return jsonEncode(result);
    },
  ));

  // ── input_swipe — 滑动屏幕 ──
  registry.register(ToolEntry(
    name: 'input_swipe',
    toolset: 'system',
    schema: {
      'name': 'input_swipe',
      'description': '在屏幕上滑动。用于滚动列表、切换页面等。duration为滑动时长(毫秒)，默认300。',
      'parameters': {
        'type': 'object',
        'properties': {
          'x1': {'type': 'number', 'description': '起点X'},
          'y1': {'type': 'number', 'description': '起点Y'},
          'x2': {'type': 'number', 'description': '终点X'},
          'y2': {'type': 'number', 'description': '终点Y'},
          'duration': {'type': 'integer', 'description': '滑动时长(毫秒)，默认300'},
        },
        'required': ['x1', 'y1', 'x2', 'y2'],
      },
    },
    handler: (args) async {
      final result = await NativeBridge.inputSwipe(
        (args['x1'] as num).toDouble(),
        (args['y1'] as num).toDouble(),
        (args['x2'] as num).toDouble(),
        (args['y2'] as num).toDouble(),
        duration: args['duration'] as int? ?? 300,
      );
      return jsonEncode(result);
    },
  ));

  // ── input_text — 向输入框输入文字 ──
  registry.register(ToolEntry(
    name: 'input_text',
    toolset: 'system',
    schema: {
      'name': 'input_text',
      'description': '向当前焦点的输入框输入文字。需要输入框已获得焦点（先用 input_tap 点击输入框）。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '要输入的文字'},
        },
        'required': ['text'],
      },
    },
    handler: (args) async {
      final result = await NativeBridge.inputText(args['text'] as String);
      return jsonEncode(result);
    },
  ));

  // ── press_back — 按返回键 ──
  registry.register(ToolEntry(
    name: 'press_back',
    toolset: 'system',
    schema: {
      'name': 'press_back',
      'description': '按返回键。用于退出当前页面或弹窗。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final result = await NativeBridge.pressBack();
      return jsonEncode(result);
    },
  ));

  // ── press_home — 按主页键 ──
  registry.register(ToolEntry(
    name: 'press_home',
    toolset: 'system',
    schema: {
      'name': 'press_home',
      'description': '按主页键回到桌面。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final result = await NativeBridge.pressHome();
      return jsonEncode(result);
    },
  ));

  // ── get_screen_text — 读取屏幕内容 ──
  registry.register(ToolEntry(
    name: 'get_screen_text',
    toolset: 'system',
    schema: {
      'name': 'get_screen_text',
      'description':
          '读取当前屏幕上的所有可见文本和元素。返回每个元素的文字、是否可点击、坐标(bounds)。用于了解当前界面——找到按钮、输入框等。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final result = await NativeBridge.getScreenText();
      return jsonEncode(result);
    },
  ));

  // ── find_text — 在屏幕上查找文字 ──
  registry.register(ToolEntry(
    name: 'find_text',
    toolset: 'system',
    schema: {
      'name': 'find_text',
      'description':
          '在当前屏幕上查找包含指定文字的元素。返回匹配元素的文字、坐标、是否可点击。比 get_screen_text 更高效——只返回匹配项。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '要查找的文字（支持部分匹配）'},
        },
        'required': ['text'],
      },
    },
    handler: (args) async {
      final result = await NativeBridge.findText(args['text'] as String);
      return jsonEncode(result);
    },
  ));

  // ── click_text — 点击包含指定文字的元素 ──
  registry.register(ToolEntry(
    name: 'click_text',
    toolset: 'system',
    schema: {
      'name': 'click_text',
      'description':
          '查找并点击屏幕上包含指定文字的可点击元素。如 click_text("发送") 点击发送按钮。优先用这个而不是 input_tap——不需要坐标。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '要点击的文字（如"发送"、"确定"、"微信"）'},
        },
        'required': ['text'],
      },
    },
    handler: (args) async {
      final result = await NativeBridge.clickText(args['text'] as String);
      return jsonEncode(result);
    },
  ));

  // ── check_accessibility / open_accessibility — 无障碍服务管理 ──
  registry.register(ToolEntry(
    name: 'check_accessibility',
    toolset: 'system',
    schema: {
      'name': 'check_accessibility',
      'description':
          '检查无障碍服务是否已开启。如果未开启，用 open_accessibility_settings 直接跳到设置页。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final result = await NativeBridge.isAccessibilityEnabled();
      return jsonEncode(result);
    },
  ));

  registry.register(ToolEntry(
    name: 'open_accessibility_settings',
    toolset: 'system',
    schema: {
      'name': 'open_accessibility_settings',
      'description': '直接打开系统无障碍设置页面。对方不用手动找——一键跳到设置→无障碍，然后找到Solvhen开启即可。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final result = await NativeBridge.openAccessibilitySettings();
      return jsonEncode(result);
    },
  ));

  // ═══════════════════════════════════════════════
  // 补充高频工具
  // ═══════════════════════════════════════════════

  // ── press_enter — 发送回车/发送键 ──
  registry.register(ToolEntry(
    name: 'press_enter',
    toolset: 'system',
    schema: {
      'name': 'press_enter',
      'description': '向当前焦点输入框发送回车键（用于发送消息）。先点击输入框获得焦点，再调此工具。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final result = await NativeBridge.pressEnter();
      return jsonEncode(result);
    },
  ));

  // ── press_recent — 最近任务 ──
  registry.register(ToolEntry(
    name: 'press_recent',
    toolset: 'system',
    schema: {
      'name': 'press_recent',
      'description': '打开最近任务列表。用于切换应用。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final result = await NativeBridge.pressRecents();
      return jsonEncode(result);
    },
  ));

  // ── long_press — 长按 ──
  registry.register(ToolEntry(
    name: 'long_press',
    toolset: 'system',
    schema: {
      'name': 'long_press',
      'description': '长按屏幕指定坐标。用于弹出上下文菜单（如微信消息的"删除""转发"菜单）。',
      'parameters': {
        'type': 'object',
        'properties': {
          'x': {'type': 'number', 'description': 'X坐标'},
          'y': {'type': 'number', 'description': 'Y坐标'},
        },
        'required': ['x', 'y'],
      },
    },
    handler: (args) async {
      final result = await NativeBridge.longPress(
        (args['x'] as num).toDouble(),
        (args['y'] as num).toDouble(),
      );
      return jsonEncode(result);
    },
  ));

  // ── scroll_up / scroll_down — 快捷滑动 ──
  registry.register(ToolEntry(
    name: 'scroll_up',
    toolset: 'system',
    schema: {
      'name': 'scroll_up',
      'description': '向上滚动（手指从下往上滑）。用于翻看聊天记录、浏览列表等。默认从屏幕中间偏下滑到中间偏上。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final result =
          await NativeBridge.inputSwipe(540, 1200, 540, 400, duration: 200);
      return jsonEncode(result);
    },
  ));

  registry.register(ToolEntry(
    name: 'scroll_down',
    toolset: 'system',
    schema: {
      'name': 'scroll_down',
      'description': '向下滚动（手指从上往下滑）。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      final result =
          await NativeBridge.inputSwipe(540, 400, 540, 1200, duration: 200);
      return jsonEncode(result);
    },
  ));

  // ── get_notifications — 读取系统通知 ──
  registry.register(ToolEntry(
    name: 'get_notifications',
    toolset: 'system',
    schema: {
      'name': 'get_notifications',
      'description': '''读取最近收到的系统通知（微信/QQ等）。
需要先在系统设置中开启"通知使用权"（会引导你打开设置页）。
参数 filter 可按应用名过滤：'微信'/'QQ'/'企业微信' 或包名 'com.tencent.mm'。
返回通知的标题、内容、时间、来源应用。最多30条。''',
      'parameters': {
        'type': 'object',
        'properties': {
          'filter': {'type': 'string', 'description': '按应用名或包名过滤，如"微信"'}
        }
      }
    },
    handler: (args) async {
      final filter = args['filter'] as String? ?? '';
      final result = await NativeBridge.getNotifications(filter: filter);
      // 如果服务未开启，引导用户打开设置
      if (result['service_enabled'] != true) {
        unawaited(NativeBridge.openNotificationListenerSettings());
        return jsonEncode(
            {...result, 'hint': '通知监听服务未开启，已为你打开设置页。请找到 Solvhen 并开启。'});
      }
      return jsonEncode(result);
    },
  ));

  // ── wait — 等待 ──
  registry.register(ToolEntry(
    name: 'wait',
    toolset: 'system',
    schema: {
      'name': 'wait',
      'description':
          '等待指定毫秒数。在操作之间加延迟——UI切换需要时间，太快会导致操作失败。建议每次操作后等待500-1000ms。',
      'parameters': {
        'type': 'object',
        'properties': {
          'ms': {
            'type': 'integer',
            'description': '等待毫秒数。默认1000(1秒)，建议500-2000。'
          },
        },
        'required': [],
      },
    },
    handler: (args) async {
      final ms = args['ms'] as int? ?? 1000;
      await Future.delayed(Duration(milliseconds: ms.clamp(100, 5000)));
      return jsonEncode({'waited': ms});
    },
  ));
}

/// 将应用中文名或包名解析为包名。
/// 用于 tools_system.dart 和 command_executor.dart 共享。
/// 如果输入看起来像包名（含点号），直接返回；否则查内置映射表。
/// 大小写不敏感（统一 toLowerCase 后匹配）。
String resolveAppPackage(String input) {
  // 含点号 → 视为包名直接返回
  if (input.contains('.')) return input;

  /// 内置中文名 → 包名映射表。
  /// 注意：全部 key 为小写，resolveAppPackage 中会先 toLowerCase 再查表。
  /// 多个 key 可映射到同一包名（如「地图」「百度地图」→ com.baidu.BaiduMap）。
  const map = {
    '微信': 'com.tencent.mm',
    'qq': 'com.tencent.mobileqq',
    '地图': 'com.baidu.BaiduMap',
    '百度地图': 'com.baidu.BaiduMap',
    '高德': 'com.autonavi.minimap',
    '高德地图': 'com.autonavi.minimap',
    '设置': 'com.android.settings',
    '相机': 'com.android.camera',
    '淘宝': 'com.taobao.taobao',
    '支付宝': 'com.eg.android.AlipayGphone',
    '抖音': 'com.ss.android.ugc.aweme',
    'b站': 'com.bilibili.app.in',
    '哔哩哔哩': 'com.bilibili.app.in',
    '微博': 'com.sina.weibo',
    '网易云': 'com.netease.cloudmusic',
    '网易云音乐': 'com.netease.cloudmusic',
    'chrome': 'com.android.chrome',
    '浏览器': 'com.android.chrome',
    '计算器': 'com.android.calculator2',
    '日历': 'com.android.calendar',
    '时钟': 'com.android.deskclock',
  };
  return map[input.toLowerCase()] ?? input;
}

/// 安全解析布尔值，兼容多种类型。
/// DeepSeek XML 模式下 bool 可能被序列化为字符串 "true"/"false"，
/// 也可能以整数 1/0 形式传入。此函数统一处理。
bool _parseBool(dynamic v) => v == true || v == 'true' || v == 1;

// ═══════════════════════════════════════════════
// OneBot 桥接控制
// ═══════════════════════════════════════════════

/// 注册 OneBot 桥接工具——AI 可通过这些工具管理 QQ/微信接入
void registerOneBotTools() {
  final registry = ToolRegistry();

  // ── start_onebot — 启动 OneBot 服务 ──
  registry.register(ToolEntry(
    name: 'start_onebot',
    toolset: 'system',
    schema: {
      'name': 'start_onebot',
      'description':
          '启动 OneBot WebSocket 服务，允许 NapCatQQ 等客户端连接。默认端口 13579。启用后 QQ/微信消息会自动由 AI 回复。',
      'parameters': {
        'type': 'object',
        'properties': {
          'port': {'type': 'integer', 'description': 'WebSocket 端口，默认 13579'}
        }
      }
    },
    handler: (args) async {
      final port = (args['port'] as num?)?.toInt() ?? 13579;
      await dbs.DB.setConfig('onebot_enabled', 'true');
      await dbs.DB.setConfig('onebot_port', port.toString());
      final bridge = ob.OneBotBridge();
      await bridge.stop();
      final cfg = await dbs.DB.getConfig();
      final token = await OneBotCredentials().loadOrCreateToken();
      final ok = await bridge.start(
        port: port,
        accessToken: token,
        allowInsecureLan: cfg['onebot_allow_insecure_lan'] == 'true',
      );
      return jsonEncode({
        'success': ok,
        'port': port,
        'hint': ok
            ? 'OneBot 服务已启动在 ws://0.0.0.0:$port/onebot，NapCatQQ 反向 WebSocket 地址填这个'
            : '启动失败，端口可能被占用'
      });
    },
  ));

  // ── stop_onebot — 停止 OneBot 服务 ──
  registry.register(ToolEntry(
    name: 'stop_onebot',
    toolset: 'system',
    schema: {
      'name': 'stop_onebot',
      'description': '停止 OneBot WebSocket 服务',
      'parameters': {'type': 'object', 'properties': {}}
    },
    handler: (args) async {
      await dbs.DB.setConfig('onebot_enabled', 'false');
      await ob.OneBotBridge().stop();
      return jsonEncode({'stopped': true});
    },
  ));

  // ── onebot_status — 查看状态 ──
  registry.register(ToolEntry(
    name: 'onebot_status',
    toolset: 'system',
    schema: {
      'name': 'onebot_status',
      'description': '查看 OneBot 桥接服务状态：是否运行、连接数、端口',
      'parameters': {'type': 'object', 'properties': {}}
    },
    handler: (args) async {
      final bridge = ob.OneBotBridge();
      return jsonEncode({
        'running': bridge.isRunning,
        'port': bridge.port,
        'clients': bridge.clientCount,
        'hint': bridge.isRunning
            ? 'NapCatQQ 反向 WebSocket 地址：ws://<手机IP>:${bridge.port}/onebot'
            : '服务未运行，调用 start_onebot 启动'
      });
    },
  ));
}
