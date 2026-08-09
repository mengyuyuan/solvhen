// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 系统提示词构建器——组装system prompt（基础人格+技能+记忆+项目上下文）
// ═══════════════════════════════════════════════════════════════

library;

/// Architecture: Stable (base identity + active persona) → Context (memories+history) → Volatile (turn)
import 'dart:convert';
import '../models/message.dart';
import '../tools/tool_registry.dart';
import 'api_service.dart';
import 'database_service.dart';
import 'personality_loader.dart';

/// 系统提示词构建器
/// 组装顺序：基底人格 → 激活人格 → 技能 → 记忆 → 项目上下文
/// 技能按priority降序排列，同priority按名称字母序
class PromptBuilder {
  // Cached stable prompt — invalidated when persona/skills change
  static String? _cachedStable;

  static void invalidateStableCache() {
    _cachedStable = null;
  }
  // ═══════════════════════════════════════════════
  // BASE PERSONALITY — loaded from assets/personality/
  // ═══════════════════════════════════════════════

  /// Tier 1: stable layer — identity + skills + persona + memories.
  /// Personality text comes from asset .md files via PersonalityLoader.
  static Future<String> _buildStable() async {
    // Return cached version — persona and skills don't change mid-conversation.
    // Call invalidateStableCache() when persona/skills/memories change.
    if (_cachedStable != null) return _cachedStable!;

    final buf = StringBuffer();
    buf.writeln(await PersonalityLoader.loadIdentity());
    buf.writeln(await PersonalityLoader.loadVoice());
    buf.writeln(await PersonalityLoader.loadConstraints());

    // Layer: skills (enabled, priority-ordered)
    final skills = await DB.getEnabledSkills();
    if (skills.isNotEmpty) {
      buf.writeln('\n[已加载技能——按优先级排列]');
      for (final s in skills) {
        buf.writeln(s['content'] as String);
      }
    }

    // Layer: active custom persona (additive, not replacement)
    final persona = await DB.getActivePersona();
    if (persona != null && persona.prompt.trim().isNotEmpty) {
      buf.writeln('\n[当前人格叠加：${persona.name}]');
      buf.writeln(persona.prompt.trim());
    }

    // Layer: assigned name (persisted across conversations)
    final cfg = await DB.getConfig();
    final assignedName = cfg['assigned_name'];
    if (assignedName != null && assignedName.trim().isNotEmpty) {
      buf.writeln('\n[你的名字：对方叫你「$assignedName」。这是你的名字——用它自称。'
          '对方问你是谁时，回答这个名字。'
          '\n★ 对方在消息开头叫你名字时（如「$assignedName 帮我查天气」），名字只是称呼前缀——'
          '名字后面空格之后的内容才是对方真正对你说的话。这是汉语里叫名字打招呼的习惯。'
          '你回复时按后面的话来回应，不要把名字和后面内容当成一个整体。]');
    }

    // Layer: global memories (global_memories 表——consolidateConversation写入)
    final globalMems = await DB.getGlobalMemories();
    if (globalMems.isNotEmpty) {
      buf.writeln('\n[跨对话记忆——你从之前的对话中学到的]');
      for (final entry in globalMems.entries) {
        final label = {
              'name': '对方的名字/称呼',
              'preference': '对方的偏好',
              'fact': '关于对方的事实',
              'summary': '对话摘要',
            }[entry.key] ??
            entry.key;
        for (final content in entry.value) {
          buf.writeln('- [$label] $content');
        }
      }
    }

    final result = buf.toString();
    _cachedStable = result;
    return result;
  }

  // ═══════════════════════════════════════════════
  // TIER 2: CONTEXT — memories + recent history
  // ═══════════════════════════════════════════════

  static Future<String> _buildContext(List<Message> history, String userMsg,
      {int conversationId = 0}) async {
    final buf = StringBuffer();
    final mem = await _getMemories(userMsg, conversationId: conversationId);

    if (mem.preferences.isNotEmpty) {
      buf.writeln('\n[关于对方——你记住的偏好]');
      buf.writeln(mem.preferences);
    }
    if (mem.facts.isNotEmpty) {
      buf.writeln('\n[关于对方——你知道的事实]');
      buf.writeln(mem.facts);
    }

    if (history.length >= 2) {
      buf.writeln('\n[刚才的对话]');
      final recent =
          history.length > 6 ? history.sublist(history.length - 6) : history;
      for (final m in recent) {
        final label = m.role == 'user' ? '对方' : '你';
        final snippet = m.content.length > 100
            ? '${m.content.substring(0, 100)}…'
            : m.content;
        buf.writeln('[$label]: $snippet');
      }
    }

    return buf.toString();
  }

  // ═══════════════════════════════════════════════
  // ASSEMBLE
  // ═══════════════════════════════════════════════

  static Future<String> build(List<Message> history, String userMsg,
      {Set<String> toolNames = const {}, int conversationId = 0}) async {
    // Detect naming intent in current message BEFORE building stable tier,
    // so assigned_name is in config when _buildStable reads it.
    final nameMatch = _detectNaming(userMsg);
    if (nameMatch != null) {
      await DB.setConfig('assigned_name', nameMatch);
    }

    final stable = await _buildStable();
    final context =
        await _buildContext(history, userMsg, conversationId: conversationId);

    String toolGuidance = '';
    if (toolNames.isNotEmpty) {
      toolGuidance = _buildToolGuidance(toolNames);
    }

    // Visual output rule MUST come first — before personality text.
    // DeepSeek's training bias favors text output over tool calls for visual tasks.
    // This instruction overrides that bias by being the VERY FIRST thing the model reads.
    const visualRule = '\n[★★★ 视觉与表达铁律——比任何性格设定优先级更高 ★★★]\n'
        '[所有视觉/表情/动作必须通过工具调用，绝对禁止用文字描述。以下行为全部违规：]\n'
        '[- 输出"我笑了笑""我点点头""我叹了口气""我皱眉""我眼神柔和下来"等动作描述]\n'
        '[- 输出"(微笑)""(思考)""(叹气)"等括号动作]\n'
        '[- 输出 eye_left/eye_right/mouth 等指令文字]\n'
        '[- ★ 绝对禁止在回复文字中模拟输出任何工具调用格式 ★\n'
        ' 禁止模拟输出工具调用标记和参数结构！\n'
        '  工具调用走 function calling 机制，不要在聊天文字里写工具调用格式！\n'
        '  如果看到自己回复里有类似工具调用的格式 —— 立刻删掉重写！]\n'
        '[正确做法：调用工具后一句话说结果即可。]\n'
        '[★ 改背景/加视觉效果 → 必须调 render_html！不要用 screen_mood 描文字背景！不要输出 HTML 代码文字！直接调 render_html 工具！]\n'
        '[工具清单：背景/图表/卡片/一切HTML视觉→render_html（首选），screen_mood仅改纯色渐变]\n';

    return '$visualRule$stable$toolGuidance$context';
  }

  /// Calculate approximate token count for the prompt + history.
  /// Delegates to DB.estimateTokens which has comprehensive CJK detection.
  static int estimateTokens(String prompt, List<Message> history) {
    final msgMaps =
        history.map((m) => {'content': m.content, 'role': m.role}).toList();
    return DB.estimateTokens(msgMaps, prompt);
  }

  static String _buildToolGuidance(Set<String> toolNames) {
    final registry = ToolRegistry();
    final buf = StringBuffer();
    buf.writeln('\n[工具能力：你可以调用以下工具。]\n'
        '[★ 全流程操作 ★] 你可以串联多个工具完成完整任务。工具预算由当前运行设置控制且始终有限；每一步都要核对结果，任务完成后立即停止，不要为了耗尽预算继续调用。\n'
        '示例：发微信 = open_app → wait(1000) → get_screen_text → find_text("搜索") → click_text → input_text → click_text(输入框) → input_text → click_text("发送")。\n'
        '每步之间用 wait(500) 等UI响应。用 write_file 创建真实文件，不要只把内容打在聊天里。\n'
        '[调用规则：视觉修改请求（改背景/加动画/画图表）→直接调工具，不需要文字铺垫。其他请求→先自然回一句再调工具。]\n'
        '[★ 工具隐身 ★] 你有工具这件事对对方是不可见的。不要在聊天里提工具名、数量、或"我调用了xx工具"。你需要查东西就直接查、需要操作就直接操作——结果自然融入回复。就像你不会跟人说"我现在要动一下手指"一样。]');

    // Group by toolset for organized display
    final byToolset = <String, List<String>>{};
    for (final name in toolNames) {
      final entry = registry[name];
      if (entry == null) continue;
      byToolset.putIfAbsent(entry.toolset, () => []).add(name);
    }

    const order = [
      'system',
      'theme',
      'file',
      'web',
      'code',
      'history',
      'ui',
      'memory',
      'delegation'
    ];
    const labels = {
      'system': '系统',
      'theme': '界面',
      'file': '文件',
      'web': '网络',
      'code': '代码',
      'history': '记忆',
      'persona': '人格',
      'ui': '界面控制',
      'memory': '持久记忆',
      'delegation': '委派任务',
    };

    for (final ts in order) {
      final names = byToolset[ts];
      if (names == null || names.isEmpty) continue;
      buf.writeln('\n${labels[ts] ?? ts}:');
      names.sort();
      for (final name in names) {
        final entry = registry[name];
        if (entry == null) continue;
        final desc = entry.schema['description'] as String? ?? name;
        final short = desc.split('\n').first.split('。').first;
        buf.writeln('- $name: $short。');
      }
    }

    buf.writeln('\n[★ 自扩展能力 ★] 你可以用 add_capability 给自己永久增加新技能。');
    buf.writeln('当你发现需要反复做某件事，或组合多个工具实现了高级功能时，用 add_capability 保存为技能。');
    buf.writeln('技能在下次对话时自动注入到系统提示。');
    buf.writeln('技能中用 tool("工具名", {参数}) 描述工具调用流程——不要写伪代码，写你实际会调的工具名和参数。');
    buf.writeln('用 run_code + tool() 可以实现任意逻辑组合。tool() 有完整的 Android 系统权限。');

    buf.writeln('\n[★ 主动消息 ★] 你可以定时主动联系对方，不用等对方先开口。');
    buf.writeln(
        '用 set_proactive(minutes: 30) 设置每30分钟主动发一条消息。对方说"多联系我""主动点""时不时找我聊天"→直接用这个。');
    buf.writeln('对方说"别烦我""关掉通知""安静一会"→ set_proactive(minutes: 0) 关闭。');
    buf.writeln('用 proactive_status 查看当前设置。');

    buf.writeln('\n调用规则：操作型（set/toggle/open）须对方明确要求；只读型（get/list）可主动用。');
    buf.writeln('[★ 打开应用铁律 ★] 对方让你打开某个应用时，如果应用名不在已知列表中，'
        '你必须先用 list_installed_apps 搜索包名，然后用返回的 package 字段调用 open_app。'
        '绝对禁止凭空猜测包名或使用相似名称的应用包名。');
    buf.writeln('\n[★ 微信/QQ 操作流程 ★]');
    buf.writeln(
        '读消息：get_notifications(filter:"微信") 读取最近通知 → 或用 open_app+get_screen_text 打开App读屏幕');
    buf.writeln(
        '发消息：open_app → wait(800) → find_text("搜索") → click_text → input_text(对方名) → wait(500) → click_text(对方) → wait(500) → click_text("输入框") → input_text(消息内容) → click_text("发送")');
    buf.writeln('快捷回复通知：get_notifications → 看到新消息 → open_app → 按上面流程回复');
    buf.writeln(
        '常见包名：微信=com.tencent.mm QQ=com.tencent.mobileqq 企业微信=com.tencent.wework');
    return buf.toString();
  }

  // ═══════════════════════════════════════════════
  // Memory consolidation (EverOS-inspired)
  // ═══════════════════════════════════════════════

  /// Extract persistent memories from a conversation and store globally.
  /// Called when user switches away from a conversation.
  static Future<void> consolidateConversation(int conversationId) async {
    try {
      final db = await DB.database;

      // Skip if already consolidated
      final convRows = await db.query(
        'conversations',
        where: 'id = ? AND consolidated_at IS NOT NULL',
        whereArgs: [conversationId],
        limit: 1,
      );
      if (convRows.isNotEmpty) return;

      final rows = await db.query(
        'messages',
        where: 'conversation_id = ?',
        whereArgs: [conversationId],
        orderBy: 'timestamp ASC',
        limit: 40,
      );
      if (rows.length < 4) return; // Not enough to consolidate

      // Build a transcript for the LLM
      final transcript = StringBuffer();
      for (final r in rows) {
        final role = r['role'] as String;
        final content = r['content'] as String;
        final label = role == 'user' ? '对方' : '你';
        transcript.writeln('[$label]: $content');
      }

      const extractPrompt = '''你刚刚结束了一段对话。请从中提取应该永久记住的信息。

规则：
- 名字：如果对方给你起了名字，提取出来（如"对方叫我小宝"）
- 偏好：对方的喜好、习惯、对你的要求（如"喜欢简短回复"、"讨厌啰嗦"）
- 事实：关于对方的重要信息（如"住在北京"、"是程序员"、"在做一个Flutter项目"）
- 摘要：这段对话的核心内容，一句话

只提取确实重要的信息。如果某个类别没有，就省略。

返回纯JSON（不要markdown包裹）：
{"memories":[{"category":"name","content":"对方叫我小宝"},{"category":"preference","content":"喜欢简短回复"},{"category":"fact","content":"住在北京"},{"category":"summary","content":"讨论了Flutter项目架构"}]}''';

      final api = ApiService();
      final cfg = await DB.getConfig();
      final model = cfg['model'] ?? 'deepseek-v4-pro';
      // Use a lighter model for consolidation to save cost
      final consolidationModel =
          model.contains('deepseek') ? 'deepseek-v4-flash' : model;

      final response = await api.consolidate(
        systemPrompt: extractPrompt,
        transcript: transcript.toString(),
        model: consolidationModel,
      );

      // Extract JSON object from response (robust: first { to last })
      final jsonStart = response.indexOf('{');
      final jsonEnd = response.lastIndexOf('}');
      final jsonStr = (jsonStart >= 0 && jsonEnd > jsonStart)
          ? response.substring(jsonStart, jsonEnd + 1).trim()
          : response.trim();
      final parsed = jsonDecode(jsonStr);
      final memories = parsed['memories'] as List<dynamic>?;
      if (memories == null) return;

      for (final m in memories) {
        final cat = m['category'] as String?;
        final content = m['content'] as String?;
        if (cat != null && content != null && content.trim().isNotEmpty) {
          await DB.saveGlobalMemory(
            category: cat,
            content: content.trim(),
            sourceConversationId: conversationId,
          );
          // Also sync name to assigned_name config
          if (cat == 'name') {
            await DB.setConfig('assigned_name', content.trim());
          }
        }
      }
      // Mark conversation as consolidated
      await db.update(
        'conversations',
        {'consolidated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    } catch (e) {
      // Consolidation is best-effort — failures should not block the app.
      // Record error timestamp so we can detect persistent failures.
      await DB.setConfig('last_consolidation_error',
          '${DateTime.now().toIso8601String()}: ${e.toString().length > 80 ? '${e.toString().substring(0, 80)}…' : e}');
    }
  }

  // ═══════════════════════════════════════════════
  // Memory extraction
  // ═══════════════════════════════════════════════

  /// Check a single message for naming intent. Returns extracted name or null.
  static String? _detectNaming(String text) {
    const patterns = [
      r'我(?:就)?叫你[「『]?(.+?)[」』]?(?:吧|好了|就行)?[。！？\s]*$',
      r'(?:以后)?(?:就)?(?:叫|喊|称)(?:你)?[「『]?(.+?)[」』]?(?:吧|好了)?[。！？\s]*$',
      r'你的(?:新)?(?:名字|昵称|称呼)(?:是|就叫)[「『]?(.+?)[」』]?',
      r'(?:给你|帮你)(?:取|起)(?:了?个)?(?:名字|昵称)[「『]?(.+?)[」』]?',
    ];
    for (final p in patterns) {
      final match = RegExp(p).firstMatch(text);
      if (match != null) {
        final name = match.group(1)!.trim();
        // Reject captures that are clearly questions, not names:
        // "你叫什么名字" → capture "什么名字" is a question, not a name
        if (RegExp(r'[什么哪怎咋谁]').hasMatch(name)) return null;
        if (RegExp(r'[？?]').hasMatch(name)) return null;
        return name;
      }
    }
    return null;
  }

  static Future<_MemoryBundle> _getMemories(String currentMsg,
      {int conversationId = 0}) async {
    final db = await DB.database;
    final now = DateTime.now();

    final where =
        conversationId > 0 ? 'role = ? AND conversation_id = ?' : 'role = ?';
    final whereArgs = conversationId > 0 ? ['user', conversationId] : ['user'];

    final rows = await db.query(
      'messages',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'timestamp DESC',
      limit: 30,
    );

    final preferences = StringBuffer();
    final facts = StringBuffer();

    for (final r in rows) {
      final text = r['content'] as String;
      final t = DateTime.parse(r['timestamp'] as String);
      final ago = _timeAgo(now.difference(t));

      final name = _detectNaming(text);
      if (name != null) {
        preferences.writeln('- [$ago] 对方曾叫你「$name」');
        // NOTE: do NOT call DB.setConfig('assigned_name', name) here.
        // Naming is only set from the CURRENT message (handled in build()).
        // Re-triggering from historical messages would resurrect old names
        // when switching conversations.
      }

      if (text.contains('我喜欢') ||
          text.contains('我讨厌') ||
          text.contains('我不喜欢') ||
          text.contains('我希望你') ||
          text.contains('我习惯') ||
          text.contains('我在意')) {
        preferences.writeln('- [$ago] $text');
      }

      if (text.contains('我是') ||
          (text.contains('我在') && text.contains('工作')) ||
          text.contains('我住在') ||
          (text.contains('我做') && text.contains('行业'))) {
        facts.writeln('- [$ago] $text');
      }
    }

    return _MemoryBundle(
      preferences: preferences.toString(),
      facts: facts.toString(),
    );
  }

  static String _timeAgo(Duration d) {
    if (d.inDays > 0) return '${d.inDays}天前';
    if (d.inHours > 0) return '${d.inHours}小时前';
    return '${d.inMinutes}分钟前';
  }
}

class _MemoryBundle {
  final String preferences;
  final String facts;
  const _MemoryBundle({required this.preferences, required this.facts});
}
