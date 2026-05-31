import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/conversation.dart';
import '../models/persona.dart';

class DB {
  static Database? _db;
  static Completer<Database>? _dbCompleter;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    if (_dbCompleter != null) return _dbCompleter!.future;
    _dbCompleter = Completer<Database>();
    try {
      final dbPath = await getDatabasesPath();
      final path = p.join(dbPath, 'companion_v2.db');
      _db = await openDatabase(path, version: 7, onCreate: _create,
        onUpgrade: _upgrade,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA journal_mode=WAL');
          await db.rawQuery('PRAGMA foreign_keys=ON');
        },
      );
      _dbCompleter!.complete(_db!);
      return _db!;
    } catch (e) {
      _dbCompleter!.completeError(e);
      _dbCompleter = null;
      // If DB open failed (e.g. FTS5 during migration), delete and retry once
      try {
        final dbPath = await getDatabasesPath();
        final path = p.join(dbPath, 'companion_v2.db');
        await deleteDatabase(path);
        _dbCompleter = Completer<Database>();
        _db = await openDatabase(path, version: 7, onCreate: _create,
          onUpgrade: _upgrade,
          onConfigure: (db) async {
            await db.rawQuery('PRAGMA journal_mode=WAL');
            await db.rawQuery('PRAGMA foreign_keys=ON');
          },
        );
        _dbCompleter!.complete(_db!);
        return _db!;
      } catch (e2) {
        _dbCompleter!.completeError(e2);
        _dbCompleter = null;
        rethrow;
      }
    }
  }

  static Future<void> _create(Database db, int v) async {
    // ── Conversations ──
    await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '新对话',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        consolidated_at TEXT
      )
    ''');
    await db.execute('CREATE INDEX idx_conv_time ON conversations(updated_at DESC)');

    // ── Messages (with conversation_id) ──
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        role TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        token_count INTEGER DEFAULT 0,
        tool_call_id TEXT,
        tool_calls_json TEXT,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('CREATE INDEX idx_msg_conv ON messages(conversation_id, timestamp)');

    // ── FTS for message search (try FTS5, skip if not supported) ──
    try {
      await db.execute('''
        CREATE VIRTUAL TABLE messages_fts USING fts5(
          content, role, content= messages, content_rowid= id
        )
      ''');
      await db.execute('''
        CREATE TRIGGER msg_ai AFTER INSERT ON messages BEGIN
          INSERT OR REPLACE INTO messages_fts(rowid, content, role) VALUES (new.id, new.content, new.role);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER msg_ad AFTER DELETE ON messages BEGIN
          INSERT INTO messages_fts(messages_fts, rowid, content, role) VALUES('delete', old.id, old.content, old.role);
        END
      ''');
    } catch (_) {
      // FTS5 not available on this device — search_history will use LIKE fallback
    }

    // ── Personas ──
    await db.execute('''
      CREATE TABLE personas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        prompt TEXT NOT NULL DEFAULT '',
        active INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

    // ── Config ──
    await db.execute('''
      CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL)
    ''');

    // ── Global Memories (conversation-independent, survives new chats) ──
    await db.execute('''
      CREATE TABLE global_memories (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL,
        content TEXT NOT NULL,
        source_conversation_id INTEGER,
        created_at TEXT NOT NULL,
        FOREIGN KEY (source_conversation_id) REFERENCES conversations(id) ON DELETE SET NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_gm_category ON global_memories(category)');
    // ── Skills ──
    await db.execute('''
      CREATE TABLE skills (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE,
        content TEXT NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        priority INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_skills_enabled ON skills(enabled, priority)');
    await db.insert('config', {'key': 'base_url', 'value': 'https://api.deepseek.com/v1'});
    await db.insert('config', {'key': 'model', 'value': 'deepseek-v4-pro'});
    await db.insert('config', {'key': 'api_key', 'value': ''});
    await db.insert('config', {'key': 'active_conversation', 'value': ''});

    // Skills are now loaded from assets/skills/ by SkillLoader.sync() at startup.
    // No longer seeded here — the DB skills table starts empty and is populated
    // on first SkillLoader run (INSERT OR REPLACE, idempotent).

    // ── Create default conversation ──
    final now = DateTime.now().toIso8601String();
    await db.insert('conversations', {
      'title': '新对话', 'created_at': now, 'updated_at': now,
    });
  }

  static Future<void> _upgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN tool_call_id TEXT');
    }
    if (oldV < 3) {
      // Add conversation_id to messages (nullable first)
      await db.execute('ALTER TABLE messages ADD COLUMN conversation_id INTEGER DEFAULT 1');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id, timestamp)');
      // Create conversations table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS conversations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL DEFAULT '新对话',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_conv_time ON conversations(updated_at DESC)');
      // Insert default conversation if none exists
      final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM conversations')) ?? 0;
      if (count == 0) {
        final now = DateTime.now().toIso8601String();
        await db.insert('conversations', {
          'title': '新对话', 'created_at': now, 'updated_at': now,
        });
      }
      // Create FTS (skip if device doesn't support FTS5)
      try {
        await db.execute('''
          CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            content, role, content= messages, content_rowid= id
          )
        ''');
        await db.execute('''
          CREATE TRIGGER IF NOT EXISTS msg_ai AFTER INSERT ON messages BEGIN
            INSERT INTO messages_fts(rowid, content, role) VALUES (new.id, new.content, new.role);
          END
        ''');
        await db.execute('''
          CREATE TRIGGER IF NOT EXISTS msg_ad AFTER DELETE ON messages BEGIN
            INSERT INTO messages_fts(messages_fts, rowid, content, role) VALUES('delete', old.id, old.content, old.role);
          END
        ''');
      } catch (_) {
        // FTS5 not available — search will use LIKE fallback
      }
      // Create personas table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS personas (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          prompt TEXT NOT NULL DEFAULT '',
          active INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
      // Drop old persona/custom_persona config keys — replaced by personas table
      await db.delete('config', where: 'key IN (?, ?)', whereArgs: ['persona', 'custom_persona']);
      // Add active_conversation config
      await db.rawInsert(
        'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)',
        ['active_conversation', '1'],
      );
    }
    if (oldV < 4) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS global_memories (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          category TEXT NOT NULL,
          content TEXT NOT NULL,
          source_conversation_id INTEGER,
          created_at TEXT NOT NULL,
          FOREIGN KEY (source_conversation_id) REFERENCES conversations(id) ON DELETE SET NULL
        )
      ''');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_gm_category ON global_memories(category)');
    }
    if (oldV < 5) {
      await db.execute('ALTER TABLE messages ADD COLUMN tool_calls_json TEXT');
    }
    if (oldV < 6) {
      await db.execute('ALTER TABLE conversations ADD COLUMN consolidated_at TEXT');
    }
    if (oldV < 7) {
      await db.execute('''
        CREATE TABLE skills (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE,
          content TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          priority INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX idx_skills_enabled ON skills(enabled, priority)');
    }
  }

  // ═══════════════════════════════════════
  // CONFIG
  // ═══════════════════════════════════════

  static Future<Map<String, String>> getConfig() async {
    final db = await database;
    final rows = await db.query('config');
    return {for (var r in rows) r['key'] as String: r['value'] as String};
  }

  static Future<void> setConfig(String key, String value) async {
    final db = await database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)',
      [key, value],
    );
  }

  // ═══════════════════════════════════════
  // CONVERSATIONS
  // ═══════════════════════════════════════

  static Future<List<Conversation>> getConversations() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT c.*, COUNT(m.id) as message_count
      FROM conversations c
      LEFT JOIN messages m ON c.id = m.conversation_id
      GROUP BY c.id
      ORDER BY c.updated_at DESC
    ''');
    return rows.map((r) {
      final c = Conversation.fromMap(r);
      return c.copyWith(messageCount: r['message_count'] as int? ?? 0);
    }).toList();
  }

  static Future<Conversation> createConversation({String title = '新对话'}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('conversations', {
      'title': title, 'created_at': now, 'updated_at': now,
    });
    return Conversation(id: id, title: title, createdAt: DateTime.now(), updatedAt: DateTime.now());
  }

  static Future<void> updateConversationTitle(int id, String title) async {
    final db = await database;
    await db.update('conversations',
      {'title': title, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?', whereArgs: [id],
    );
  }

  static Future<void> touchConversation(int id) async {
    final db = await database;
    await db.update('conversations',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?', whereArgs: [id],
    );
  }

  static Future<void> deleteConversation(int id) async {
    final db = await database;
    await db.delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  static Future<int> getActiveConversationId() async {
    final c = await getConfig();
    final idStr = c['active_conversation'] ?? '';
    final id = int.tryParse(idStr);
    if (id != null && id > 0) return id;
    // Fallback: first conversation
    final db = await database;
    final first = await db.query('conversations', orderBy: 'id ASC', limit: 1);
    if (first.isNotEmpty) {
      final fid = first.first['id'] as int;
      await setConfig('active_conversation', fid.toString());
      return fid;
    }
    // Create one
    final conv = await createConversation();
    await setConfig('active_conversation', conv.id.toString());
    return conv.id!;
  }

  static Future<void> setActiveConversation(int id) async {
    await setConfig('active_conversation', id.toString());
  }

  // ═══════════════════════════════════════
  // MESSAGES
  // ═══════════════════════════════════════

  static Future<List<Map<String, dynamic>>> getMessages(int conversationId, {int limit = 50}) async {
    final db = await database;
    return db.query('messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp ASC',
      limit: limit,
    );
  }

  static Future<int> getMessageCount(int conversationId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM messages WHERE conversation_id = ?',
      [conversationId],
    );
    return result.first['cnt'] as int? ?? 0;
  }

  /// Full-text search across all messages. Tries FTS5, falls back to LIKE.
  static Future<List<Map<String, dynamic>>> searchMessages(String query, {int limit = 20}) async {
    final db = await database;
    try {
      // Escape FTS5 special characters to prevent syntax errors
      final safeQuery = _escapeFts5(query);
      return await db.rawQuery('''
        SELECT m.content, m.role, m.conversation_id, m.timestamp
        FROM messages_fts f
        JOIN messages m ON f.rowid = m.id
        WHERE messages_fts MATCH ?
        ORDER BY m.timestamp DESC
        LIMIT ?
      ''', [safeQuery, limit]);
    } catch (_) {
      // FTS not available — fall back to LIKE
      return await db.rawQuery('''
        SELECT content, role, conversation_id, timestamp
        FROM messages
        WHERE content LIKE ?
        ORDER BY timestamp DESC
        LIMIT ?
      ''', ['%$query%', limit]);
    }
  }

  /// Estimate token count for messages + system prompt.
  /// CJK-aware: CJK chars ~1.5 tokens, ASCII ~0.25 tokens.
  static int estimateTokens(List<Map<String, dynamic>> messages, String systemPrompt) {
    int chars = systemPrompt.length;
    for (final m in messages) {
      chars += (m['content'] as String?)?.length ?? 0;
    }
    // Count CJK characters separately
    int cjk = 0;
    for (var i = 0; i < systemPrompt.length; i++) {
      final c = systemPrompt.codeUnitAt(i);
      if ((c >= 0x2E80 && c <= 0x2FDF) || // CJK Radicals
          (c >= 0x3000 && c <= 0x33FF) || // Punctuation + Kana
          (c >= 0x3400 && c <= 0x4DBF) || // CJK Extension A
          (c >= 0x4E00 && c <= 0x9FFF) || // CJK Unified
          (c >= 0xF900 && c <= 0xFAFF) || // CJK Compatibility
          (c >= 0xFE30 && c <= 0xFE4F) || // CJK Compat Forms
          (c >= 0xAC00 && c <= 0xD7AF)) { // Hangul
        cjk++;
      }
    }
    for (final m in messages) {
      final content = (m['content'] as String?) ?? '';
      for (var i = 0; i < content.length; i++) {
        final c = content.codeUnitAt(i);
        if ((c >= 0x2E80 && c <= 0x2FDF) ||
            (c >= 0x3000 && c <= 0x33FF) ||
            (c >= 0x3400 && c <= 0x4DBF) ||
            (c >= 0x4E00 && c <= 0x9FFF) ||
            (c >= 0xF900 && c <= 0xFAFF) ||
            (c >= 0xFE30 && c <= 0xFE4F) ||
            (c >= 0xAC00 && c <= 0xD7AF)) {
          cjk++;
        }
      }
    }
    final ascii = chars - cjk;
    // CJK ~1.5 tokens, ASCII ~0.25 tokens, +10% overhead for format/special tokens
    return ((cjk * 1.5 + ascii * 0.25) * 1.1).round();
  }

  /// Per-model context window in tokens.
  static int contextWindow(String model) {
    final m = model.toLowerCase();
    // 1M context models
    if (m.contains('deepseek-v4')) return 1048576;
    if (m.contains('doubao-seed-2')) return 1048576;
    // 128K models
    if (m.contains('deepseek-reasoner') || m.contains('r1')) return 131072;
    if (m.contains('doubao-seed-1.6')) return 131072;
    if (m.contains('doubao') || m.contains('seed')) return 131072;
    if (m.contains('gpt-4o')) return 128000;
    // 200K models
    if (m.contains('claude-3.5') || m.contains('claude-4')) return 200000;
    if (m.contains('claude')) return 200000;
    // Legacy
    if (m.contains('gpt-4')) return 8192;
    if (m.contains('qwen')) return 32768;
    return 131072; // default
  }

  // ═══════════════════════════════════════
  // PERSONAS
  // ═══════════════════════════════════════

  static Future<List<Persona>> getPersonas() async {
    final db = await database;
    final rows = await db.query('personas', orderBy: 'created_at ASC');
    return rows.map((r) => Persona.fromMap(r)).toList();
  }

  static Future<Persona> createPersona({required String name, String prompt = ''}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('personas', {
      'name': name, 'prompt': prompt, 'active': 0, 'created_at': now,
    });
    return Persona(id: id, name: name, prompt: prompt, active: false, createdAt: DateTime.now());
  }

  static Future<void> updatePersona(int id, {String? name, String? prompt}) async {
    final db = await database;
    final updates = <String, dynamic>{};
    if (name != null) updates['name'] = name;
    if (prompt != null) updates['prompt'] = prompt;
    if (updates.isNotEmpty) {
      await db.update('personas', updates, where: 'id = ?', whereArgs: [id]);
    }
  }

  static Future<void> deletePersona(int id) async {
    final db = await database;
    await db.delete('personas', where: 'id = ?', whereArgs: [id]);
  }

  /// Activate exactly one persona, deactivate all others.
  static Future<void> activatePersona(int? id) async {
    final db = await database;
    await db.update('personas', {'active': 0});
    if (id != null) {
      await db.update('personas', {'active': 1}, where: 'id = ?', whereArgs: [id]);
    }
  }

  static Future<Persona?> getActivePersona() async {
    final db = await database;
    final rows = await db.query('personas', where: 'active = 1', limit: 1);
    if (rows.isEmpty) return null;
    return Persona.fromMap(rows.first);
  }

  // ═══════════════════════════════════════
  // GLOBAL MEMORIES (conversation-independent)
  // ═══════════════════════════════════════

  /// Get all global memories, grouped by category.
  static Future<Map<String, List<String>>> getGlobalMemories() async {
    final db = await database;
    final rows = await db.query('global_memories', orderBy: 'created_at DESC');
    final grouped = <String, List<String>>{};
    for (final r in rows) {
      final cat = r['category'] as String;
      final content = r['content'] as String;
      grouped.putIfAbsent(cat, () => []).add(content);
    }
    return grouped;
  }

  /// Search global memories by content LIKE query, grouped by category.
  static Future<Map<String, List<String>>> searchGlobalMemories(String query) async {
    final db = await database;
    final rows = await db.query('global_memories',
      where: 'content LIKE ?',
      whereArgs: ['%$query%'],
      orderBy: 'created_at DESC',
    );
    final grouped = <String, List<String>>{};
    for (final r in rows) {
      final cat = r['category'] as String;
      final content = r['content'] as String;
      grouped.putIfAbsent(cat, () => []).add(content);
    }
    return grouped;
  }

  /// Save a memory to global store. Deduplicates by content.
  static Future<void> saveGlobalMemory({
    required String category,
    required String content,
    int? sourceConversationId,
  }) async {
    final db = await database;
    // Deduplicate: skip if identical content already exists
    final existing = await db.query('global_memories',
      where: 'category = ? AND content = ?',
      whereArgs: [category, content],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    await db.rawInsert(
      'INSERT INTO global_memories (category, content, source_conversation_id, created_at) VALUES (?, ?, ?, ?)',
      [category, content, sourceConversationId, DateTime.now().toIso8601String()],
    );
  }

  /// Clear all global memories.
  static Future<void> clearGlobalMemories() async {
    final db = await database;
    await db.delete('global_memories');
  }

  // ═══════════════════════════════════════
  // SKILLS
  // ═══════════════════════════════════════

  static Future<List<Map<String, dynamic>>> getEnabledSkills() async {
    final db = await database;
    return db.query('skills',
      where: 'enabled = 1',
      orderBy: 'priority DESC, created_at ASC',
    );
  }

  static Future<List<Map<String, dynamic>>> getAllSkills() async {
    final db = await database;
    return db.query('skills', orderBy: 'priority DESC, created_at ASC');
  }

  static Future<void> toggleSkill(String name, bool enable) async {
    final db = await database;
    await db.update('skills', {'enabled': enable ? 1 : 0}, where: 'name = ?', whereArgs: [name]);
  }

  static Future<void> addSkill(String name, String content, {int priority = 0}) async {
    final db = await database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO skills (name, content, enabled, priority, created_at) VALUES (?, ?, 1, ?, ?)',
      [name, content, priority, DateTime.now().toIso8601String()],
    );
  }

  static Future<void> deleteSkill(String name) async {
    final db = await database;
    await db.delete('skills', where: 'name = ?', whereArgs: [name]);
  }

  /// Escape special characters in FTS5 query to prevent syntax errors.
  /// FTS5 treats these as operators: * " ( ) + - and column-name prefixes.
  static String _escapeFts5(String query) {
    // Strip all FTS5 special characters — keep it simple
    return query.replaceAll(RegExp(r'[*"()+\-]'), '').trim();
  }
}
