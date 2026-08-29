// Widget-level verification that LaTeX actually builds inside the chat bubble.
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/screens/markdown_message.dart';
import 'package:solvhen/theme/theme_provider.dart';

Widget _wrap(String data) {
  final colors = ThemeColors(ThemeNotifier());
  return MaterialApp(
    home: Scaffold(
      body: SolvhenMarkdownMessage(data: data, colors: colors),
    ),
  );
}

void main() {
  testWidgets('inline + block math build in the bubble', (tester) async {
    await tester.pumpWidget(_wrap('质能方程 \$E=mc^2\$，求根：\n\n\$\$x=\\frac{-b}{2a}\$\$'));
    await tester.pumpAndSettle();
    expect(find.byType(Math), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('prices stay plain text, no Math widget', (tester) async {
    await tester.pumpWidget(_wrap('价格是 \$5 和 \$10 两个档'));
    await tester.pumpAndSettle();
    expect(find.byType(Math), findsNothing);
    expect(find.textContaining('5'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('broken formula falls back to raw text', (tester) async {
    await tester.pumpWidget(_wrap(r'坏公式 $\frac{1}{$ 这里'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
