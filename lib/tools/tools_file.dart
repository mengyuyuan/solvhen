/// File system tools — read, write, list files.
/// Pure Dart, uses path_provider for storage paths.
library;

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'tool_registry.dart';
import 'tool_utils.dart';

void registerFileTools() {
  final registry = ToolRegistry();

  registry.register(ToolEntry(
    name: 'write_file',
    toolset: 'file',
    schema: {
      'name': 'write_file',
      'description': '写入文件。用于保存笔记、记录、导出内容。路径相对于 Solvhen 的存储目录。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '文件路径，如 notes/日记.txt'},
          'content': {'type': 'string', 'description': '要写入的内容'},
        },
        'required': ['path', 'content'],
      },
    },
    handler: (args) async {
      try {
        final dir = await _storageDir();
        final file = File('${dir.path}/${_normalizePath(args['path'] as String, dir.path)}');
        await file.parent.create(recursive: true);
        await file.writeAsString(args['content'] as String);
        final size = await file.length();
        return jsonEncode({'success': true, 'path': file.path, 'size': size});
      } catch (e) {
        return jsonEncode({'error': e.toString()});
      }
    },
  ));

  registry.register(ToolEntry(
    name: 'read_file',
    toolset: 'file',
    schema: {
      'name': 'read_file',
      'description': '''读取文件内容，带行号。支持分页读取长文件。

用法：
  read_file({path:"notes.txt"})              → 读前200行，返回 total_lines
  read_file({path:"notes.txt", offset:201})  → 翻页读第201行起
  read_file({path:"notes.txt", limit:50})    → 只读50行

返回字段：content(带行号文本), total_lines(总行数), offset, chars(字符数)
二进制文件（PDF/xlsx/图片等）→ 只返回元数据，不返回内容
文件路径 solvhen_files/ 前缀可省略，会自动处理''',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '文件路径'},
          'offset': {'type': 'integer', 'description': '起始行号（1开始），默认1'},
          'limit': {'type': 'integer', 'description': '最多返回行数，默认200'},
        },
        'required': ['path'],
      },
    },
    handler: (args) async {
      try {
        final dir = await _storageDir();
        final file = File('${dir.path}/${_normalizePath(args['path'] as String, dir.path)}');
        if (!await file.exists()) {
          return jsonEncode({'error': '文件不存在: ${args['path']}'});
        }
        try {
          final content = await file.readAsString();
          final allLines = const LineSplitter().convert(content);
          final totalLines = allLines.length;
          final offset = clampInt(parseArgInt(args['offset'], 1), 1, totalLines);
          final limit = clampInt(parseArgInt(args['limit'], 200), 1, 500);

          final end = (offset + limit - 1).clamp(0, totalLines);
          final page = allLines.sublist(offset - 1, end);

          final buf = StringBuffer();
          for (var i = 0; i < page.length; i++) {
            buf.writeln('${offset + i}|${page[i]}');
          }

          return jsonEncode({
            'content': buf.toString().trimRight(),
            'path': file.path,
            'total_lines': totalLines,
            'offset': offset,
            'limit': limit,
            'chars': content.length,
          });
        } on FormatException {
          final size = await file.length();
          final ext = file.path.split('.').last;
          return jsonEncode({
            'note': '这是二进制文件（${_fmtSize(size)}），无法当文本读取。',
            'path': file.path,
            'extension': ext,
            'size': size,
            'size_human': _fmtSize(size),
          });
        }
      } catch (e) {
        return jsonEncode({'error': e.toString()});
      }
    },
  ));

  registry.register(ToolEntry(
    name: 'list_files',
    toolset: 'file',
    schema: {
      'name': 'list_files',
      'description': '列出 Solvhen 保存的所有文件。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '子目录，留空则列出根目录'},
        },
        'required': [],
      },
    },
    handler: (args) async {
      try {
        final dir = await _storageDir();
        final subPath = args['path'] as String? ?? '';
        final normalized = _normalizePath(subPath, dir.path);
        final target = Directory('${dir.path}/$normalized');
        if (!await target.exists()) {
          return jsonEncode({'files': []});
        }
        final files = <Map<String, dynamic>>[];
        await for (final entity in target.list()) {
          if (entity is File) {
            files.add({
              'name': entity.uri.pathSegments.last,
              'path': entity.path.replaceFirst(dir.path, ''),
              'size': await entity.length(),
              'modified': (await entity.lastModified()).toIso8601String(),
            });
          }
        }
        return jsonEncode({'files': files, 'count': files.length});
      } catch (e) {
        return jsonEncode({'error': e.toString()});
      }
    },
  ));

  // ═══════════════════════════════════════
  // browse_files — 浏览手机任意文件夹
  // ═══════════════════════════════════════
  registry.register(ToolEntry(
    name: 'browse_files',
    toolset: 'file',
    schema: {
      'name': 'browse_files',
      'description': '浏览手机上的任意文件夹。可查看 Download、DCIM、Documents 等。'
          '\n常用路径: /sdcard/ (内部存储根), /sdcard/Download/, /sdcard/DCIM/, '
          '/sdcard/Documents/, /sdcard/Pictures/, /sdcard/Music/。'
          '\ndepth: 0=仅当前目录(默认), 1=包含一级子目录。'
          '\n首次使用可能需要授予存储权限。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '绝对路径，如 /sdcard/Download/'},
          'depth': {
            'type': 'integer',
            'description': '递归深度（0=仅当前目录，1=含一级子目录，最大1）。默认0。',
          },
        },
        'required': ['path'],
      },
    },
    handler: (args) async {
      try {
        final rawPath = args['path'] as String;
        // Path traversal protection — only allow safe system directories
        if (rawPath.contains('..')) {
          return jsonEncode({'error': '不允许的路径: 路径中不能包含 ..', 'hint': '试试 /sdcard/ 开头的路径'});
        }
        // Whitelist known-safe Android paths
        const allowedPrefixes = ['/sdcard/', '/storage/emulated/', '/mnt/sdcard/'];
        final isAllowed = allowedPrefixes.any((p) => rawPath.startsWith(p));
        if (!isAllowed) {
          return jsonEncode({'error': '不允许访问此路径。仅支持 /sdcard/ 和 /storage/ 下的目录。',
            'hint': '试试 /sdcard/Download/ 或 /sdcard/DCIM/'});
        }
        final depth = ((args['depth'] as int?) ?? 0).clamp(0, 1);
        final dir = Directory(rawPath);
        if (!await dir.exists()) {
          // Try common alternative prefixes
          if (rawPath.startsWith('/storage/emulated/0/')) {
            final altPath = rawPath.replaceFirst('/storage/emulated/0/', '/sdcard/');
            final altDir = Directory(altPath);
            if (await altDir.exists()) {
              final result = await _browseDir(altDir, depth);
              result['path'] = altPath;
              result['requested'] = rawPath;
              return jsonEncode(result);
            }
          }
          return jsonEncode({'error': '文件夹不存在: $rawPath', 'hint': '试试 /sdcard/ 开头的路径'});
        }
        final result = await _browseDir(dir, depth);
        result['path'] = rawPath;
        return jsonEncode(result);
      } on FileSystemException catch (e) {
        return jsonEncode({
          'error': '权限不足: ${e.message}',
          'hint': '请在 系统设置→应用→Solvhen→权限 中授予"所有文件访问权限"',
        });
      } catch (e) {
        return jsonEncode({'error': e.toString()});
      }
    },
  ));

  registry.register(ToolEntry(
    name: 'delete_file',
    toolset: 'file',
    schema: {
      'name': 'delete_file',
      'description': '删除文件。慎用。',
      'parameters': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string', 'description': '要删除的文件路径'},
        },
        'required': ['path'],
      },
    },
    handler: (args) async {
      try {
        final dir = await _storageDir();
        final file = File('${dir.path}/${_normalizePath(args['path'] as String, dir.path)}');
        if (await file.exists()) {
          await file.delete();
          return jsonEncode({'success': true, 'path': file.path});
        }
        return jsonEncode({'error': '文件不存在: ${args['path']}'});
      } catch (e) {
        return jsonEncode({'error': e.toString()});
      }
    },
  ));
}

/// Strip storage dir prefix from absolute paths so the AI can safely use
/// any path (relative or absolute from a previous tool result).
String _normalizePath(String rawPath, String storageDir) {
  if (rawPath.startsWith(storageDir)) {
    var rel = rawPath.substring(storageDir.length);
    if (rel.startsWith('/')) rel = rel.substring(1);
    return rel.isEmpty ? '.' : rel;
  }
  // Strip solvhen_files/ prefix if present (tools already prepend storage dir)
  if (rawPath.startsWith('solvhen_files/')) {
    return rawPath.substring('solvhen_files/'.length);
  }
  // If it looks like an absolute Android path but not ours,
  // extract just the filename to avoid double-prepending.
  if (rawPath.startsWith('/')) {
    return rawPath.split('/').last;
  }
  // Reject path traversal attempts — throw with clear message
  if (rawPath.contains('..')) {
    throw FormatException('不允许路径遍历: $rawPath');
  }
  return rawPath;
}

/// Browse a directory and return its contents as a tree.
Future<Map<String, dynamic>> _browseDir(Directory dir, int depth) async {
  final items = <Map<String, dynamic>>[];
  try {
    final entities = await dir.list().toList();
    // Sort: directories first, then files, both alphabetically
    entities.sort((a, b) {
      final aIsDir = a is Directory;
      final bIsDir = b is Directory;
      if (aIsDir && !bIsDir) return -1;
      if (!aIsDir && bIsDir) return 1;
      return a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last);
    });

    for (final entity in entities) {
      final name = entity.uri.pathSegments.last;
      if (entity is Directory) {
        final item = <String, dynamic>{
          'name': name,
          'type': 'directory',
          'path': entity.path,
        };
        if (depth > 0) {
          try {
            final sub = await _browseDir(entity, depth - 1);
            item['children'] = sub['items'];
          } on FileSystemException {
            item['children'] = [];
            item['error'] = '权限不足';
          } catch (_) {
            item['children'] = [];
          }
        }
        items.add(item);
      } else if (entity is File) {
        items.add({
          'name': name,
          'type': 'file',
          'path': entity.path,
          'size': await entity.length(),
          'size_human': _fmtSize(await entity.length()),
          'modified': (await entity.lastModified()).toIso8601String(),
        });
      }
    }
  } on FileSystemException {
    // Permission denied — rethrow so the handler can give a nice message
    rethrow;
  }
  return {'items': items, 'count': items.length};
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

Future<Directory> _storageDir() async {
  final appDir = await getApplicationDocumentsDirectory();
  final solvhenDir = Directory('${appDir.path}/solvhen_files');
  if (!await solvhenDir.exists()) {
    await solvhenDir.create(recursive: true);
  }
  return solvhenDir;
}
