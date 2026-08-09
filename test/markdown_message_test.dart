import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/screens/markdown_message.dart';
import 'package:solvhen/theme/theme_provider.dart';

void main() {
  testWidgets('assistant Markdown renders formatting without raw markers',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SolvhenMarkdownMessage(
            data: '**国际**\n\n- 第一项\n- 第二项',
            colors: ThemeColors(ThemeNotifier()),
          ),
        ),
      ),
    );

    expect(find.text('**国际**', findRichText: true), findsNothing);
    expect(find.text('国际', findRichText: true), findsOneWidget);
    expect(find.text('第一项', findRichText: true), findsOneWidget);
  });

  testWidgets('remote Markdown images never load automatically',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SolvhenMarkdownMessage(
            data: '![示意图](https://example.com/tracker.png)',
            colors: ThemeColors(ThemeNotifier()),
          ),
        ),
      ),
    );

    expect(find.text('示意图'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
