/// Solvhen AI手机智能体 — 重型记忆管理工具
/// 提供永久记忆的保存、搜索、关联、合并（替换旧轻量 global_memories）。
library;

import 'dart:convert';
import 'tool_registry.dart';
import '../services/memory_service.dart';

/// 注册重型记忆管理工具
/// 工具：save_memory / search_memory / list_memories / link_memories / consolidate_memories / remember_episode
void registerMemoryTools() {
  final registry = ToolRegistry();
  final mem = MemoryService();

  // ── save_memory — 存入永久记忆（带重要性评分） ──
  registry.register(ToolEntry(
    name: 'save_memory',
    toolset: 'memory',
    schema: {
      'name': 'save_memory',
      'description': '''将重要信息存入永久记忆（重型系统：FTS5查重、重要性评分、衰减机制）。
当对方说"记住xxx"、分享个人信息、或你认为值得长期记住时调用。
自动查重——相似记忆会合并而非重复存储。
category: name(名字), preference(偏好), fact(事实), summary(摘要)
importance: 0.0-1.0，越高越不容易被遗忘（默认0.5）''',
      'parameters': {
        'type': 'object',
        'properties': {
          'content': {'type': 'string', 'description': '要记住的内容'},
          'category': {
            'type': 'string',
            'enum': ['name', 'preference', 'fact', 'summary'],
            'description': '类别',
          },
          'importance': {
            'type': 'number',
            'description': '重要性 0-1，默认0.5。核心身份信息给0.9+',
          },
        },
        'required': ['content', 'category'],
      },
    },
    handler: (args) async {
      try {
        final importance = (args['importance'] as num?)?.toDouble() ?? 0.5;
        final entry = await mem.save(
          category: args['category'] as String,
          content: args['content'] as String,
          importance: importance.clamp(0.0, 1.0),
        );
        return jsonEncode({
          'saved': true,
          'id': entry.id,
          'category': entry.category,
          'content': entry.content,
          'importance': entry.importance,
          'merged': entry.accessCount > 1, // >1 说明是合并而非新建
        });
      } catch (e) {
        return jsonEncode({'error': '记忆存储失败: $e'});
      }
    },
  ));

  // ── search_memory — 全文搜索（FTS5）──
  registry.register(ToolEntry(
    name: 'search_memory',
    toolset: 'memory',
    schema: {
      'name': 'search_memory',
      'description': '搜索永久记忆（FTS5全文搜索+重要性排序+关联扩散）。在回应对方之前先用此工具检查是否有相关记忆。',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': '搜索关键词'},
        },
        'required': ['query'],
      },
    },
    handler: (args) async {
      try {
        final query = args['query'] as String;
        final results = await mem.search(query, limit: 15);
        return jsonEncode({
          'query': query,
          'count': results.length,
          'results': results.map((e) => {
            'id': e.id,
            'category': e.category,
            'content': e.content,
            'importance': e.importance.toStringAsFixed(2),
            'effective': e.effectiveImportance().toStringAsFixed(2),
            'access_count': e.accessCount,
          }).toList(),
        });
      } catch (e) {
        return jsonEncode({'error': '搜索失败: $e'});
      }
    },
  ));

  // ── list_memories — 按重要性列出 ──
  registry.register(ToolEntry(
    name: 'list_memories',
    toolset: 'memory',
    schema: {
      'name': 'list_memories',
      'description': '列出所有永久记忆，按有效重要性排序（已计入时间衰减）。',
      'parameters': {'type': 'object', 'properties': {}},
    },
    handler: (args) async {
      try {
        final results = await mem.getTopMemories(limit: 50);
        if (results.isEmpty) return jsonEncode({'memories': [], 'count': 0});
        return jsonEncode({
          'count': results.length,
          'memories': results.map((e) => {
            'id': e.id,
            'category': e.category,
            'content': e.content,
            'importance': e.importance.toStringAsFixed(2),
            'effective': e.effectiveImportance().toStringAsFixed(2),
            'access_count': e.accessCount,
          }).toList(),
        });
      } catch (e) {
        return jsonEncode({'error': '读取失败: $e'});
      }
    },
  ));

  // ── link_memories — 建立记忆关联 ──
  registry.register(ToolEntry(
    name: 'link_memories',
    toolset: 'memory',
    schema: {
      'name': 'link_memories',
      'description': '在两个记忆之间建立关联。relation: related_to(相关), contradicts(矛盾), supports(支持), extends(扩展)',
      'parameters': {
        'type': 'object',
        'properties': {
          'source_id': {'type': 'integer', 'description': '源记忆ID'},
          'target_id': {'type': 'integer', 'description': '目标记忆ID'},
          'relation': {
            'type': 'string',
            'enum': ['related_to', 'contradicts', 'supports', 'extends'],
            'description': '关系类型',
          },
        },
        'required': ['source_id', 'target_id'],
      },
    },
    handler: (args) async {
      try {
        await mem.link(
          args['source_id'] as int,
          args['target_id'] as int,
          relation: (args['relation'] as String?) ?? 'related_to',
        );
        return jsonEncode({'linked': true});
      } catch (e) {
        return jsonEncode({'error': '关联失败: $e'});
      }
    },
  ));

  // ── consolidate_memories — 合并冗余记忆 ──
  registry.register(ToolEntry(
    name: 'consolidate_memories',
    toolset: 'memory',
    schema: {
      'name': 'consolidate_memories',
      'description': '合并冗余记忆。同类别相似度>80%的记忆自动合并，保留重要性更高的。定期调用可清理冗余。',
      'parameters': {'type': 'object', 'properties': {}},
    },
    handler: (args) async {
      try {
        final merged = await mem.consolidate();
        return jsonEncode({'merged': merged, 'message': '已合并 $merged 条冗余记忆'});
      } catch (e) {
        return jsonEncode({'error': '合并失败: $e'});
      }
    },
  ));

  // ── remember_episode — 记录情景记忆 ──
  registry.register(ToolEntry(
    name: 'remember_episode',
    toolset: 'memory',
    schema: {
      'name': 'remember_episode',
      'description': '保存一段对话的情景摘要。当一段对话结束时，总结要点存入情景记忆。',
      'parameters': {
        'type': 'object',
        'properties': {
          'summary': {'type': 'string', 'description': '对话摘要（一句话）'},
          'importance': {'type': 'number', 'description': '重要性 0-1'},
        },
        'required': ['summary'],
      },
    },
    handler: (args) async {
      try {
        // 从当前上下文获取 conversationId——暂用1
        await mem.saveEpisode(
          conversationId: 1,
          summary: args['summary'] as String,
          importance: (args['importance'] as num?)?.toDouble() ?? 0.5,
          startTime: DateTime.now(),
        );
        return jsonEncode({'saved': true});
      } catch (e) {
        return jsonEncode({'error': '保存情景失败: $e'});
      }
    },
  ));
}
