import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/screens/chat_provider.dart';

void main() {
  test('one model run stays one assistant message with Markdown intact', () {
    const response = '''## 结论

- 第一项
- 第二项

```dart
print('ok');
```''';

    final messages = buildFinalAssistantMessages(
      content: response,
      conversationId: 7,
      timestamp: DateTime.utc(2026, 8, 9),
    );

    expect(messages, hasLength(1));
    expect(messages.single.content, response);
    expect(messages.single.role, 'assistant');
    expect(messages.single.conversationId, 7);
  });
}
