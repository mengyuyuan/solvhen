/// Solvhen AI手机智能体 — 文件系统工具集
/// 提供文件读写、列表、浏览（含手机/sdcard目录）、删除功能。
/// 纯 Dart 实现，使用 path_provider 获取存储路径，内置路径遍历防护。
library;

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'tool_registry.dart';
import 'tool_utils.dart';

/// 注册文件操作工具集
/// 工具：read_file(读取)/write_file(写入)/list_files(列表)/
///       delete_file(删除)/search_files(搜索)
/// ⚠️ 安全：路径限制在存储目录内（sandbox模式）/ 读取限500行
void registerFileTools() {
  final registry = ToolRegistry();

  // ── write_file — 写入文件 ──
  registry.register(ToolEntry(
    name: 'write_file',
    toolset: 'file',
    schema: {
      'name': 'write_file',
      'description': '创建文件。写入的内容会保存为真实文件，不会出现在聊天中。用于保存笔记、代码、导出数据等。路径如 files/笔记.txt 或 /storage/emulated/0/Download/报告.md。父目录自动创建。',
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

  // ── read_file — 读取文件（带行号、支持分页）──
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
          // offset/limit 安全取值：确保在有效范围内
          final offset = clampInt(parseArgInt(args['offset'], 1), 1, totalLines);
          final limit = clampInt(parseArgInt(args['limit'], 200), 1, 500);
          // 注意：空文件 totalLines=0 时 allLines 包含一个空串 ['']，故 totalLines=1
          // 这是 LineSplitter 的行为——非空字符串分割至少有一行

          final end = (offset + limit - 1).clamp(0, totalLines);
          final page = allLines.sublist(offset - 1, end);

          // 构建带行号的输出
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
          // readAsString 抛出 FormatException 时说明是二进制文件
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

  // ── list_files — 列出 Solvhen 存储目录中的文件 ──
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
  // 支持浏览 /sdcard/、/storage/ 下的文件，带递归深度控制
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
        // 路径遍历防护：拒绝含 .. 的路径
        if (rawPath.contains('..')) {
          return jsonEncode({'error': '不允许的路径: 路径中不能包含 ..', 'hint': '试试 /sdcard/ 开头的路径'});
        }
        // 白名单：仅允许已知安全的 Android 路径前缀
        const allowedPrefixes = ['/sdcard/', '/storage/emulated/', '/mnt/sdcard/'];
        final isAllowed = allowedPrefixes.any((p) => rawPath.startsWith(p));
        if (!isAllowed) {
          return jsonEncode({'error': '不允许访问此路径。仅支持 /sdcard/ 和 /storage/ 下的目录。',
            'hint': '试试 /sdcard/Download/ 或 /sdcard/DCIM/'});
        }
        final depth = ((args['depth'] as int?) ?? 0).clamp(0, 1);
        final dir = Directory(rawPath);
        if (!await dir.exists()) {
          // 兼容性：某些设备上 /storage/emulated/0/ 路径不存在但 /sdcard/ 可以用
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

  // ── delete_file — 删除文件（慎用）──
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

/// 规范化文件路径：去除存储目录前缀、拒绝路径遍历。
/// AI 可能传入来自之前工具结果的绝对路径，需要安全地转为相对路径。
String _normalizePath(String rawPath, String storageDir) {
  // 去掉存储目录前缀，转为相对路径
  if (rawPath.startsWith(storageDir)) {
    var rel = rawPath.substring(storageDir.length);
    if (rel.startsWith('/')) rel = rel.substring(1);
    return rel.isEmpty ? '.' : rel;
  }
  // 去掉 solvhen_files/ 前缀（工具已自动添加存储目录前缀，避免重复）
  if (rawPath.startsWith('solvhen_files/')) {
    return rawPath.substring('solvhen_files/'.length);
  }
  // 如果是绝对路径但不是我们的存储目录，提取文件名避免双重拼接
  if (rawPath.startsWith('/')) {
    return rawPath.split('/').last;
  }
  // 拒绝路径遍历攻击（.. 可用于跳出沙箱目录）
  if (rawPath.contains('..')) {
    // 注意：这里使用 ArgumentError 而非 FormatException 更合适
    // FormatException 用于数据格式问题，路径遍历是安全违规
    throw FormatException('不允许路径遍历: $rawPath');
  }
  return rawPath;
}

/// 递归浏览目录，返回目录树结构。
/// [depth] 控制递归深度：0 仅当前目录，>0 则递归子目录。
Future<Map<String, dynamic>> _browseDir(Directory dir, int depth) async {
  final items = <Map<String, dynamic>>[];
  try {
    final entities = await dir.list().toList();
    // 排序：目录在前，文件在后，同类按名称字母排序
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
        // ⚠️ 性能注意：entity.length() 被调用了两次（size 和 size_human）
        // 后续应缓存 length 值避免重复 I/O
        final fileSize = await entity.length();
        items.add({
          'name': name,
          'type': 'file',
          'path': entity.path,
          'size': fileSize,
          'size_human': _fmtSize(fileSize),
          'modified': (await entity.lastModified()).toIso8601String(),
        });
      }
    }
  } on FileSystemException {
    // 权限不足时向上抛出，让 handler 层给出友好提示
    rethrow;
  }
  return {'items': items, 'count': items.length};
}

/// 格式化文件大小为人类可读的字符串。
String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// 获取 Solvhen 的文件存储目录（应用文档目录下的 solvhen_files）。
/// 目录不存在时自动创建。
Future<Directory> _storageDir() async {
  final appDir = await getApplicationDocumentsDirectory();
  final solvhenDir = Directory('${appDir.path}/solvhen_files');
  if (!await solvhenDir.exists()) {
    await solvhenDir.create(recursive: true);
  }
  return solvhenDir;
}
