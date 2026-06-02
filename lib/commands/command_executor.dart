/// Executes slash commands — handles theme, system, file operations.
library;

import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'command_registry.dart';
import '../theme/theme_provider.dart';
import '../tools/native_bridge.dart';
import '../tools/tools_system.dart';
import '../tools/tool_utils.dart';
import '../services/database_service.dart';
import '../screens/chat_provider.dart';

class CommandExecutor {

  /// Execute a slash action and return a result message.
  static Future<String> execute(SlashAction action, WidgetRef ref) async {
    final cmd = action.command.name;
    final args = action.args;

    try {
      switch (cmd) {
      // ── 对话 ──
      case 'new':
        final oldConvId = ref.read(chatProvider).conversationId;
        final conv = await DB.createConversation();
        // Switch to the new conversation — this also triggers consolidation
        await ref.read(chatProvider.notifier).switchConversation(conv.id!);
        return '✅ 已创建新对话 #${conv.id}。上一段对话的记忆已保存。';

      case 'clear':
        final db = await DB.database;
        // Get current conversation ID from provider
        final chatState = ref.read(chatProvider);
        await db.delete('messages',
          where: 'conversation_id = ?',
          whereArgs: [chatState.conversationId],
        );
        await DB.touchConversation(chatState.conversationId);
        return '🗑️ 对话记录已清除';

      // ── 主题 ──
      case 'theme':
        if (args.isEmpty) return '用法: /theme blue|green|purple|pink|dark|light';
        final arg = args[0].toLowerCase();
        if (arg == 'dark') {
          ThemeNotifier().setBrightness('dark');
          return '✅ 已切换为暗色模式';
        }
        if (arg == 'light') {
          ThemeNotifier().setBrightness('light');
          return '✅ 已切换为浅色模式';
        }
        ThemeNotifier().setAccentColor(arg);
        return '✅ 主题色已更新';

      // ── 系统 ──
      case 'battery':
        final b = await NativeBridge.getBattery();
        final level = b['level'];
        final charging = b['charging'] == true ? ' ⚡充电中' : '';
        return '🔋 电量: $level%$charging';

      case 'time':
        final now = DateTime.now();
        final w = ['一','二','三','四','五','六','日'][now.weekday - 1];
        return '🕐 ${now.hour}时${now.minute}分 星期$w';

      case 'device':
        final d = await NativeBridge.getDeviceInfo();
        return '📱 ${d['manufacturer']} ${d['model']} · Android ${d['androidVersion']}';

      case 'volume':
        if (args.isEmpty) {
          final v = await NativeBridge.getVolume();
          return '🔊 音量: ${v['level']}/${v['max']}';
        }
        final lvl = clampInt(int.tryParse(args[0]) ?? 50, 0, 100);
        await NativeBridge.setVolume(lvl);
        final v = await NativeBridge.getVolume();
        return '🔊 音量已设为 ${v['level']}/${v['max']}';

      case 'brightness':
        if (args.isEmpty) {
          final b = await NativeBridge.getBrightness();
          return '💡 亮度: ${b['level']}/${b['max']}';
        }
        final lvl = clampInt(int.tryParse(args[0]) ?? 128, 0, 255);
        await NativeBridge.setBrightness(lvl);
        final b = await NativeBridge.getBrightness();
        return '💡 亮度已设为 ${b['level']}/${b['max']}';

      case 'wifi':
        if (args.isEmpty) return '用法: /wifi on|off';
        final enable = args[0] == 'on';
        await NativeBridge.toggleWifi(enable);
        return enable ? '📶 WiFi 已打开' : '📶 WiFi 已关闭';

      case 'bt':
        if (args.isEmpty) return '用法: /bt on|off';
        final enable = args[0] == 'on';
        await NativeBridge.toggleBluetooth(enable);
        return enable ? '🔵 蓝牙已打开' : '🔵 蓝牙已关闭';

      case 'open':
        if (args.isEmpty) return '用法: /open 应用名';
        final pkg = resolveAppPackage(args.join(''));
        await NativeBridge.openApp(pkg);
        return '✅ 已打开';

      case 'silent':
        await NativeBridge.setRingerMode('silent');
        return '🔇 已切换为静音模式';

      case 'ring':
        await NativeBridge.setRingerMode('normal');
        return '🔔 已切换为响铃模式';

      // ── 技能 ──
      case 'skills':
        if (args.isEmpty) return '用法: /skills list | toggle <技能名>';
        final sub = args[0].toLowerCase();
        if (sub == 'list') {
          final skills = await DB.getAllSkills();
          if (skills.isEmpty) return '📋 暂无安装的技能';
          final buf = StringBuffer('📋 已安装技能:\n');
          for (final s in skills) {
            final enabled = (s['enabled'] as int) == 1 ? '✅' : '❌';
            buf.writeln('  $enabled ${s['name']} (优先:${s['priority']})');
          }
          return buf.toString();
        }
        if (sub == 'toggle' && args.length > 1) {
          final name = args[1];
          final skills = await DB.getAllSkills();
          final skill = skills.cast<Map<String, dynamic>?>().firstWhere(
            (s) => s?['name'] == name,
            orElse: () => null,
          );
          if (skill == null) return '未找到技能: $name';
          final enabled = (skill['enabled'] as int) == 1;
          await DB.toggleSkill(name, !enabled);
          return '${!enabled ? '✅' : '❌'} $name ${!enabled ? '已启用' : '已禁用'}。重启对话生效。';
        }
        return '用法: /skills list | toggle <技能名>';

      // ── 记忆 ──
      case 'memory':
        if (args.isEmpty) return '用法: /memory add <内容> | list | delete <id>';
        final sub = args[0].toLowerCase();
        if (sub == 'list') {
          final memories = await DB.getGlobalMemories();
          if (memories.isEmpty) return '🧠 暂无存储的记忆';
          final buf = StringBuffer('🧠 已存储的记忆:\n');
          int idx = 1;
          for (final entry in memories.entries) {
            for (final m in entry.value) {
              buf.writeln('  $idx. [${entry.key}] $m');
              idx++;
            }
          }
          return buf.toString();
        }
        if (sub == 'add' && args.length > 1) {
          final content = args.sublist(1).join(' ');
          await DB.saveGlobalMemory(category: 'fact', content: content);
          return '✅ 已记忆: $content';
        }
        if (sub == 'delete' && args.length > 1) {
          return '⚠️ 请按序号删除，先用 /memory list 查看序号';
        }
        return '用法: /memory add <内容> | list | delete <序号>';

      // ── 文件 ──
      case 'save':
        final db = await DB.database;
        final chatState = ref.read(chatProvider);
        final rows = await db.query('messages',
          where: 'conversation_id = ?',
          whereArgs: [chatState.conversationId],
          orderBy: 'timestamp ASC',
          limit: 100);
        final text = rows.map((r) {
          final role = r['role'] == 'user' ? '你' : 'Solvhen';
          return '[$role] ${r['content']}';
        }).join('\n\n');
        final truncatedNote = rows.length >= 100 ? '（仅最近100条消息）\n' : '';

        final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);
        final name = '对话记录_$timestamp.txt';
        final dir = await _sfDir();
        final file = await File('${dir.path}/$name').create(recursive: true);
        await file.writeAsString('$truncatedNote$text');
        return '✅ 已保存: $name';

      case 'files':
        final dir = await _sfDir();
        if (!await dir.exists()) return '📁 暂无文件';
        final files = <String>[];
        await for (final e in dir.list()) {
          if (e is File) files.add(e.uri.pathSegments.last);
        }
        if (files.isEmpty) return '📁 暂无文件';
        return '📁 文件 (${files.length}):\n${files.map((f) => '  · $f').join('\n')}';

      default:
        return '未知指令: /$cmd。输入 / 查看可用指令。';
      }
    } catch (e) {
      return '⚠️ 指令执行失败: ${e.toString().length > 100 ? '${e.toString().substring(0, 100)}…' : e}';
    }
  }
}

Future<Directory> _sfDir() async {
  final appDir = await getApplicationDocumentsDirectory();
  return Directory('${appDir.path}/solvhen_files');
}
