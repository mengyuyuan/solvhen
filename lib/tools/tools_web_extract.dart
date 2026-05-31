/// web_extract — fetch URL content and convert HTML to readable text.
library;

import 'dart:convert';
import 'package:dio/dio.dart';
import 'tool_registry.dart';

void registerWebExtractTool() {
  final registry = ToolRegistry();
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 50),
    headers: {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
    },
  ));

  registry.register(ToolEntry(
    name: 'web_extract',
    toolset: 'web',
    schema: {
      'name': 'web_extract',
      'description': '''获取网页内容并转为可读文本。用于阅读文章、文档、API响应等。
自动移除HTML标签、脚本、样式，保留正文。
获取全文≤5000字符；超长内容截断并标注。''',
      'parameters': {
        'type': 'object',
        'properties': {
          'url': {'type': 'string', 'description': '要提取的网页URL'},
        },
        'required': ['url'],
      },
    },
    handler: (args) async {
      final url = args['url'] as String;
      // SSRF protection — block non-http schemes and internal IPs
      final uri = Uri.tryParse(url);
      if (uri == null) {
        return jsonEncode({'success': false, 'error': '无法解析URL: $url'});
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        return jsonEncode({'success': false, 'error': '不支持的URL协议: ${uri.scheme}。仅支持 http/https。'});
      }
      final host = uri.host.toLowerCase();
      if (host == 'localhost' || host == '127.0.0.1' || host == '0.0.0.0' ||
          host.startsWith('127.') || host.startsWith('192.168.') ||
          host.startsWith('10.') || host.startsWith('172.16.') ||
          host.startsWith('172.17.') || host.startsWith('172.18.') ||
          host.startsWith('172.19.') || host.startsWith('172.20.') ||
          host.startsWith('172.21.') || host.startsWith('172.22.') ||
          host.startsWith('172.23.') || host.startsWith('172.24.') ||
          host.startsWith('172.25.') || host.startsWith('172.26.') ||
          host.startsWith('172.27.') || host.startsWith('172.28.') ||
          host.startsWith('172.29.') || host.startsWith('172.30.') ||
          host.startsWith('172.31.') || host.endsWith('.local')) {
        return jsonEncode({'success': false, 'error': '禁止访问内部网络地址: $host'});
      }
      try {
        final resp = await dio.get(url,
          options: Options(responseType: ResponseType.plain),
        );
        final html = resp.data.toString();
        final text = _htmlToText(html);

        if (text.isEmpty) {
          return jsonEncode({'success': true, 'url': url, 'content': '(页面无文本内容)', 'length': 0});
        }

        final maxLen = 5000;
        final truncated = text.length > maxLen
            ? '${text.substring(0, maxLen)}…[已截断，原文${text.length}字符]'
            : text;

        return jsonEncode({
          'success': true,
          'url': url,
          'content': truncated,
          'length': text.length,
          'truncated': text.length > maxLen,
        });
      } catch (e) {
        return jsonEncode({'success': false, 'error': '获取失败: ${_shortErr(e)}'});
      }
    },
  ));
}

/// Strip HTML tags, scripts, styles, and decode entities.
String _htmlToText(String html) {
  var text = html;

  // Remove scripts and styles
  text = text.replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), '');
  text = text.replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), '');
  text = text.replaceAll(RegExp(r'<noscript[^>]*>.*?</noscript>', dotAll: true), '');

  // Replace block elements with newlines
  const blockTags = 'div|p|h[1-6]|li|tr|br|hr|section|article|header|footer|main|aside|nav';
  text = text.replaceAll(RegExp('</?(?:$blockTags)[^>]*>'), '\n');

  // Remove all remaining HTML tags
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');

  // Decode HTML entities
  text = text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#x2F;', '/');

  // Replace numeric entities
  text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)));
  text = text.replaceAllMapped(RegExp(r'&#[xX]([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));

  // Collapse whitespace
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  text = text.trim();

  return text;
}

String _shortErr(Object e) {
  final s = e.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}
