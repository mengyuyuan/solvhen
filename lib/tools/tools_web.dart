/// Solvhen AI手机智能体 — 网页搜索与学习工具集
/// 提供多引擎并行搜索（Bing/百度/搜狗）、技能保存、URL 获取功能。
/// 使用 Dio HTTP 客户端，内置 SSRF 防护。
library;

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'tool_registry.dart';

/// 注册网页搜索工具集
/// 工具：web_search(多引擎搜索)/fetch_url(获取网页内容)
/// 搜索引擎回退链：DuckDuckGo → Bing → Google
/// 支持内网地址检测（172.x/192.168/10.x/127.x → 拒绝请求）
void registerWebTools() {
  final registry = ToolRegistry();
  // 单例 Dio 实例，20秒连接超时 + 50秒读取超时
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 50),
  ));

  // ── web_search — 多引擎并行搜索 ──
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
      // 三个搜索引擎并行请求，不互相阻塞
      // Google 在国内被屏蔽且无代理时不可用，已禁用
      final engines = [
        _SearchEngine('Bing', 'https://www.bing.com/search?q=$query', _extractBingResults),
        _SearchEngine('百度', 'https://www.baidu.com/s?wd=$query', _extractBaiduResults),
        _SearchEngine('搜狗', 'https://www.sogou.com/web?query=$query', _extractSogouResults),
      ];

      // 并行触发所有搜索引擎，Future.wait 等待全部完成（或失败）
      final futures = engines.map((e) => _searchOne(e, dio));
      final results = await Future.wait(futures);

      // Debug 模式下打印诊断信息
      for (final r in results) {
        if (kDebugMode) {
          if (r.error != null) {
            debugPrint('[Solvhen:web] ${r.engine} ERROR: ${r.error!.substring(0, r.error!.length > 300 ? 300 : r.error!.length)}');
          } else {
            debugPrint('[Solvhen:web] ${r.engine}: ${r.results?.length ?? 0} results');
          }
        }
      }

      // 收集所有成功引擎的结果
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

  // ── save_skill — 保存技能/知识到本地文件 ──
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
        // 委托给 write_file 工具——避免代码重复，利用已有的文件系统工具
        return await registry.dispatch('write_file', {
          'path': 'skills/${args['name']}.md',
          'content': args['content'],
        });
      } catch (e) {
        return jsonEncode({'success': false, 'error': e.toString()});
      }
    },
  ));

  // ── fetch_url — 获取网页原始内容 ──
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
        // ── SSRF 防护：阻止访问内部网络 ──
        final uri = Uri.parse(rawUrl);
        // 只允许 http/https 协议
        if (uri.scheme != 'http' && uri.scheme != 'https') {
          return jsonEncode({
            'error': '不支持的URL协议: ${uri.scheme}。仅支持 http/https。',
          });
        }
        // 阻止内部/私有 IP 地址访问
        final host = uri.host.toLowerCase();
        if (host == 'localhost' ||
            host == '127.0.0.1' ||
            host == '0.0.0.0' ||
            host.startsWith('127.') ||
            host.startsWith('192.168.') ||
            host.startsWith('10.') ||
            (host.startsWith('172.') && _isPrivate172(host))) {
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
        // 截断超长响应，保留前8000字符
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

// ── 搜索引擎抽象层 ──────────────────────────────

/// 单个搜索引擎定义：名称、URL模板、HTML解析函数。
class _SearchEngine {
  final String name;
  final String url;
  final List<Map<String, String>> Function(String html) parse;
  const _SearchEngine(this.name, this.url, this.parse);
}

/// 单个搜索引擎的搜索结果。
class _SearchResult {
  final String engine;
  final List<Map<String, String>>? results; // null 表示出错
  final String? error;
  const _SearchResult({required this.engine, this.results, this.error});
}

/// 对单个搜索引擎发起 HTTP 请求并解析结果。
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
    // 诊断：解析无结果时附带 HTML 片段用于调试
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

/// 从 Bing HTML 中提取搜索结果（标题 + URL + 摘要）。
List<Map<String, String>> _extractBingResults(String html) {
  final results = <Map<String, String>>[];
  // Bing 搜索结果块：<li class="b_algo">
  final blockRe = RegExp(
    r'<li class="b_algo"[^>]*>(.*?)</li>',
    dotAll: true,
  );
  final blocks = blockRe.allMatches(html);

  for (final b in blocks.take(10)) {
    final block = b.group(1)!;
    // 标题和链接：<h2><a href="...">Title</a></h2>
    final titleMatch = RegExp(r'<h2[^>]*>.*?<a[^>]*href="([^"]*)"[^>]*>([^<]*)<', dotAll: true).firstMatch(block);
    // 摘要：<p> 标签内容（10-300字符，过滤太短的）
    final snippetMatch = RegExp(r'<p[^>]*>([^<]{10,300})', dotAll: true).firstMatch(block);

    if (titleMatch != null) {
      results.add({
        'title': titleMatch.group(2)?.trim() ?? '',
        'url': titleMatch.group(1)?.trim() ?? '',
        'snippet': snippetMatch?.group(1)?.trim() ?? '',
      });
    }
  }

  // 回退策略：更宽泛的链接提取
  if (results.isEmpty) {
    final simpleRe = RegExp(
      r'<a[^>]*href="(https?://[^"]*)"[^>]*>([^<]{3,100})</a>',
      dotAll: true,
    );
    for (final m in simpleRe.allMatches(html).take(10)) {
      final url = m.group(1)!.trim();
      final title = m.group(2)!.trim();
      // 过滤掉 Bing 和 Microsoft 自身的链接
      if (!url.contains('bing.com') && !url.contains('microsoft.com')) {
        results.add({'title': title, 'url': url, 'snippet': ''});
      }
    }
  }

  return results;
}

/// 从百度 HTML 中提取搜索结果。
List<Map<String, String>> _extractBaiduResults(String html) {
  final results = <Map<String, String>>[];
  // 百度结果块：<div class="result c-container" ...>
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

/// 从搜狗 HTML 中提取搜索结果。
List<Map<String, String>> _extractSogouResults(String html) {
  final results = <Map<String, String>>[];
  // 搜狗结果块：<div class="vrwrap"> 或 <div class="rb">
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

/// 去除字符串中的 HTML 标签并压缩空白。
String _stripTags(String html) {
  return html.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
}


/// 判断 172.x.x.x 中的 x 是否属于私有范围（16-31）。
/// 私有 172.16.0.0/12 范围: 172.16.0.0 – 172.31.255.255
bool _isPrivate172(String host) {
  final parts = host.split('.');
  if (parts.length < 2) return false;
  final second = int.tryParse(parts[1]);
  return second != null && second >= 16 && second <= 31;
}
