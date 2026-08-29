import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme/theme_provider.dart';
import 'markdown_math_syntax.dart';

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
    final bool display = isBlock || element.tag == 'math-inline-display';
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
      mathStyle: display ? MathStyle.display : MathStyle.text,
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
      inlineSyntaxes: <md.InlineSyntax>[DisplayMathInlineSyntax(), MathInlineSyntax()],
      builders: <String, MarkdownElementBuilder>{
        'math-block': _MathBuilder(colors: colors),
        'math-inline': _InlineMathBuilder(colors: colors),
        'math-inline-display': _InlineMathBuilder(colors: colors),
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
