import 'package:markdown/markdown.dart' as md;

/// `$$...$$` display-math block. Matches a line starting with `$$`, supports
/// both single-line (`$$x$$`) and multi-line (`$$` ... `$$`) forms. Registered
/// ahead of the standard block syntaxes so paragraphs never swallow it; fenced
/// code blocks open with backticks, so their contents stay untouched.
class MathBlockSyntax extends md.BlockSyntax {
  const MathBlockSyntax();

  static final RegExp _singleLine = RegExp(r'^\s*\$\$(.+?)\$\$\s*$');
  static final RegExp _begin = RegExp(r'^\s*\$\$(.*)$');
  static final RegExp _end = RegExp(r'^(.*?)\$\$\s*$');

  @override
  RegExp get pattern => _begin;

  @override
  bool canEndBlock(md.BlockParser parser) => false;

  @override
  md.Node? parse(md.BlockParser parser) {
    final String first = parser.current.content;
    final Match? single = _singleLine.firstMatch(first);
    if (single != null) {
      parser.advance();
      return md.Element.text('math-block', single.group(1)!.trim());
    }
    final Match? begin = _begin.firstMatch(first);
    if (begin == null) return null;
    final StringBuffer buffer = StringBuffer(begin.group(1)!);
    parser.advance();
    while (!parser.isDone) {
      final String line = parser.current.content;
      final Match? end = _end.firstMatch(line);
      if (end != null) {
        buffer.write('\n');
        buffer.write(end.group(1)!);
        parser.advance();
        break;
      }
      buffer.write('\n');
      buffer.write(line);
      parser.advance();
    }
    return md.Element.text('math-block', buffer.toString().trim());
  }

  @override
  List<md.Line?> parseChildLines(md.BlockParser parser) => const <md.Line>[];
}

/// `$$...$$` used inline in prose (not at line start, so the block syntax
/// never sees it). Rendered with display style but stays inside the paragraph.
/// Must be registered before [MathInlineSyntax] so the longer delimiter wins.
class DisplayMathInlineSyntax extends md.InlineSyntax {
  DisplayMathInlineSyntax() : super(r'\$\$([^$\n]+?)\$\$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final String content = match.group(1)!.trim();
    if (content.isEmpty) return false;
    parser.addNode(md.Element.text('math-inline-display', content));
    return true;
  }
}

/// `$...$` inline math. Guards: no `$$` pairs (those belong to blocks), no
/// whitespace right inside the delimiters, and the closing `$` must not be
/// followed by another `$` or a digit — keeps prices like "$5 和 $10" as text.
class MathInlineSyntax extends md.InlineSyntax {
  MathInlineSyntax() : super(r'\$(?!\$)(?!\s)([^$\n]+?)(?<!\s)\$(?!\$|\d)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final String content = match.group(1)!.trim();
    if (content.isEmpty) return false;
    parser.addNode(md.Element.text('math-inline', content));
    return true;
  }
}
