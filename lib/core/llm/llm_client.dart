import '../../models/message.dart';
import '../../services/tool_executor.dart';
import '../agent/cancellation.dart';

class LlmUsage {
  const LlmUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });

  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  factory LlmUsage.fromJson(Map<String, dynamic> json) => LlmUsage(
        promptTokens: (json['prompt_tokens'] as num?)?.toInt() ?? 0,
        completionTokens: (json['completion_tokens'] as num?)?.toInt() ?? 0,
        totalTokens: (json['total_tokens'] as num?)?.toInt() ?? 0,
      );
}

abstract interface class LlmClient {
  Future<({String content, LlmUsage? usage})> chatStream({
    required String systemPrompt,
    required List<Message> history,
    required String userMessage,
    void Function(String chunk)? onChunk,
    AgentCancellationToken? cancellation,
  });

  Future<({
    String content,
    List<ToolCall>? toolCalls,
    List<dynamic>? rawToolCalls,
    LlmUsage? usage,
  })> chatWithTools({
    required String systemPrompt,
    required List<Message> history,
    required String userMessage,
    required List<Map<String, dynamic>> tools,
    int maxTokens = 4096,
    AgentCancellationToken? cancellation,
  });
}
