import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/services/tool_executor.dart';

void main() {
  group('ToolExecutor XML/DSML parsing and stripping', () {
    test('parses standard XML invoke blocks from content', () {
      const content = '<invoke name="web_search"><parameter name="query">Solvhen</parameter></invoke>';
      final calls = ToolExecutor.parseToolCallsFromContent(content);

      expect(calls, isNotNull);
      expect(calls, hasLength(1));
      expect(calls!.first.name, 'web_search');
      expect(jsonDecode(calls.first.arguments), {'query': 'Solvhen'});
    });

    test('parses DSML invoke blocks from content', () {
      const content = '<|DSML|invoke name="open_app"><|DSML|parameter name="app">微信</|DSML|parameter></|DSML|invoke>';
      final calls = ToolExecutor.parseToolCallsFromContent(content);

      expect(calls, isNotNull);
      expect(calls, hasLength(1));
      expect(calls!.first.name, 'open_app');
      expect(jsonDecode(calls.first.arguments), {'app': '微信'});
    });

    test('strips standard XML, DSML, HTML/CSS code fences, and tool narration', () {
      const content = '''我先处理。
<invoke name="web_search"><parameter name="query">x</parameter></invoke>
<|DSML|invoke name="open_app"><|DSML|parameter name="app">微信</|DSML|parameter></|DSML|invoke>
（调用 web_search 工具）
```html
<div>leak</div>
```
```css
body{color:red}
```
结果在这里。''';

      final cleaned = ToolExecutor.stripToolCallsFromContent(content);

      expect(cleaned, contains('我先处理。'));
      expect(cleaned, contains('结果在这里。'));
      expect(cleaned, isNot(contains('<invoke')));
      expect(cleaned, isNot(contains('parameter')));
      expect(cleaned, isNot(contains('DSML')));
      expect(cleaned, isNot(contains('```html')));
      expect(cleaned, isNot(contains('```css')));
      expect(cleaned, isNot(contains('调用 web_search')));
    });
  });
}
