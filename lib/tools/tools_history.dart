// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 历史搜索工具——AI可搜索对话历史记录
// ═══════════════════════════════════════════════════════════════

library;


import 'dart:convert';
import 'tool_registry.dart';
import '../services/database_service.dart';

/// 注册对话历史搜索工具
/// 工具：search_history(搜索对话记录)/get_recent_history(获取最近消息)
/// 底层：FTS5全文搜索，失败回退LIKE模糊匹配
void registerHistoryTool() {
  final registry = ToolRegistry();

  registry.register(ToolEntry(
    name: 'search_history',
    toolset: 'history',
    schema: {
      'name': 'search_history',
      'description': '''搜索所有历史对话记录。用于回答"我们之前聊过xxx吗""你记得我说过yyy吗"等问题。
返回匹配的消息内容、角色和时间。''',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '搜索关键词',
          },
        },
        'required': ['query'],
      },
    },
    handler: (args) async {
      final query = args['query'] as String;
      try {
        final results = await DB.searchMessages(query, limit: 10);
        if (results.isEmpty) {
          return jsonEncode({'success': true, 'query': query, 'results': [], 'message': '没有找到相关记录'});
        }
        final formatted = results.map((r) => {
          'role': r['role'],
          'content': (r['content'] as String).length > 150
              ? '${(r['content'] as String).substring(0, 150)}...'
              : r['content'],
          'timestamp': r['timestamp'],
          'conversation_id': r['conversation_id'],
        }).toList();
        return jsonEncode({'success': true, 'query': query, 'results': formatted, 'count': formatted.length});
      } catch (e) {
        return jsonEncode({'success': false, 'error': e.toString()});
      }
    },
  ));
}
