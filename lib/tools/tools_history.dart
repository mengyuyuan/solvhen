/// History search tool — Solvhen searches past conversations.
library;

import 'dart:convert';
import 'tool_registry.dart';
import '../services/database_service.dart';

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
