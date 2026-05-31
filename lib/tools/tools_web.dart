/// Web & learning tools — Solvhen searches, downloads skills, grows autonomously.
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'tool_registry.dart';

void registerWebTools() {
  final registry = ToolRegistry();
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 50),
  ));

  // ── Web Search ──
  registry.register(ToolEntry(
    name: 'web_search',
    toolset: 'web',
    schema: {
      'name': 'web_search',
      'description': '''搜索互联网获取信息。用于查找实时数据、学习新知识、验证事实。
返回搜索结果摘要。像Hermes一样，你可以用这个工具来扩展自己的知识。''',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '搜索关键词',
          },
        },
        'required': ['query'],
      },
    },
    handler: (args) async {
      final rawQuery = args['query'] as String;
      final query = Uri.encodeComponent(rawQuery);
      final engines = [
        _SearchEngine('Bing', 'https://www.bing.com/search?q=$query', _extractBingResults),
        _SearchEngine('百度', 'https://www.baidu.com/s?wd=$query', _extractBaiduResults),
        _SearchEngine('搜狗', 'https://www.sogou.com/web?query=$query', _extractSogouResults),
        // Google blocked in China without proxy — disabled
        // _SearchEngine('Google', 'https://www.google.com/search?q=$query&hl=zh-CN', _extractGoogleResults),
      ];

      // Parallel search — all engines fire at once, collect results as they arrive.
      final futures = engines.map((e) => _searchOne(e, dio));
      final results = await Future.wait(futures);

      // Log diagnostic info
      for (final r in results) {
        if (kDebugMode) {
          if (r.error != null) {
            debugPrint('[Solvhen:web] ${r.engine} ERROR: ${r.error!.substring(0, r.error!.length > 300 ? 300 : r.error!.length)}');
          } else {
            debugPrint('[Solvhen:web] ${r.engine}: ${r.results?.length ?? 0} results');
          }
        }
      }

      final allResults = <Map<String, String>>[];
      final errors = <String>[];
      for (final r in results) {
        if (r.error != null) {
          errors.add('${r.engine}: ${r.error}');
        } else if (r.results != null && r.results!.isNotEmpty) {
          allResults.addAll(r.results!);
        }
      }

      if (allResults.isNotEmpty) {
        return jsonEncode({
          'success': true,
          'query': rawQuery,
          'engines': results.where((r) => r.results != null && r.results!.isNotEmpty).map((r) => r.engine).toList(),
          'results': allResults,
          'count': allResults.length,
        });
      }
      return jsonEncode({'success': false, 'error': '所有搜索引擎均失败', 'details': errors});
    },
  ));

  // ── Save Skill / Learn ──
  registry.register(ToolEntry(
    name: 'save_skill',
    toolset: 'web',
    schema: {
      'name': 'save_skill',
      'description': '''保存你学到的新知识或技能为本地文件。
就像Hermes的技能系统一样——把你学到的东西写成可复用的知识。
保存后可以用 read_file 随时查阅。建议保存到 skills/ 目录。''',
      'parameters': {
        'type': 'object',
        'properties': {
          'name': {
            'type': 'string',
            'description': '技能/知识名称，用作文件名（如 math_shortcuts）',
          },
          'content': {
            'type': 'string',
            'description': '完整的技能内容，可以是文本、代码、prompt模板等',
          },
        },
        'required': ['name', 'content'],
      },
    },
    handler: (args) async {
      try {
        // Delegate to file tool via the singleton registry
        return await registry.dispatch('write_file', {
          'path': 'skills/${args['name']}.md',
          'content': args['content'],
        });
      } catch (e) {
        return jsonEncode({'success': false, 'error': e.toString()});
      }
    },
  ));

  // ── Fetch URL ──
  registry.register(ToolEntry(
    name: 'fetch_url',
    toolset: 'web',
    schema: {
      'name': 'fetch_url',
      'description': '获取网页内容。用于读取文档、API数据、学习资料。',
      'parameters': {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': '要获取的URL',
          },
        },
        'required': ['url'],
      },
    },
    handler: (args) async {
      final rawUrl = args['url'] as String;
      try {
        final uri = Uri.parse(rawUrl);
        // Validate scheme — only allow http/https
        if (uri.scheme != 'http' && uri.scheme != 'https') {
          return jsonEncode({
            'error': '不支持的URL协议: ${uri.scheme}。仅支持 http/https。',
          });
        }
        // Block internal/private IPs (SSRF protection)
        final host = uri.host.toLowerCase();
        if (host == 'localhost' ||
            host == '127.0.0.1' ||
            host == '0.0.0.0' ||
            host.startsWith('127.') ||
            host.startsWith('192.168.') ||
            host.startsWith('10.') ||
            host.startsWith('172.16.') ||
            host.startsWith('172.17.') ||
            host.startsWith('172.18.') ||
            host.startsWith('172.19.') ||
            host.startsWith('172.20.') ||
            host.startsWith('172.21.') ||
            host.startsWith('172.22.') ||
            host.startsWith('172.23.') ||
            host.startsWith('172.24.') ||
            host.startsWith('172.25.') ||
            host.startsWith('172.26.') ||
            host.startsWith('172.27.') ||
            host.startsWith('172.28.') ||
            host.startsWith('172.29.') ||
            host.startsWith('172.30.') ||
            host.startsWith('172.31.')) {
          return jsonEncode({
            'error': '禁止访问内部网络地址: $host',
          });
        }
        final resp = await dio.get(
          rawUrl,
          options: Options(
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
            },
            responseType: ResponseType.plain,
          ),
        );
        final text = resp.data.toString();
        // Truncate long responses
        final truncated =
            text.length > 8000 ? '${text.substring(0, 8000)}...' : text;
        return jsonEncode({
          'success': true,
          'url': rawUrl,
          'content': truncated,
          'length': text.length,
        });
      } catch (e) {
        return jsonEncode({'success': false, 'error': e.toString()});
      }
    },
  ));
}

// ── Search engine abstraction ──────────────────────────────

class _SearchEngine {
  final String name;
  final String url;
  final List<Map<String, String>> Function(String html) parse;
  const _SearchEngine(this.name, this.url, this.parse);
}

class _SearchResult {
  final String engine;
  final List<Map<String, String>>? results;
  final String? error;
  const _SearchResult({required this.engine, this.results, this.error});
}

Future<_SearchResult> _searchOne(_SearchEngine engine, Dio dio) async {
  try {
    final resp = await dio.get(
      engine.url,
      options: Options(
        headers: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
          'Accept-Language': 'zh-CN,zh;q=0.9',
        },
      ),
    );
    final html = resp.data as String;
    final results = engine.parse(html);
    // Diagnostic: include HTML snippet when parsing fails
    if (results.isEmpty) {
      final snippet = html.length > 500 ? '${html.substring(0, 500)}…' : html;
      return _SearchResult(engine: engine.name, results: results, error: '解析无结果。HTML: $snippet');
    }
    return _SearchResult(engine: engine.name, results: results);
  } catch (e) {
    return _SearchResult(
      engine: engine.name,
      error: e.toString().length > 80 ? '${e.toString().substring(0, 80)}…' : e.toString(),
    );
  }
}

/// Extract search result titles + snippets from Bing HTML
List<Map<String, String>> _extractBingResults(String html) {
  final results = <Map<String, String>>[];

  // Bing result blocks: <li class="b_algo">
  final blockRe = RegExp(
    r'<li class="b_algo"[^>]*>(.*?)</li>',
    dotAll: true,
  );
  final blocks = blockRe.allMatches(html);

  for (final b in blocks.take(10)) {
    final block = b.group(1)!;
    // Title: <h2><a href="...">Title</a></h2>
    final titleMatch = RegExp(r'<h2[^>]*>.*?<a[^>]*href="([^"]*)"[^>]*>([^<]*)<', dotAll: true).firstMatch(block);
    // Snippet: <p> or <div class="b_caption"><p>
    final snippetMatch = RegExp(r'<p[^>]*>([^<]{10,300})', dotAll: true).firstMatch(block);

    if (titleMatch != null) {
      results.add({
        'title': titleMatch.group(2)?.trim() ?? '',
        'url': titleMatch.group(1)?.trim() ?? '',
        'snippet': snippetMatch?.group(1)?.trim() ?? '',
      });
    }
  }

  if (results.isEmpty) {
    // Fallback: broader match
    final simpleRe = RegExp(
      r'<a[^>]*href="(https?://[^"]*)"[^>]*>([^<]{3,100})</a>',
      dotAll: true,
    );
    for (final m in simpleRe.allMatches(html).take(10)) {
      final url = m.group(1)!.trim();
      final title = m.group(2)!.trim();
      if (!url.contains('bing.com') && !url.contains('microsoft.com')) {
        results.add({'title': title, 'url': url, 'snippet': ''});
      }
    }
  }

  return results;
}

/// Extract search results from Baidu HTML
List<Map<String, String>> _extractBaiduResults(String html) {
  final results = <Map<String, String>>[];
  // Baidu result blocks: <div class="result c-container" ...>
  final blockRe = RegExp(r'<div[^>]*class="[^"]*result[^"]*c-container[^"]*"[^>]*>(.*?)</div>\s*</div>', dotAll: true);
  for (final b in blockRe.allMatches(html).take(10)) {
    final block = b.group(1)!;
    final titleMatch = RegExp(r'<a[^>]*href="([^"]*)"[^>]*>(.+?)</a>', dotAll: true).firstMatch(block);
    final snippetMatch = RegExp(r'<span[^>]*class="[^"]*content-right_[^"]*"[^>]*>(.*?)</span>', dotAll: true).firstMatch(block)
        ?? RegExp(r'<div[^>]*class="[^"]*c-abstract[^"]*"[^>]*>(.*?)</div>', dotAll: true).firstMatch(block);
    if (titleMatch != null) {
      results.add({
        'title': _stripTags(titleMatch.group(2) ?? ''),
        'url': titleMatch.group(1)?.trim() ?? '',
        'snippet': _stripTags(snippetMatch?.group(1) ?? ''),
      });
    }
  }
  return results;
}

/// Extract search results from Sogou HTML
List<Map<String, String>> _extractSogouResults(String html) {
  final results = <Map<String, String>>[];
  // Sogou result blocks: <div class="vrwrap"> or <div class="rb">
  final blockRe = RegExp(r'<div[^>]*class="(?:vrwrap|rb)"[^>]*>(.*?)</div>\s*</div>\s*</div>', dotAll: true);
  for (final b in blockRe.allMatches(html).take(10)) {
    final block = b.group(1)!;
    final titleMatch = RegExp(r'<a[^>]*href="([^"]*)"[^>]*>(.+?)</a>', dotAll: true).firstMatch(block);
    final snippetMatch = RegExp(r'<p[^>]*class="[^"]*(?:star-wiki|str_info|str-text)[^"]*"[^>]*>(.*?)</p>', dotAll: true).firstMatch(block)
        ?? RegExp(r'<div[^>]*class="[^"]*(?:space|ft|abstract)[^"]*"[^>]*>(.*?)</div>', dotAll: true).firstMatch(block);
    if (titleMatch != null) {
      results.add({
        'title': _stripTags(titleMatch.group(2) ?? ''),
        'url': titleMatch.group(1)?.trim() ?? '',
        'snippet': _stripTags(snippetMatch?.group(1) ?? ''),
      });
    }
  }
  return results;
}

/// Strip HTML tags from a string
String _stripTags(String html) {
  return html.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Extract search results from Google HTML
List<Map<String, String>> _extractGoogleResults(String html) {
  final results = <Map<String, String>>[];
  // Google result blocks: <div class="g"> or <div data-sokoban-container>
  final blockRe = RegExp(r'<div[^>]*class="[^"]*\bg\b[^"]*"[^>]*>(.*?)</div>\s*</div>\s*</div>', dotAll: true);
  for (final b in blockRe.allMatches(html).take(10)) {
    final block = b.group(1)!;
    final titleMatch = RegExp(r'<h3[^>]*>(.+?)</h3>', dotAll: true).firstMatch(block);
    final linkMatch = RegExp(r'<a[^>]*href="(/url\?q=)?(https?://[^"&]*)', dotAll: true).firstMatch(block);
    final snippetMatch = RegExp(r'<div[^>]*class="[^"]*\bVwiC3b\b[^"]*"[^>]*>(.*?)</div>', dotAll: true).firstMatch(block)
        ?? RegExp(r'<span[^>]*class="[^"]*\bst\b[^"]*"[^>]*>(.*?)</span>', dotAll: true).firstMatch(block);
    if (titleMatch != null) {
      var url = linkMatch?.group(2) ?? linkMatch?.group(1) ?? '';
      if (url.startsWith('/url?q=')) url = Uri.parse(url).queryParameters['q'] ?? url;
      results.add({
        'title': _stripTags(titleMatch.group(1) ?? ''),
        'url': url,
        'snippet': _stripTags(snippetMatch?.group(1) ?? ''),
      });
    }
  }
  return results;
}
