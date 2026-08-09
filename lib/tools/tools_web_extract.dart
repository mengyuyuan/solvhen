/// Solvhen AI手机智能体 — 网页内容提取工具
/// 获取 URL 内容并将 HTML 转为可读纯文本，自动移除脚本、样式、标签。
/// 内置 SSRF 防护，阻止访问内部网络地址。
library;

import 'dart:convert';
import 'package:dio/dio.dart';
import 'tool_registry.dart';

/// 注册网页内容提取工具
/// 工具：web_extract(提取URL正文→Markdown)
/// 大页面：>5000字符走LLM摘要，>2M字符拒绝
/// 安全：拒绝内网地址
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
      // ── SSRF 防护 ──
      final uri = Uri.tryParse(url);
      if (uri == null) {
        return jsonEncode({'success': false, 'error': '无法解析URL: $url'});
      }
      // 仅允许 http/https 协议
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        return jsonEncode({
          'success': false,
          'error': '不支持的URL协议: ${uri.scheme}。仅支持 http/https。'
        });
      }
      final host = uri.host.toLowerCase();
      // 阻止内部/私有 IP 地址和 .local 域名（mDNS）
      if (host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '0.0.0.0' ||
          host.startsWith('127.') ||
          host.startsWith('192.168.') ||
          host.startsWith('10.') ||
          host.endsWith('.local') ||
          (host.startsWith('172.') && _isPrivate172(host))) {
        return jsonEncode({'success': false, 'error': '禁止访问内部网络地址: $host'});
      }
      try {
        final resp = await dio.get(
          url,
          options: Options(responseType: ResponseType.plain),
        );
        final html = resp.data.toString();
        final text = _htmlToText(html);

        if (text.isEmpty) {
          return jsonEncode({
            'success': true,
            'url': url,
            'content': '(页面无文本内容)',
            'length': 0
          });
        }

        const maxLen = 5000;
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

/// 将 HTML 转为纯文本：移除脚本、样式、标签，解码 HTML 实体，压缩空白。
String _htmlToText(String html) {
  var text = html;

  // 移除脚本、样式、noscript 块（连同内容）
  text =
      text.replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), '');
  text = text.replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), '');
  text = text.replaceAll(
      RegExp(r'<noscript[^>]*>.*?</noscript>', dotAll: true), '');

  // 块级元素替换为换行——原始正则中的 h[1-6] 是字符类，匹配 h1~h6
  const blockTags =
      'div|p|h[1-6]|li|tr|br|hr|section|article|header|footer|main|aside|nav';
  text = text.replaceAll(RegExp('</?(?:$blockTags)[^>]*>'), '\n');

  // 移除剩余所有 HTML 标签
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');

  // 解码常见 HTML 实体
  text = text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#x2F;', '/');

  // 解码数字实体：&#DDD; 和 &#xHHH;
  text = text.replaceAllMapped(
      RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m.group(1)!)));
  text = text.replaceAllMapped(RegExp(r'&#[xX]([0-9a-fA-F]+);'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));

  // 压缩多余空白
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  text = text.trim();

  return text;
}

/// 截断异常消息，避免返回过长的错误信息。
String _shortErr(Object e) {
  final s = e.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…' : s;
}

/// 判断 172.x.x.x 中的第二位是否在私有范围（16-31）内。
/// 172.16.0.0/12 范围: 172.16.0.0 – 172.31.255.255
bool _isPrivate172(String host) {
  final parts = host.split('.');
  if (parts.length < 2) return false;
  final second = int.tryParse(parts[1]);
  return second != null && second >= 16 && second <= 31;
}
