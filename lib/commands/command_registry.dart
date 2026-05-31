/// Slash command system — like Hermes's command registry.
/// Commands starting with / are intercepted before reaching the AI.
library;

/// A single slash command definition.
class CommandDef {
  final String name;
  final String description;
  final String argsHint;
  final CommandCategory category;

  const CommandDef({
    required this.name,
    required this.description,
    this.argsHint = '',
    this.category = CommandCategory.general,
  });

  String get fullName => '/$name';
}

enum CommandCategory { theme, system, file, chat, conversation, general }

/// Central command registry — all slash commands defined here.
class CommandRegistry {
  static const commands = [
    // ── 对话 ──
    CommandDef(name: 'new', description: '开启新对话', category: CommandCategory.conversation),
    CommandDef(name: 'clear', description: '清除当前对话记录', category: CommandCategory.chat),

    // ── 主题 ──
    CommandDef(name: 'theme', description: '切换主题色', argsHint: 'blue|green|purple|pink|dark|light', category: CommandCategory.theme),

    // ── 系统 ──
    CommandDef(name: 'battery', description: '查看电量', category: CommandCategory.system),
    CommandDef(name: 'time', description: '查看时间', category: CommandCategory.system),
    CommandDef(name: 'device', description: '查看手机信息', category: CommandCategory.system),
    CommandDef(name: 'volume', description: '调节音量', argsHint: '0-100', category: CommandCategory.system),
    CommandDef(name: 'brightness', description: '调节亮度', argsHint: '0-255', category: CommandCategory.system),
    CommandDef(name: 'wifi', description: '开关 WiFi', argsHint: 'on|off', category: CommandCategory.system),
    CommandDef(name: 'bt', description: '开关蓝牙', argsHint: 'on|off', category: CommandCategory.system),
    CommandDef(name: 'open', description: '打开应用', argsHint: '微信|QQ|地图|...', category: CommandCategory.system),
    CommandDef(name: 'silent', description: '静音模式', category: CommandCategory.system),
    CommandDef(name: 'ring', description: '响铃模式', category: CommandCategory.system),

    // ── 技能 ──
    CommandDef(name: 'skills', description: '管理已安装技能', argsHint: 'list|toggle <name>', category: CommandCategory.general),

    // ── 记忆 ──
    CommandDef(name: 'memory', description: '记忆管理', argsHint: 'add|list|delete', category: CommandCategory.chat),

    // ── 文件 ──
    CommandDef(name: 'save', description: '保存对话为文件', category: CommandCategory.file),
    CommandDef(name: 'files', description: '列出已保存的文件', category: CommandCategory.file),
  ];

  /// Find matching commands for autocomplete.
  static List<CommandDef> suggest(String prefix) {
    if (!prefix.startsWith('/')) return [];
    final q = prefix.substring(1).toLowerCase();
    if (q.isEmpty) return commands;
    return commands.where((c) => c.name.startsWith(q)).toList();
  }

  /// Parse a slash command input and return action.
  static SlashAction? parse(String input) {
    if (!input.startsWith('/')) return null;
    final parts = input.trim().split(RegExp(r'\s+'));
    final cmd = parts[0].substring(1).toLowerCase();
    final args = parts.length > 1 ? parts.sublist(1) : <String>[];

    final def = commands.cast<CommandDef?>().firstWhere(
      (c) => c?.name == cmd,
      orElse: () => null,
    );
    if (def == null) return null;

    return SlashAction(command: def, args: args);
  }
}

/// Result of parsing a slash command.
class SlashAction {
  final CommandDef command;
  final List<String> args;

  const SlashAction({required this.command, required this.args});
}
