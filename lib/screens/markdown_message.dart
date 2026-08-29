import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme/theme_provider.dart';

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

/// Renders parsed math elements through flutter_math_fork, themed with the
/// current palette. Falls back to the raw `$`-delimited source on parse errors
/// so a broken formula never crashes the bubble.
class _MathBuilder extends MarkdownElementBuilder {
  _MathBuilder({required this.colors});

  final ThemeColors colors;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final String tex = element.textContent.trim();
    final bool isBlock = element.tag == 'math-block';
    final String raw = isBlock ? '\$\$$tex\$\$' : '\$$tex\$';
    final TextStyle base = (preferredStyle ?? const TextStyle()).copyWith(
      color: colors.textPrimary,
      height: 1.55,
    );
    if (tex.isEmpty) {
      return Text(raw, style: base);
    }
    final Widget math = Math.tex(
      tex,
      mathStyle: isBlock ? MathStyle.display : MathStyle.text,
      textStyle: base,
      onErrorFallback: (_) => Text(raw, style: base),
    );
    if (!isBlock) return math;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SizedBox(
        width: double.infinity,
        child: Center(child: math),
      ),
    );
  }
}

class _InlineMathBuilder extends _MathBuilder {
  _InlineMathBuilder({required super.colors});

  @override
  bool isBlockElement() => false;
}

/// Rich assistant text that stays inside Solvhen's dot-tech visual language.
///
/// Remote Markdown images are deliberately represented as placeholders. Merely
/// displaying an assistant response must never contact an external image host.
class SolvhenMarkdownMessage extends StatelessWidget {
  const SolvhenMarkdownMessage({
    super.key,
    required this.data,
    required this.colors,
    this.onOpenLink,
  });

  final String data;
  final ThemeColors colors;
  final Future<void> Function(Uri uri)? onOpenLink;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: 15,
      color: colors.textPrimary,
      height: 1.55,
    );
    final heading = base.copyWith(
      color: colors.navy,
      fontWeight: FontWeight.w800,
      height: 1.35,
    );

    return MarkdownBody(
      data: data,
      selectable: false,
      softLineBreak: true,
      blockSyntaxes: const <md.BlockSyntax>[MathBlockSyntax()],
      inlineSyntaxes: <md.InlineSyntax>[MathInlineSyntax()],
      builders: <String, MarkdownElementBuilder>{
        'math-block': _MathBuilder(colors: colors),
        'math-inline': _InlineMathBuilder(colors: colors),
      },
      onTapLink: (_, href, __) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
          return;
        }
        final callback = onOpenLink;
        if (callback != null) unawaited(callback(uri));
      },
      imageBuilder: (uri, title, alt) => Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: colors.accentFaint,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: colors.accent.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_outlined, size: 16, color: colors.accent),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                (alt?.trim().isNotEmpty ?? false) ? alt!.trim() : '外部图片未自动加载',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
      styleSheet: MarkdownStyleSheet(
        p: base,
        a: base.copyWith(
          color: colors.accent,
          decoration: TextDecoration.underline,
          decorationColor: colors.accent.withValues(alpha: 0.45),
        ),
        strong: base.copyWith(
          color: colors.navy,
          fontWeight: FontWeight.w800,
        ),
        em: base.copyWith(fontStyle: FontStyle.italic),
        del: base.copyWith(
          color: colors.textTertiary,
          decoration: TextDecoration.lineThrough,
        ),
        h1: heading.copyWith(fontSize: 21),
        h2: heading.copyWith(fontSize: 19),
        h3: heading.copyWith(fontSize: 17),
        h4: heading.copyWith(fontSize: 16),
        h5: heading.copyWith(fontSize: 15),
        h6: heading.copyWith(fontSize: 14, color: colors.textSecondary),
        listBullet: base.copyWith(
          color: colors.accent,
          fontWeight: FontWeight.w800,
        ),
        blockSpacing: 8,
        listIndent: 22,
        blockquote: base.copyWith(color: colors.textSecondary),
        blockquotePadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        blockquoteDecoration: BoxDecoration(
          color: colors.accentFaint,
          border: Border(left: BorderSide(color: colors.accent, width: 3)),
        ),
        code: TextStyle(
          fontSize: 13,
          height: 1.45,
          fontFamily: 'monospace',
          color: colors.navy,
          backgroundColor: colors.bgRoot,
        ),
        codeblockPadding: const EdgeInsets.all(11),
        codeblockDecoration: BoxDecoration(
          color: colors.bgRoot,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: colors.separator),
        ),
        tableHead: base.copyWith(
          color: colors.navy,
          fontWeight: FontWeight.w800,
        ),
        tableBody: base.copyWith(fontSize: 13),
        tableBorder: TableBorder.all(color: colors.separator, width: 0.8),
        tableCellsPadding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.separator)),
        ),
      ),
    );
  }
}
