/// Memory tools — save/recall memories on demand (like Hermes).
library;

import 'dart:convert';
import 'tool_registry.dart';
import '../services/database_service.dart';

void registerMemoryTools() {
  final registry = ToolRegistry();

  registry.register(ToolEntry(
    name: 'save_memory',
    toolset: 'memory',
    schema: {
      'name': 'save_memory',
      'description': '''将重要信息存入永久记忆。
当对方说"记住xxx"、"别忘了xxx"、"以后都xxx"时调用。
当对方分享个人信息（姓名、偏好、习惯、事实）时判断是否长期有用，是则调用。
category: name(名字), preference(偏好), fact(事实), summary(摘要)
不要问"要我记住吗"——判断了就存。''',
      'parameters': {
        'type': 'object',
        'properties': {
          'content': {'type': 'string', 'description': '要记住的内容'},
          'category': {
            'type': 'string',
            'enum': ['name', 'preference', 'fact', 'summary'],
            'description': '类别：名字、偏好、事实、摘要',
          },
        },
        'required': ['content', 'category'],
      },
    },
    handler: (args) async {
      try {
        await DB.saveGlobalMemory(
          category: args['category'] as String,
          content: args['content'] as String,
        );
        return jsonEncode({'saved': true, 'category': args['category'], 'content': args['content']});
      } catch (e) {
        return jsonEncode({'error': '记忆存储失败: $e'});
      }
    },
  ));

  registry.register(ToolEntry(
    name: 'list_memories',
    toolset: 'memory',
    schema: {
      'name': 'list_memories',
      'description': '列出所有已存储的永久记忆，按类别分组。',
      'parameters': {'type': 'object', 'properties': {}, 'required': []},
    },
    handler: (args) async {
      try {
        final memories = await DB.getGlobalMemories();
        if (memories.isEmpty) return jsonEncode({'memories': {}});
        return jsonEncode({'memories': memories});
      } catch (e) {
        return jsonEncode({'error': '读取记忆失败: ${e.toString().substring(0, 80)}'});
      }
    },
  ));

  registry.register(ToolEntry(
    name: 'search_memory',
    toolset: 'memory',
    schema: {
      'name': 'search_memory',
      'description': '搜索已存储的记忆。在回应对方之前先用此工具检查是否有相关记忆。',
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
        final query = (args['query'] as String).toLowerCase();
        final memories = await DB.searchGlobalMemories(query);
        final results = <Map<String, String>>[];
        for (final entry in memories.entries) {
          for (final m in entry.value) {
            results.add({'category': entry.key, 'content': m});
          }
        }
        return jsonEncode({'results': results, 'query': query});
      } catch (e) {
        return jsonEncode({'error': '搜索记忆失败: ${e.toString().substring(0, 80)}'});
      }
    },
  ));
}
