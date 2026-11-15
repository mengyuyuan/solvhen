// Smoke test for the math markdown parsing layer (pure Dart, no Flutter).
// Run: dart run tool/math_parse_smoke.dart
// ignore_for_file: avoid_print
import 'package:markdown/markdown.dart' as md;

import 'package:solvhen/screens/markdown_math_syntax.dart';

void main() {
  final doc = md.Document(
    blockSyntaxes: const [MathBlockSyntax()],
    inlineSyntaxes: [DisplayMathInlineSyntax(), MathInlineSyntax()],
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );

  int failures = 0;
  void check(String name, String input, bool Function(List<md.Node>) expect) {
    final nodes = doc.parseLines(input.split('\n'));
    final ok = expect(nodes);
    if (!ok) failures++;
    print('${ok ? "PASS" : "FAIL"}  $name');
    if (!ok) print('      nodes: ${nodes.map((n) => '${n.runtimeType}').toList()}');
  }

  bool hasInlineMath(List<md.Node> nodes, String tex) {
    bool found = false;
    void walk(md.Node n) {
      if (n is md.Element && n.tag == 'math-inline' && n.textContent.trim() == tex) {
        found = true;
      }
      if (n is md.Element) n.children?.forEach(walk);
    }
    nodes.forEach(walk);
    return found;
  }

  bool hasDisplayInlineMath(List<md.Node> nodes, String tex) {
    bool found = false;
    void walk(md.Node n) {
      if (n is md.Element && n.tag == 'math-inline-display' && n.textContent.trim() == tex) {
        found = true;
      }
      if (n is md.Element) n.children?.forEach(walk);
    }
    nodes.forEach(walk);
    return found;
  }

  bool hasBlockMath(List<md.Node> nodes, String texContains) => nodes.any(
        (n) => n is md.Element && n.tag == 'math-block' && n.textContent.contains(texContains),
      );

  // 1. inline formula in a sentence
  check('inline \$E=mc^2\$', r'质能方程是 $E=mc^2$ 没错', (n) => hasInlineMath(n, r'E=mc^2'));

  // 2. inline with underscore/asterisk inside — emphasis must NOT split it
  check('inline a_b * c', r'公式 $a_b * c$ 结束', (n) => hasInlineMath(n, r'a_b * c'));

  // 3. price pair must stay plain text
  check('prices untouched', '价格是 \$5 和 \$10 两个档', (n) => !hasInlineMath(n, '5 和'));

  // 4. inline \$\$x\$\$ in prose (not line-start) → treated as inline x
  check('inline \$\$x\$\$ in prose', r'试试 $$x$$ 这里', (n) => hasDisplayInlineMath(n, 'x'));

  // 5. code span protected
  check('code span protected', '代码 `\$x\$` 不渲染', (n) => !hasInlineMath(n, 'x'));

  // 6. single-line block
  check('single-line block', r'$$x^2 + y^2 = z^2$$', (n) => hasBlockMath(n, 'x^2'));

  // 7. multi-line block
  check('multi-line block', '\$\$\n\\frac{a}{b}\n\$\$', (n) => hasBlockMath(n, 'frac'));

  // 8. fenced code block protected
  check('fenced code protected', '```\necho \$\$\n```', (n) => !hasBlockMath(n, 'echo'));

  // 9. block followed by paragraph
  check('block then paragraph', '\$\$x^2\$\$\n\n下一段文字', (n) {
    final hasP = nodesText(n).contains('下一段文字');
    return hasBlockMath(n, 'x^2') && hasP;
  });

  print(failures == 0 ? '\nALL PASS' : '\n$failures FAILURES');
}

String nodesText(List<md.Node> nodes) {
  final b = StringBuffer();
  void walk(md.Node n) {
    b.write(n.textContent);
    if (n is md.Element) n.children?.forEach(walk);
  }
  nodes.forEach(walk);
  return b.toString();
}
