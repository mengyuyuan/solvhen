// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 消息数据模型——对话中的单条消息，支持user/assistant/tool三种角色
// ═══════════════════════════════════════════════════════════════

library;

class Message {
  final int? id;
  final int conversationId;
  final String content;
  final String role; // 'user' | 'assistant' | 'tool'
  final DateTime timestamp;
  final int tokenCount;
  final String? toolCallId;   // for tool results
  final String? toolCallsJson; // for assistant messages with tool_calls (raw JSON array)

  const Message({
    this.id,
    this.conversationId = 1,
    required this.content,
    required this.role,
    required this.timestamp,
    this.tokenCount = 0,
    this.toolCallId,
    this.toolCallsJson,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'conversation_id': conversationId,
        'content': content,
        'role': role,
        'timestamp': timestamp.toIso8601String(),
        'token_count': tokenCount,
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (toolCallsJson != null) 'tool_calls_json': toolCallsJson,
      };

  static DateTime _parseDateTime(dynamic value) {
    if (value is String) {
      try {
        return DateTime.parse(value);
      } catch (_) {
        return DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    return DateTime.now();
  }

  factory Message.fromMap(Map<String, dynamic> map) => Message(
        id: map['id'] as int?,
        conversationId: map['conversation_id'] as int? ?? 1,
        content: map['content'] as String,
        role: map['role'] as String,
        timestamp: _parseDateTime(map['timestamp']),
        tokenCount: map['token_count'] as int? ?? 0,
        toolCallId: map['tool_call_id'] as String?,
        toolCallsJson: map['tool_calls_json'] as String?,
      );
}
