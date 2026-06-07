// ═══════════════════════════════════════════════════════════════
// Solvhen — AI手机智能体 | 世于我愿
// 重型记忆服务 — FTS5全文搜索 + 重要性衰减 + 关联图谱 + 情景记忆 + 工作记忆
// ═══════════════════════════════════════════════════════════════

library;

import 'dart:math';
import 'database_service.dart';

/// 记忆条目
class MemoryEntry {
  final int? id;
  final String category;
  final String content;
  final double importance;
  final int accessCount;
  final DateTime? lastAccess;
  final int? sourceConversationId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const MemoryEntry({
    this.id,
    required this.category,
    required this.content,
    this.importance = 0.5,
    this.accessCount = 0,
    this.lastAccess,
    this.sourceConversationId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory MemoryEntry.fromMap(Map<String, dynamic> m) => MemoryEntry(
    id: m['id'] as int?,
    category: m['category'] as String,
    content: m['content'] as String,
    importance: (m['importance'] as num?)?.toDouble() ?? 0.5,
    accessCount: m['access_count'] as int? ?? 0,
    lastAccess: m['last_access'] != null ? DateTime.tryParse(m['last_access'] as String) : null,
    sourceConversationId: m['source_conversation_id'] as int?,
    createdAt: DateTime.parse(m['created_at'] as String),
    updatedAt: DateTime.parse(m['updated_at'] as String),
  );

  /// 衰减后有效重要性 = importance × 时间衰减 × 访问频率加成
  double effectiveImportance({DateTime? now}) {
    final n = now ?? DateTime.now();

    // 时间衰减：超过7天未访问，重要性指数下降
    double decay = 1.0;
    if (lastAccess != null) {
      final daysSince = n.difference(lastAccess!).inHours / 24.0;
      if (daysSince > 7) {
        decay = exp(-0.05 * (daysSince - 7)); // 7天后每天衰减5%
      }
    } else {
      final daysSince = n.difference(createdAt).inHours / 24.0;
      if (daysSince > 14) {
        decay = exp(-0.03 * (daysSince - 14));
      }
    }

    // 访问频率加成：log(accessCount + 1)
    final freqBonus = 1.0 + log(accessCount + 1) * 0.15;

    return (importance * decay * freqBonus).clamp(0.0, 1.0);
  }
}

/// 记忆关联
class MemoryLink {
  final int? id;
  final int sourceId;
  final int targetId;
  final String relation;
  final double strength;

  const MemoryLink({
    this.id,
    required this.sourceId,
    required this.targetId,
    this.relation = 'related_to',
    this.strength = 0.5,
  });
}

/// 情景记忆
class MemoryEpisode {
  final int? id;
  final int conversationId;
  final String summary;
  final int participantCount;
  final int messageCount;
  final DateTime startTime;
  final DateTime? endTime;
  final double importance;

  const MemoryEpisode({
    this.id,
    required this.conversationId,
    required this.summary,
    this.participantCount = 1,
    this.messageCount = 0,
    required this.startTime,
    this.endTime,
    this.importance = 0.5,
  });
}

/// 重型记忆服务——替代原来的轻量 global_memories
class MemoryService {
  static final MemoryService _instance = MemoryService._();
  factory MemoryService() => _instance;
  MemoryService._();

  // ═══════════════════════════════════════
  // 记忆条目 CRUD
  // ═══════════════════════════════════════

  /// 保存记忆——先 FTS5 查重（语义相似 >80% 的合并），再加上重要性评分
  Future<MemoryEntry> save({
    required String category,
    required String content,
    double importance = 0.5,
    int? sourceConversationId,
  }) async {
    final db = await DB.database;

    // FTS5 查重：找相似记忆，相似度 >0.7 则合并
    final similar = await _findSimilar(category, content);
    if (similar != null) {
      // 合并：更新重要性（取最高），增加访问计数
      final newImportance = max(importance, similar.importance + 0.1);
      final newAccessCount = similar.accessCount + 1;
      await db.update('memory_entries', {
        'importance': newImportance,
        'access_count': newAccessCount,
        'last_access': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }, where: 'id = ?', whereArgs: [similar.id]);
      return MemoryEntry(
        id: similar.id,
        category: category,
        content: content,
        importance: newImportance,
        accessCount: newAccessCount,
        lastAccess: DateTime.now(),
        createdAt: similar.createdAt,
        updatedAt: DateTime.now(),
      );
    }

    // 新记忆插入
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('memory_entries', {
      'category': category,
      'content': content,
      'importance': importance,
      'access_count': 1,
      'last_access': now,
      'source_conversation_id': sourceConversationId,
      'created_at': now,
      'updated_at': now,
    });

    // 同步 FTS5 索引
    try {
      await db.rawInsert(
        'INSERT INTO memory_fts(rowid, category, content) VALUES (?, ?, ?)',
        [id, category, content],
      );
    } catch (_) {}

    return MemoryEntry(
      id: id,
      category: category,
      content: content,
      importance: importance,
      accessCount: 1,
      lastAccess: DateTime.now(),
      sourceConversationId: sourceConversationId,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  /// FTS5 全文搜索
  Future<List<MemoryEntry>> search(String query, {int limit = 20}) async {
    final db = await DB.database;
    List<Map<String, dynamic>> rows;
    try {
      rows = await db.rawQuery(
        'SELECT me.* FROM memory_entries me '
        'JOIN memory_fts fts ON me.id = fts.rowid '
        'WHERE memory_fts MATCH ? '
        'ORDER BY rank '
        'LIMIT ?',
        [query, limit],
      );
    } catch (_) {
      // FTS5 不可用时回退 LIKE
      rows = await db.query('memory_entries',
        where: 'content LIKE ?',
        whereArgs: ['%$query%'],
        orderBy: 'importance DESC',
        limit: limit,
      );
    }

    final results = rows.map((r) => MemoryEntry.fromMap(r)).toList();

    // 更新访问计数和最后访问时间
    for (final e in results) {
      if (e.id != null) {
        await db.update('memory_entries', {
          'access_count': e.accessCount + 1,
          'last_access': DateTime.now().toIso8601String(),
        }, where: 'id = ?', whereArgs: [e.id]);
      }
    }

    return results;
  }

  /// 按重要性排序取记忆（带衰减）
  Future<List<MemoryEntry>> getTopMemories({int limit = 30}) async {
    final db = await DB.database;
    final rows = await db.query('memory_entries',
      orderBy: 'importance DESC, access_count DESC',
      limit: limit,
    );
    return rows.map((r) => MemoryEntry.fromMap(r)).toList();
  }

  /// 按类别获取
  Future<List<MemoryEntry>> getByCategory(String category, {int limit = 20}) async {
    final db = await DB.database;
    final rows = await db.query('memory_entries',
      where: 'category = ?',
      whereArgs: [category],
      orderBy: 'importance DESC',
      limit: limit,
    );
    return rows.map((r) => MemoryEntry.fromMap(r)).toList();
  }

  /// 删除记忆
  Future<void> delete(int id) async {
    final db = await DB.database;
    await db.delete('memory_entries', where: 'id = ?', whereArgs: [id]);
    try { await db.delete('memory_fts', where: 'rowid = ?', whereArgs: [id]); } catch (_) {}
    await db.delete('memory_links', where: 'source_id = ? OR target_id = ?', whereArgs: [id, id]);
  }

  // ═══════════════════════════════════════
  // 关联图谱
  // ═══════════════════════════════════════

  /// 建立记忆关联
  Future<void> link(int sourceId, int targetId, {String relation = 'related_to', double strength = 0.5}) async {
    final db = await DB.database;
    await db.insert('memory_links', {
      'source_id': sourceId,
      'target_id': targetId,
      'relation': relation,
      'strength': strength,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// 获取关联记忆——从匹配的记忆沿 link 扩散一跳
  Future<List<MemoryEntry>> getLinked(int memoryId) async {
    final db = await DB.database;
    final rows = await db.rawQuery('''
      SELECT DISTINCT me.* FROM memory_entries me
      JOIN memory_links ml ON (ml.target_id = me.id OR ml.source_id = me.id)
      WHERE (ml.source_id = ? OR ml.target_id = ?) AND me.id != ?
      ORDER BY ml.strength DESC
      LIMIT 10
    ''', [memoryId, memoryId, memoryId]);
    return rows.map((r) => MemoryEntry.fromMap(r)).toList();
  }

  // ═══════════════════════════════════════
  // 情景记忆
  // ═══════════════════════════════════════

  /// 保存对话情景摘要
  Future<void> saveEpisode({
    required int conversationId,
    required String summary,
    int participantCount = 1,
    int messageCount = 0,
    required DateTime startTime,
    DateTime? endTime,
    double importance = 0.5,
  }) async {
    final db = await DB.database;
    await db.insert('memory_episodes', {
      'conversation_id': conversationId,
      'summary': summary,
      'participant_count': participantCount,
      'message_count': messageCount,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime?.toIso8601String(),
      'importance': importance,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// 获取最近的情景记忆
  Future<List<MemoryEpisode>> getRecentEpisodes({int limit = 5}) async {
    final db = await DB.database;
    final rows = await db.query('memory_episodes',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map((r) => MemoryEpisode(
      id: r['id'] as int?,
      conversationId: r['conversation_id'] as int,
      summary: r['summary'] as String,
      participantCount: r['participant_count'] as int? ?? 1,
      messageCount: r['message_count'] as int? ?? 0,
      startTime: DateTime.parse(r['start_time'] as String),
      endTime: r['end_time'] != null ? DateTime.tryParse(r['end_time'] as String) : null,
      importance: (r['importance'] as num?)?.toDouble() ?? 0.5,
    )).toList();
  }

  // ═══════════════════════════════════════
  // 工作记忆
  // ═══════════════════════════════════════

  /// 记录一轮对话到工作记忆
  Future<void> addWorkingTurn({
    required int conversationId,
    required int turnIndex,
    required String userMsg,
    required String assistantMsg,
    String? keyPoints,
  }) async {
    final db = await DB.database;
    await db.insert('working_memory', {
      'conversation_id': conversationId,
      'turn_index': turnIndex,
      'user_msg': userMsg,
      'assistant_msg': assistantMsg,
      'key_points': keyPoints,
      'created_at': DateTime.now().toIso8601String(),
    });
    // 只保留最近50轮
    await db.rawDelete(
      'DELETE FROM working_memory WHERE conversation_id = ? AND id NOT IN (SELECT id FROM working_memory WHERE conversation_id = ? ORDER BY id DESC LIMIT 50)',
      [conversationId, conversationId],
    );
  }

  /// 获取最近N轮工作记忆
  Future<List<Map<String, dynamic>>> getWorkingMemory(int conversationId, {int turns = 10}) async {
    final db = await DB.database;
    return db.query('working_memory',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'turn_index DESC',
      limit: turns,
    );
  }

  /// 清除某对话的工作记忆
  Future<void> clearWorkingMemory(int conversationId) async {
    final db = await DB.database;
    await db.delete('working_memory',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  // ═══════════════════════════════════════
  // 智能检索——多层策略
  // ═══════════════════════════════════════

  /// 综合检索：关键词匹配 + 关联扩散 + 重要性排序 + 情景关联
  /// 返回最相关的记忆，按综合得分排序
  Future<List<MemoryEntry>> retrieve(String currentMessage, {int maxResults = 15}) async {
    final allResults = <MemoryEntry>[];
    final seenIds = <int>{};

    // Layer 1: FTS5 关键词搜索
    final keywords = _extractKeywords(currentMessage);
    for (final kw in keywords) {
      final matches = await search(kw, limit: 10);
      for (final m in matches) {
        if (m.id != null && seenIds.add(m.id!)) {
          allResults.add(m);
        }
      }
    }

    // Layer 2: 关联扩散——从匹配到的记忆中找关联
    final linkedIds = <int>{};
    for (final m in allResults.toList()) {
      if (m.id == null) continue;
      final linked = await getLinked(m.id!);
      for (final l in linked) {
        if (l.id != null && seenIds.add(l.id!)) {
          linkedIds.add(l.id!);
          allResults.add(l);
        }
      }
    }

    // Layer 3: 按有效重要性排序（带衰减）
    allResults.sort((a, b) =>
      b.effectiveImportance().compareTo(a.effectiveImportance()));

    return allResults.take(maxResults).toList();
  }

  // ═══════════════════════════════════════
  // 记忆合并压缩
  // ═══════════════════════════════════════

  /// 合并同类别相似记忆——减少冗余
  Future<int> consolidate() async {
    final db = await DB.database;
    int merged = 0;

    final categories = ['preference', 'fact', 'name', 'summary'];
    for (final cat in categories) {
      final rows = await db.query('memory_entries',
        where: 'category = ?',
        whereArgs: [cat],
        orderBy: 'importance DESC',
      );

      // 合并相似度 >0.8 的记忆
      for (int i = 0; i < rows.length; i++) {
        for (int j = i + 1; j < rows.length; j++) {
          final a = rows[i]['content'] as String;
          final b = rows[j]['content'] as String;
          if (_textSimilarity(a, b) > 0.8) {
            // 保留重要性更高的，删除另一个
            final remove = rows[j];
            await db.delete('memory_entries', where: 'id = ?', whereArgs: [remove['id']]);
            try { await db.delete('memory_fts', where: 'rowid = ?', whereArgs: [remove['id']]); } catch (_) {}
            merged++;
          }
        }
      }
    }
    return merged;
  }

  // ═══════════════════════════════════════
  // 私有辅助
  // ═══════════════════════════════════════

  /// FTS5 相似记忆查找
  Future<MemoryEntry?> _findSimilar(String category, String content) async {
    final db = await DB.database;
    // 用 FTS5 找同类别相似记忆
    List<Map<String, dynamic>> rows;
    try {
      rows = await db.rawQuery(
        'SELECT me.* FROM memory_entries me '
        'JOIN memory_fts fts ON me.id = fts.rowid '
        'WHERE me.category = ? AND memory_fts MATCH ? '
        'ORDER BY rank LIMIT 1',
        [category, _ftsQuery(content)],
      );
    } catch (_) {
      return null;
    }
    if (rows.isEmpty) return null;

    final entry = MemoryEntry.fromMap(rows.first);
    // 文本相似度检查
    if (_textSimilarity(entry.content, content) > 0.7) {
      return entry;
    }
    return null;
  }

  /// 将文本转为 FTS5 兼容查询
  String _ftsQuery(String text) {
    // FTS5 简单分词：取前10个字作为查询
    final words = text
      .replaceAll(RegExp(r'[^\u4e00-\u9fff\w]'), ' ')
      .split(' ')
      .where((w) => w.length >= 2)
      .take(5)
      .join(' OR ');
    return words.isNotEmpty ? words : '"${text.substring(0, text.length.clamp(0, 20))}"';
  }

  /// 提取关键词——中文分词简化版
  List<String> _extractKeywords(String text) {
    final keywords = <String>[];
    // 2-4字短语提取
    final chars = text.replaceAll(RegExp(r'[^\u4e00-\u9fff\w]'), '');
    for (int len = 3; len >= 2; len--) {
      for (int i = 0; i + len <= chars.length; i++) {
        final phrase = chars.substring(i, i + len);
        if (!keywords.contains(phrase)) {
          keywords.add(phrase);
        }
      }
    }
    return keywords.take(8).toList();
  }

  /// 简单文本相似度——Jaccard 字符级
  double _textSimilarity(String a, String b) {
    final setA = a.runes.toSet();
    final setB = b.runes.toSet();
    final intersection = setA.intersection(setB).length;
    final union = setA.union(setB).length;
    return union == 0 ? 0 : intersection / union;
  }
}
