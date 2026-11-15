/// Solvhen AI手机智能体 — 设备操控工具集（device）
/// 目标：让 Agent 真正"看懂"并"无缝操控"任意应用，而不只是盲点坐标。
///
/// 设计（对齐 Mika 的 on-device agent 路线，保留 Solvhen 的安全模型）：
///   1. device_screen 给出结构化 UI 树，节点带稳定 id
///   2. device_tap 用 id 精准点击，文字重名也不会点错
///   3. device_wait / device_scroll 让每步都有确认，不靠猜
///   4. device_act 一次确认执行整段序列，避免逐步往返造成界面漂移
///
/// 推荐循环：device_app → device_screen → device_tap(id) → device_wait → device_screen
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/security/tool_security.dart';
import 'native_bridge.dart';
import 'tool_registry.dart';

/// 注册设备操控工具集
void registerDeviceTools() {
  final registry = ToolRegistry();

  // ── device_screen — 结构化读取当前界面 ──
  registry.register(ToolEntry(
    name: 'device_screen',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.read,
    schema: {
      'name': 'device_screen',
      'description':
          '读取当前手机界面的结构化 UI 树。返回每个节点的 id、文字(text)、描述(desc)、控件类型(class)、'
          '是否可点击(clickable)、是否可输入(editable)、是否可滚动(scrollable)、坐标(bounds)和层级(depth)。'
          '拿到 id 后用 device_tap 精准点击——这是操控应用的第一步，也是每步动作后确认结果的手段。',
      'parameters': {
        'type': 'object',
        'properties': {
          'includeInvisible': {
            'type': 'boolean',
            'description': '是否包含不可见节点，默认 false。排查"元素明明存在却读不到"时可开。',
          },
          'maxNodes': {
            'type': 'integer',
            'description': '最多返回多少节点，默认 600，范围 50-3000。',
          },
        },
        'required': <String>[],
      },
    },
    handler: (args) async {
      final result = await NativeBridge.uiDump(
        includeInvisible: args['includeInvisible'] as bool? ?? false,
        maxNodes: (args['maxNodes'] as num?)?.toInt() ?? 600,
      );
      return jsonEncode(_compactScreen(result));
    },
  ));

  // ── device_find — 条件查找节点 ──
  registry.register(ToolEntry(
    name: 'device_find',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.read,
    schema: {
      'name': 'device_find',
      'description':
          '按条件在当前界面查找节点，比整屏读取更省上下文。可组合文字、控件类型、是否可点击/可输入/可滚动。'
          '返回匹配节点的 id 和坐标，可直接交给 device_tap。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '要匹配的文字（默认包含匹配）'},
          'viewId': {'type': 'string', 'description': '控件资源 id，如 btn_send'},
          'className': {'type': 'string', 'description': '控件类型简名，如 Button、EditText'},
          'clickableOnly': {'type': 'boolean', 'description': '只返回可点击节点'},
          'editableOnly': {'type': 'boolean', 'description': '只返回可输入节点'},
          'scrollableOnly': {'type': 'boolean', 'description': '只返回可滚动节点'},
          'exact': {'type': 'boolean', 'description': '文字是否精确匹配，默认 false'},
          'limit': {'type': 'integer', 'description': '最多返回多少条，默认 20'},
        },
        'required': <String>[],
      },
    },
    handler: (args) async {
      final result = await NativeBridge.uiFind(
        text: args['text'] as String? ?? '',
        viewId: args['viewId'] as String? ?? '',
        className: args['className'] as String? ?? '',
        clickableOnly: args['clickableOnly'] as bool? ?? false,
        editableOnly: args['editableOnly'] as bool? ?? false,
        scrollableOnly: args['scrollableOnly'] as bool? ?? false,
        exact: args['exact'] as bool? ?? false,
        limit: (args['limit'] as num?)?.toInt() ?? 20,
      );
      return jsonEncode(result);
    },
  ));

  // ── device_tap — 点击 ──
  registry.register(ToolEntry(
    name: 'device_tap',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.modify,
    schema: {
      'name': 'device_tap',
      'description':
          '点击界面元素。优先传 id（来自 device_screen / device_find），会自己找可点击祖先，比坐标可靠；'
          '也可以传 text 让它在屏幕上找；实在没有节点信息才用 x/y 坐标。'
          '点击后建议跟一个 device_wait 或 device_screen 确认结果。',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'description': '节点 id（推荐）'},
          'text': {'type': 'string', 'description': '要点击的文字，未提供 id 时使用'},
          'exact': {'type': 'boolean', 'description': '文字是否精确匹配，默认 false'},
          'x': {'type': 'number', 'description': 'X 坐标，仅在没有 id/text 时使用'},
          'y': {'type': 'number', 'description': 'Y 坐标，仅在没有 id/text 时使用'},
        },
        'required': <String>[],
      },
    },
    handler: (args) async {
      final id = (args['id'] as num?)?.toInt();
      if (id != null) {
        return jsonEncode(await NativeBridge.uiTapNode(id));
      }
      final text = args['text'] as String?;
      if (text != null && text.isNotEmpty) {
        return jsonEncode(await NativeBridge.uiTapText(
          text,
          exact: args['exact'] as bool? ?? false,
        ));
      }
      final x = args['x'] as num?;
      final y = args['y'] as num?;
      if (x != null && y != null) {
        return jsonEncode(await NativeBridge.inputTap(
          x.toDouble(),
          y.toDouble(),
        ));
      }
      return jsonEncode({'ok': false, 'error': '需要 id、text 或 x/y 之一'});
    },
  ));

  // ── device_input — 输入文字 ──
  registry.register(ToolEntry(
    name: 'device_input',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.modify,
    schema: {
      'name': 'device_input',
      'description':
          '向当前获得焦点的输入框写入文字（整段替换）。如果还没聚焦，先用 device_tap 点一下输入框。'
          '需要发送时，输入完再 device_tap 发送按钮，或 device_act 里用 pressEnter。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '要写入的文字'},
          'clear': {'type': 'boolean', 'description': '先清空原内容，默认 true（SET_TEXT 本身即替换）'},
        },
        'required': ['text'],
      },
    },
    handler: (args) async {
      final text = args['text'] as String? ?? '';
      if (text.isEmpty) {
        return jsonEncode({'ok': false, 'error': 'text 不能为空'});
      }
      return jsonEncode(await NativeBridge.uiTypeText(text));
    },
  ));

  // ── device_scroll — 滑动 / 滚动查找 ──
  registry.register(ToolEntry(
    name: 'device_scroll',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.modify,
    schema: {
      'name': 'device_scroll',
      'description':
          '滑动界面。传 text 时自动滚动查找直到目标出现（推荐——模型不用自己算坐标）；'
          '不传 text 时按 direction 滑一次。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '要滚动查找的目标文字'},
          'maxScrolls': {'type': 'integer', 'description': '最多滚动次数，默认 6'},
          'direction': {
            'type': 'string',
            'description': '滑动方向：up/down/left/right，默认 up',
          },
        },
        'required': <String>[],
      },
    },
    handler: (args) async {
      final text = args['text'] as String?;
      if (text != null && text.isNotEmpty) {
        return jsonEncode(await NativeBridge.uiScrollFind(
          text,
          maxScrolls: (args['maxScrolls'] as num?)?.toInt() ?? 6,
        ));
      }
      return jsonEncode(await NativeBridge.uiSwipe(
        args['direction'] as String? ?? 'up',
      ));
    },
  ));

  // ── device_wait — 等待 ──
  registry.register(ToolEntry(
    name: 'device_wait',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.read,
    schema: {
      'name': 'device_wait',
      'description':
          '等待界面变化。传 text 等某段文字出现（加载完成、消息已发出）；不传则等界面稳定。'
          '每次点击后都应该用它确认，避免在界面还没刷新时就下一步。',
      'parameters': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'description': '等这段文字出现'},
          'timeoutMs': {
            'type': 'integer',
            'description': '超时毫秒，默认 5000，最大 30000',
          },
        },
        'required': <String>[],
      },
    },
    handler: (args) async {
      final text = args['text'] as String?;
      final timeout = (args['timeoutMs'] as num?)?.toInt() ?? 5000;
      if (text != null && text.isNotEmpty) {
        return jsonEncode(
            await NativeBridge.uiWaitText(text, timeoutMs: timeout));
      }
      return jsonEncode(await NativeBridge.uiWaitIdle(timeoutMs: timeout));
    },
  ));

  // ── device_app — 当前前台应用 ──
  registry.register(ToolEntry(
    name: 'device_app',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.read,
    schema: {
      'name': 'device_app',
      'description':
          '获取当前前台应用的包名、应用名和窗口标题。用来确认"我现在到底在哪个应用里"，'
          '在多应用操作或跳转失败时先查这个。',
      'parameters': {'type': 'object', 'properties': {}, 'required': <String>[]},
    },
    handler: (args) async {
      return jsonEncode(await NativeBridge.uiForeground());
    },
  ));

  // ── device_dismiss — 关闭挡路弹窗 ──
  registry.register(ToolEntry(
    name: 'device_dismiss',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.modify,
    schema: {
      'name': 'device_dismiss',
      'description':
          '关闭挡路的弹窗、广告、升级提示。默认只点「取消/关闭/跳过/以后再说」这类安全选项，'
          '不会点「允许」。确实需要授予权限时才把 allowPermissions 设 true。',
      'parameters': {
        'type': 'object',
        'properties': {
          'allowPermissions': {
            'type': 'boolean',
            'description': '是否也点「允许/同意」，默认 false',
          },
          'maxClicks': {
            'type': 'integer',
            'description': '最多关闭几个，默认 2',
          },
        },
        'required': <String>[],
      },
    },
    handler: (args) async {
      return jsonEncode(await NativeBridge.uiDismiss(
        allowPermissions: args['allowPermissions'] as bool? ?? false,
        maxClicks: (args['maxClicks'] as num?)?.toInt() ?? 2,
      ));
    },
  ));

  // ── device_shot — 截图 ──
  registry.register(ToolEntry(
    name: 'device_shot',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.read,
    schema: {
      'name': 'device_shot',
      'description':
          '截取当前屏幕，保存为 JPEG 文件并返回路径。用于 UI 树读不到内容（游戏、视频、'
          '自绘界面、WebView 异常）时兜底，或需要给用户看画面时。',
      'parameters': {
        'type': 'object',
        'properties': {
          'quality': {'type': 'integer', 'description': 'JPEG 质量 20-95，默认 70'},
          'maxWidth': {'type': 'integer', 'description': '最大宽度像素，默认 900'},
          'includePayload': {
            'type': 'boolean',
            'description': '是否同时返回 base64（会占用大量上下文，默认 false）',
          },
        },
        'required': <String>[],
      },
    },
    handler: (args) async {
      final result = await NativeBridge.screenshot(
        quality: (args['quality'] as num?)?.toInt() ?? 70,
        maxWidth: (args['maxWidth'] as num?)?.toInt() ?? 900,
      );
      final encoded = result['base64'] as String?;
      if (encoded == null || encoded.isEmpty) {
        return jsonEncode(result);
      }
      final bytes = base64Decode(encoded);
      try {
        final dir = await getTemporaryDirectory();
        final file = File(
          '${dir.path}/shot_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        await file.writeAsBytes(bytes, flush: true);
        final payload = <String, dynamic>{
          'ok': true,
          'path': file.path,
          'bytes': bytes.length,
          'format': 'jpeg',
        };
        if (args['includePayload'] as bool? ?? false) {
          payload['base64'] = encoded;
        }
        return jsonEncode(payload);
      } catch (e) {
        return jsonEncode({
          'ok': false,
          'error': '截图已获取但写入失败：${e.runtimeType}',
          'bytes': bytes.length,
        });
      }
    },
  ));

  // ── device_act — 原子序列（无缝操控的核心）──
  registry.register(ToolEntry(
    name: 'device_act',
    toolset: 'device',
    capabilities: const {'device'},
    risk: ToolRisk.destructive,
    schema: {
      'name': 'device_act',
      'description':
          '一次执行整段界面动作序列，中途失败立即停止并回报失败的步号。'
          '这是操控手机的主力工具：把"点搜索框→输入→点搜索→等结果"合成一次调用，'
          '避免逐步往返导致界面漂移。每步支持 settleMs（步后等待，默认220）和 optional（失败也继续）。'
          '可用 action：'
          'tap(id 或 text)、tapText(text)、input(text)、swipe(direction)、scrollFind(text)、'
          'wait(text,timeoutMs)、idle、dismiss、back、home、recents、notifications、sleep(ms)。',
      'parameters': {
        'type': 'object',
        'properties': {
          'steps': {
            'type': 'array',
            'description': '动作序列，按顺序执行',
            'items': {
              'type': 'object',
              'properties': {
                'action': {'type': 'string', 'description': '动作名'},
                'id': {'type': 'integer', 'description': 'tap 用：节点 id'},
                'text': {'type': 'string', 'description': 'tap/tapText/input/wait/scrollFind 用'},
                'direction': {'type': 'string', 'description': 'swipe 用：up/down/left/right'},
                'timeoutMs': {'type': 'integer', 'description': 'wait/idle 用'},
                'ms': {'type': 'integer', 'description': 'sleep 用'},
                'settleMs': {'type': 'integer', 'description': '这一步之后的等待'},
                'optional': {'type': 'boolean', 'description': '失败是否继续'},
              },
              'required': ['action'],
            },
          },
        },
        'required': ['steps'],
      },
    },
    handler: (args) async {
      final raw = args['steps'];
      if (raw is! List || raw.isEmpty) {
        return jsonEncode({'ok': false, 'error': 'steps 必须是非空数组'});
      }
      final steps = <Map<String, dynamic>>[];
      for (final item in raw) {
        if (item is Map) {
          steps.add(Map<String, dynamic>.from(item));
        }
      }
      if (steps.isEmpty) {
        return jsonEncode({'ok': false, 'error': 'steps 里没有有效动作'});
      }
      if (steps.length > 40) {
        return jsonEncode({'ok': false, 'error': '单次最多 40 步，请拆成多段'});
      }
      return jsonEncode(await NativeBridge.uiSequence(steps));
    },
  ));
}

/// 精简整屏结果：把与 id 重复的冗余字段去掉，控制 token 消耗。
Map<String, dynamic> _compactScreen(Map<String, dynamic> raw) {
  final nodes = raw['nodes'];
  if (nodes is! List) return raw;
  final compacted = <Map<String, dynamic>>[];
  for (final item in nodes) {
    if (item is! Map) continue;
    final node = <String, dynamic>{'id': item['id']};
    for (final key in const [
      'text',
      'desc',
      'class',
      'viewId',
    ]) {
      final value = item[key];
      if (value is String && value.isNotEmpty) node[key] = value;
    }
    final flags = <String>[];
    for (final entry in const {
      'clickable': '可点击',
      'editable': '可输入',
      'scrollable': '可滚动',
      'checkable': '可勾选',
      'checked': '已勾选',
      'focused': '已聚焦',
    }.entries) {
      if (item[entry.key] == true) flags.add(entry.value);
    }
    if (flags.isNotEmpty) node['flags'] = flags;
    final bounds = item['bounds'];
    if (bounds is Map) {
      node['xy'] = [bounds['cx'], bounds['cy']];
    }
    compacted.add(node);
  }
  return {
    'package': raw['package'],
    'window': raw['window'],
    'count': raw['count'] ?? compacted.length,
    'nodes': compacted,
  };
}