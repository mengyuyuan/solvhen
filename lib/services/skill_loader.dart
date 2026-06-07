// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 技能加载器——从文件系统加载技能SKILL.md并注入prompt
// ═══════════════════════════════════════════════════════════════

library;

/// Replaces the old approach of hardcoding skill text in database_service.dart.
///
/// Skills are .md files with YAML frontmatter in assets/skills/.
/// Frontmatter declares name + priority. The body is the skill content.
///
/// Usage: call SkillLoader.sync() once at startup. Idempotent (uses INSERT OR REPLACE).

import 'package:flutter/services.dart' show rootBundle;
import 'database_service.dart';

/// 技能加载器——从assets/skills/目录加载SKILL.md并同步到DB
/// 启动时自动sync，技能按priority排序注入system prompt
class SkillLoader {
  /// Map of skill name → asset path. Add new skills here.
  /// The .md files live in assets/skills/ and must be declared in pubspec.yaml.
  static const _manifest = <String, String>{
    'project-context': 'assets/skills/project-context.md',
    'web-search-guide': 'assets/skills/web-search-guide.md',
    'memory-protocol': 'assets/skills/memory-protocol.md',
    'solvhen-dev-guide': 'assets/skills/solvhen-dev-guide.md',
    'systematic-debugging': 'assets/skills/systematic-debugging.md',
    'subagent-driven-dev': 'assets/skills/subagent-driven-dev.md',
    'dart-flutter-patterns': 'assets/skills/dart-flutter-patterns.md',
    'conversation-style': 'assets/skills/conversation-style.md',
    'tool-usage': 'assets/skills/tool-usage.md',
    'ui-expression': 'assets/skills/ui-expression.md',
    'canvas-usage': 'assets/skills/canvas-usage.md',
  };

  /// Load all skill files and upsert into DB. Idempotent — safe to call every startup.
  static Future<void> sync() async {
    for (final entry in _manifest.entries) {
      try {
        final raw = await rootBundle.loadString(entry.value);
        final parsed = _parseFrontmatter(raw);
        final name = parsed['name'] ?? entry.key;
        final priority = int.tryParse(parsed['priority']?.toString() ?? '') ?? 0;
        final content = parsed['body'] ?? raw;
        await DB.addSkill(name, content, priority: priority);
      } catch (_) {
        // Missing file or parse error — skip, don't crash the app.
        // Existing DB skills remain untouched.
      }
    }
  }

  /// Parse YAML frontmatter from a skill .md file.
  /// Returns {'name': ..., 'priority': ..., 'body': ...}.
  static Map<String, String> _parseFrontmatter(String raw) {
    final result = <String, String>{};
    if (!raw.startsWith('---')) {
      result['body'] = raw;
      return result;
    }
    final secondDelim = raw.indexOf('---', 3);
    if (secondDelim == -1) {
      result['body'] = raw;
      return result;
    }
    final frontmatter = raw.substring(4, secondDelim).trim();
    final body = raw.substring(secondDelim + 3).trim();

    for (final line in frontmatter.split('\n')) {
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      final key = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      result[key] = value;
    }
    result['body'] = body;
    return result;
  }
}
