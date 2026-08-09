/// Solvhen — SQLite数据库服务层：WAL模式 + FTS5搜索 + 版本迁移(v1→v11)
///
/// 数据表：
/// - conversations: 对话会话（标题/时间戳/整合标记）
/// - messages: 消息（内容/角色/会话关联/tool_call/外键级联删除）
/// - messages_fts: FTS5全文搜索虚拟表（含触发器自动同步）
/// - personas: 自定义人格（名称/提示词/激活标志）
/// - config: 键值对配置（api_key/base_url/model/llm_chain等）
/// - global_memories: 跨对话持久记忆（分类/内容/来源会话）
/// - skills: 技能库（name/content/enabled/priority）
/// - voice_profiles: 语音配置文件
///
/// 关键设计决策：
/// - 使用Completer模式避免并发DB打开 → 防止"database is locked"
/// - WAL模式提升并发读性能
/// - foreign_keys=ON保证消息级联删除
/// - 打开失败时只备份并抛错，绝不静默删除用户数据
library;

import 'dart:async';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import '../models/conversation.dart';
import '../models/persona.dart';

/// SQLite数据库门面 — 全静态方法，Completer保证单例初始化
class DB {
  static const schemaVersion = 11;
  static Database? _db;
  static Completer<Database>? _dbCompleter;

  /// 获取数据库实例 — 懒加载 + Completer防并发
  ///
  /// 并发安全：多个调用者同时请求database时，共享同一个Completer的future
  /// 打开失败时创建尽力而为的备份并抛错，由UI决定恢复策略。
  static Future<Database> get database async {
    if (_db != null) return _db!;
    if (_dbCompleter != null) return _dbCompleter!.future;
    _dbCompleter = Completer<Database>();
    try {
      final dbPath = await getDatabasesPath();
      final path = p.join(dbPath, 'companion_v2.db');
      _db = await openDatabase(
        path,
        version: schemaVersion,
        onCreate: _create,
        onUpgrade: _upgrade,
        onConfigure: (db) async {
          // WAL模式：写不阻塞读，适合AI对话场景（频繁读写交替）
          await db.rawQuery('PRAGMA journal_mode=WAL');
          // 外键约束：删除会话时自动级联删除消息
          await db.rawQuery('PRAGMA foreign_keys=ON');
        },
      );
      _dbCompleter!.complete(_db!);
      return _db!;
    } catch (e, stack) {
      // 数据优先：只备份，不删除或自动重建。瞬时I/O错误不应造成清库。
      try {
        final dbPath = await getDatabasesPath();
        final path = p.join(dbPath, 'companion_v2.db');
        final backupPath =
            '$path.backup.${DateTime.now().millisecondsSinceEpoch}';
        final dbFile = File(path);
        if (await dbFile.exists()) await dbFile.copy(backupPath);
      } catch (_) {
        // Backup is best-effort; preserve the original error and stack.
      }
      final completer = _dbCompleter!;
      _dbCompleter = null;
      if (!completer.isCompleted) {
        // The opener rethrows below while concurrent waiters receive the same
        // failure through the shared future. Attach an error observer first so
        // a run with no waiters does not create a second unhandled async error.
        unawaited(completer.future.then<void>(
          (_) {},
          onError: (_, __) {},
        ));
        completer.completeError(e, stack);
      }
      Error.throwWithStackTrace(e, stack);
    }
  }

  /// Opens a caller-owned database with the production migration callbacks.
  /// Only migration fixtures should use this; the normal app uses [database].
  static Future<Database> openDatabaseForTesting(String path) => openDatabase(
        path,
        version: schemaVersion,
        onCreate: _create,
        onUpgrade: _upgrade,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys=ON'),
      );

  /// Routes the static facade to a fixture database for secret-migration tests.
  static void attachDatabaseForTesting(Database database) {
    _db = database;
    _dbCompleter = null;
  }

  static void detachDatabaseForTesting() {
    _db = null;
    _dbCompleter = null;
  }

  /// 首次创建数据库 — 建所有表、索引、触发器、默认配置
  ///
  /// ⚠️ FTS5虚拟表使用try-catch包裹：部分Android设备不支持FTS5，
  /// 失败时静默跳过，searchMessages将使用LIKE回退
  static Future<void> _create(Database db, int v) async {
    try {
      // ── 对话表 ──
      await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '新对话',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        consolidated_at TEXT
      )
    ''');
      await db.execute(
          'CREATE INDEX idx_conv_time ON conversations(updated_at DESC)');

      // ── 消息表（含对话外键） ──
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
      // 复合索引：按会话+时间戳查询（最常见查询模式）
      await db.execute(
          'CREATE INDEX idx_msg_conv ON messages(conversation_id, timestamp)');

      // ── FTS5全文搜索 ──
      try {
        // content=外部内容表模式：FTS不存储本体，节省空间
        await db.execute('''
        CREATE VIRTUAL TABLE messages_fts USING fts5(
          content, role, content= messages, content_rowid= id
        )
      ''');
        // INSERT触发器 → 自动同步FTS索引
        await db.execute('''
        CREATE TRIGGER msg_ai AFTER INSERT ON messages BEGIN
          INSERT OR REPLACE INTO messages_fts(rowid, content, role) VALUES (new.id, new.content, new.role);
        END
      ''');
        // DELETE触发器 → 'delete'命令从FTS移除
        await db.execute('''
        CREATE TRIGGER msg_ad AFTER DELETE ON messages BEGIN
          INSERT INTO messages_fts(messages_fts, rowid, content, role) VALUES('delete', old.id, old.content, old.role);
        END
      ''');
      } catch (_) {
        // FTS5不可用 → searchMessages使用LIKE回退
      }

      // ── 人格表 ──
      await db.execute('''
      CREATE TABLE personas (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        prompt TEXT NOT NULL DEFAULT '',
        active INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');

      // ── 配置表 ──
      await db.execute('''
      CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL)
    ''');

      // ── 全局记忆（跨对话持久） ──
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
      await db
          .execute('CREATE INDEX idx_gm_category ON global_memories(category)');

      // ═══════════════════════════════════════
      // 重型记忆系统 (v10)
      // ═══════════════════════════════════════

      // 记忆条目——带重要性/访问追踪/衰减
      await db.execute('''
      CREATE TABLE memory_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        category TEXT NOT NULL,
        content TEXT NOT NULL,
        importance REAL NOT NULL DEFAULT 0.5,
        access_count INTEGER NOT NULL DEFAULT 0,
        last_access TEXT,
        source_conversation_id INTEGER,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (source_conversation_id) REFERENCES conversations(id) ON DELETE SET NULL
      )
    ''');
      await db
          .execute('CREATE INDEX idx_me_category ON memory_entries(category)');
      await db.execute(
          'CREATE INDEX idx_me_importance ON memory_entries(importance DESC)');

      // FTS5 全文索引——替代 LIKE（设备不支持时静默跳过）
      try {
        await db.execute('''
        CREATE VIRTUAL TABLE memory_fts USING fts5(
          category, content, content=memory_entries, content_rowid=id
        )
      ''');
      } catch (_) {
        // FTS5 不可用 → MemoryService.search 自动回退 LIKE
      }

      // 记忆关联图谱
      await db.execute('''
      CREATE TABLE memory_links (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id INTEGER NOT NULL,
        target_id INTEGER NOT NULL,
        relation TEXT NOT NULL DEFAULT "related_to",
        strength REAL NOT NULL DEFAULT 0.5,
        created_at TEXT NOT NULL,
        FOREIGN KEY (source_id) REFERENCES memory_entries(id) ON DELETE CASCADE,
        FOREIGN KEY (target_id) REFERENCES memory_entries(id) ON DELETE CASCADE
      )
    ''');

      // 情景记忆——每次对话自动摘要
      await db.execute('''
      CREATE TABLE memory_episodes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        summary TEXT NOT NULL,
        participant_count INTEGER DEFAULT 1,
        message_count INTEGER DEFAULT 0,
        start_time TEXT NOT NULL,
        end_time TEXT,
        importance REAL NOT NULL DEFAULT 0.5,
        created_at TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');

      // 工作记忆缓冲——最近N轮对话自动注入
      await db.execute('''
      CREATE TABLE working_memory (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        turn_index INTEGER NOT NULL,
        user_msg TEXT NOT NULL,
        assistant_msg TEXT NOT NULL,
        key_points TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');
      await db.execute(
          'CREATE INDEX idx_wm_conv ON working_memory(conversation_id, turn_index DESC)');

      // ── 技能表 ──
      // 技能由SkillLoader.sync()在启动时从assets同步，此处只建表
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
      await db.execute(
          'CREATE INDEX idx_skills_enabled ON skills(enabled, priority)');

      // ── 语音配置表 ──
      await db.execute("CREATE TABLE voice_profiles ("
          "id INTEGER PRIMARY KEY AUTOINCREMENT,"
          "name TEXT NOT NULL,"
          "voice_id TEXT NOT NULL DEFAULT 'zh-CN-XiaoxiaoNeural',"
          "pitch REAL NOT NULL DEFAULT 0.0,"
          "rate REAL NOT NULL DEFAULT 1.0,"
          "volume REAL NOT NULL DEFAULT 1.0,"
          "locale TEXT NOT NULL DEFAULT 'zh-CN',"
          "active INTEGER NOT NULL DEFAULT 0,"
          "created_at TEXT NOT NULL)");

      await _createAgentSecurityTables(db);

      // ── 默认配置 ──
      await db.insert('config',
          {'key': 'base_url', 'value': 'https://api.deepseek.com/v1'});
      await db.insert('config', {'key': 'model', 'value': 'deepseek-v4-pro'});
      await db.insert('config', {'key': 'api_key', 'value': ''});
      await db.insert('config', {'key': 'active_conversation', 'value': ''});

      // ── 创建默认对话 ──
      final now = DateTime.now().toIso8601String();
      await db.insert('conversations', {
        'title': '新对话',
        'created_at': now,
        'updated_at': now,
      });
    } catch (e) {
      throw Exception('数据库建表失败，可能是磁盘已满或权限不足: $e');
    }
  }

  /// 数据库版本迁移 — 增量升级，从oldV到newV
  ///
  /// v1→v2: 消息增加tool_call_id列
  /// v2→v3: 引入conversations表、消息关联会话、FTS5、人格表
  /// v3→v4: global_memories表
  /// v4→v5: 消息增加tool_calls_json列
  /// v5→v6: 对话增加consolidated_at列
  /// v6→v7: skills表
  /// v7→v8: voice_profiles表
  /// v8→v9: voice_profiles增加voice_id列（Edge TTS）
  /// v10→v11: agent运行记录、工具权限与本地审计
  static Future<void> _upgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN tool_call_id TEXT');
    }
    if (oldV < 3) {
      // 消息关联会话 → 先加列再建索引
      await db.execute(
          'ALTER TABLE messages ADD COLUMN conversation_id INTEGER DEFAULT 1');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id, timestamp)');
      // 创建对话表（如果不存在）
      await db.execute('''
        CREATE TABLE IF NOT EXISTS conversations (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL DEFAULT '新对话',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_conv_time ON conversations(updated_at DESC)');
      // 无对话时插入默认
      final count = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM conversations')) ??
          0;
      if (count == 0) {
        final now = DateTime.now().toIso8601String();
        await db.insert('conversations', {
          'title': '新对话',
          'created_at': now,
          'updated_at': now,
        });
      }
      // 尝试建FTS5 → 失败静默跳过
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
      } catch (_) {}
      // 人格表
      await db.execute('''
        CREATE TABLE IF NOT EXISTS personas (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          prompt TEXT NOT NULL DEFAULT '',
          active INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL
        )
      ''');
      // 迁移旧config key → 人格表已取代
      await db.delete('config',
          where: 'key IN (?, ?)', whereArgs: ['persona', 'custom_persona']);
      // 设置活跃对话
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
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_gm_category ON global_memories(category)');
    }
    if (oldV < 5) {
      await db.execute('ALTER TABLE messages ADD COLUMN tool_calls_json TEXT');
    }
    if (oldV < 6) {
      await db
          .execute('ALTER TABLE conversations ADD COLUMN consolidated_at TEXT');
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
      await db.execute(
          'CREATE INDEX idx_skills_enabled ON skills(enabled, priority)');
    }
    if (oldV < 8) {
      await db.execute("CREATE TABLE voice_profiles ("
          "id INTEGER PRIMARY KEY AUTOINCREMENT,"
          "name TEXT NOT NULL,"
          "voice_id TEXT NOT NULL DEFAULT 'zh-CN-XiaoxiaoNeural',"
          "pitch REAL NOT NULL DEFAULT 0.0,"
          "rate REAL NOT NULL DEFAULT 1.0,"
          "volume REAL NOT NULL DEFAULT 1.0,"
          "locale TEXT NOT NULL DEFAULT 'zh-CN',"
          "active INTEGER NOT NULL DEFAULT 0,"
          "created_at TEXT NOT NULL)");
    }
    if (oldV < 9) {
      try {
        await db.execute(
            "ALTER TABLE voice_profiles ADD COLUMN voice_id TEXT NOT NULL DEFAULT 'zh-CN-XiaoxiaoNeural'");
      } catch (_) {}
    }
    if (oldV < 10) {
      // v10: 重型记忆系统
      await db.execute('''
        CREATE TABLE IF NOT EXISTS memory_entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          category TEXT NOT NULL,
          content TEXT NOT NULL,
          importance REAL NOT NULL DEFAULT 0.5,
          access_count INTEGER NOT NULL DEFAULT 0,
          last_access TEXT,
          source_conversation_id INTEGER,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          FOREIGN KEY (source_conversation_id) REFERENCES conversations(id) ON DELETE SET NULL
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_me_category ON memory_entries(category)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_me_importance ON memory_entries(importance DESC)');
      try {
        await db.execute(
            'CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(category, content, content=memory_entries, content_rowid=id)');
      } catch (_) {}
      await db.execute('''
        CREATE TABLE IF NOT EXISTS memory_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          source_id INTEGER NOT NULL,
          target_id INTEGER NOT NULL,
          relation TEXT NOT NULL DEFAULT "related_to",
          strength REAL NOT NULL DEFAULT 0.5,
          created_at TEXT NOT NULL,
          FOREIGN KEY (source_id) REFERENCES memory_entries(id) ON DELETE CASCADE,
          FOREIGN KEY (target_id) REFERENCES memory_entries(id) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS memory_episodes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          conversation_id INTEGER NOT NULL,
          summary TEXT NOT NULL,
          participant_count INTEGER DEFAULT 1,
          message_count INTEGER DEFAULT 0,
          start_time TEXT NOT NULL,
          end_time TEXT,
          importance REAL NOT NULL DEFAULT 0.5,
          created_at TEXT NOT NULL,
          FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS working_memory (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          conversation_id INTEGER NOT NULL,
          turn_index INTEGER NOT NULL,
          user_msg TEXT NOT NULL,
          assistant_msg TEXT NOT NULL,
          key_points TEXT,
          created_at TEXT NOT NULL,
          FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_wm_conv ON working_memory(conversation_id, turn_index DESC)');
      // 迁移旧 global_memories → memory_entries
      final oldRows = await db.query('global_memories');
      for (final r in oldRows) {
        await db.insert('memory_entries', {
          'category': r['category'],
          'content': r['content'],
          'importance': 0.5,
          'access_count': 1,
          'source_conversation_id': r['source_conversation_id'],
          'created_at': r['created_at'],
          'updated_at': r['created_at'],
        });
      }
    }
    if (oldV < 11) {
      await _createAgentSecurityTables(db);
      await db.update(
        'agent_runs',
        {
          'status': 'cancelled',
          'finished_at': DateTime.now().toIso8601String(),
          'error_code': 'app_restarted',
        },
        where: "status NOT IN ('completed', 'cancelled', 'failed')",
      );
    }
  }

  static Future<void> _createAgentSecurityTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS agent_runs (
        id TEXT PRIMARY KEY,
        conversation_id INTEGER,
        origin TEXT NOT NULL,
        status TEXT NOT NULL,
        iteration_count INTEGER NOT NULL DEFAULT 0,
        started_at TEXT NOT NULL,
        finished_at TEXT,
        error_code TEXT,
        FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE SET NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_agent_runs_started ON agent_runs(started_at DESC)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tool_permissions (
        capability TEXT PRIMARY KEY,
        granted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS tool_audit_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        request_id TEXT NOT NULL,
        origin TEXT NOT NULL,
        tool_name TEXT NOT NULL,
        risk TEXT NOT NULL,
        arguments_redacted TEXT NOT NULL DEFAULT '{}',
        decision TEXT NOT NULL,
        status TEXT NOT NULL,
        started_at TEXT NOT NULL,
        finished_at TEXT,
        error_code TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_tool_audit_time ON tool_audit_events(started_at DESC)',
    );
  }

  // ═══════════════════════════════════════
  // 配置操作（CONFIG）
  // ═══════════════════════════════════════

  /// 获取所有配置 → Map<key, value>
  static Future<Map<String, String>> getConfig() async {
    final db = await database;
    final rows = await db.query('config');
    return {for (var r in rows) r['key'] as String: r['value'] as String};
  }

  /// 写入/更新配置 — INSERT OR REPLACE实现幂等
  static Future<void> setConfig(String key, String value) async {
    final db = await database;
    await db.rawInsert(
      'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)',
      [key, value],
    );
  }

  /// Atomically claims the next proactive-message slot across the foreground
  /// UI isolate, WorkManager and the short-interval foreground-service isolate.
  /// A claimed slot is never replayed after a crash; the next attempt waits for
  /// the configured interval.
  static Future<bool> tryClaimProactiveTick({
    required DateTime now,
    required int intervalMinutes,
    bool force = false,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query('config');
      final config = {
        for (final row in rows) row['key'] as String: row['value'] as String,
      };
      if (config['proactive_enabled'] != 'true') return false;

      if (!force) {
        final claim = DateTime.tryParse(config['proactive_claim_at'] ?? '');
        final sent = DateTime.tryParse(config['last_proactive_sent_at'] ?? '');
        final latest = claim == null
            ? sent
            : sent == null || claim.isAfter(sent)
                ? claim
                : sent;
        final guardSeconds =
            (intervalMinutes * 60 - 30).clamp(30, 86400).toInt();
        if (latest != null &&
            now.difference(latest) < Duration(seconds: guardSeconds)) {
          return false;
        }
      }

      await txn.rawInsert(
        'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)',
        ['proactive_claim_at', now.toIso8601String()],
      );
      return true;
    });
  }

  /// Shows onboarding only for a genuinely blank installation. Existing users
  /// are marked complete without interrupting their next app launch.
  static Future<bool> shouldShowOnboarding() async {
    final config = await getConfig();
    if (config['onboarding_completed_v3'] == 'true') return false;
    final db = await database;
    final result = await db.rawQuery('''
      SELECT
        (SELECT COUNT(*) FROM messages) AS messages,
        (SELECT COUNT(*) FROM conversations) AS conversations,
        (SELECT COUNT(*) FROM global_memories) AS memories,
        (SELECT COUNT(*) FROM personas) AS personas
    ''');
    final row = result.first;
    final hasExistingData = (row['messages'] as int? ?? 0) > 0 ||
        (row['conversations'] as int? ?? 0) > 1 ||
        (row['memories'] as int? ?? 0) > 0 ||
        (row['personas'] as int? ?? 0) > 0;
    if (hasExistingData) {
      await setConfig('onboarding_completed_v3', 'true');
      return false;
    }
    return true;
  }

  static Future<void> completeOnboarding() =>
      setConfig('onboarding_completed_v3', 'true');

  static Future<void> startAgentRun({
    required String id,
    required int conversationId,
    required String origin,
  }) async {
    final db = await database;
    await db.insert('agent_runs', {
      'id': id,
      'conversation_id': conversationId,
      'origin': origin,
      'status': 'planning',
      'iteration_count': 0,
      'started_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<void> finishAgentRun({
    required String id,
    required String status,
    required int iterations,
    String? errorCode,
  }) async {
    final db = await database;
    await db.update(
      'agent_runs',
      {
        'status': status,
        'iteration_count': iterations,
        'finished_at': DateTime.now().toIso8601String(),
        'error_code': errorCode,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<List<Map<String, dynamic>>> getRecentAgentRuns({
    int limit = 30,
  }) async {
    final db = await database;
    return db.query(
      'agent_runs',
      orderBy: 'started_at DESC',
      limit: limit.clamp(1, 100),
    );
  }

  /// Returns only explicit choices. Missing rows intentionally mean allowed.
  static Future<Map<String, bool>> getToolPermissions() async {
    final db = await database;
    final rows = await db.query('tool_permissions');
    return {
      for (final row in rows)
        row['capability'] as String: (row['granted'] as int? ?? 0) == 1,
    };
  }

  static Future<void> setToolPermission(
    String capability, {
    required bool granted,
  }) async {
    final db = await database;
    await db.insert(
      'tool_permissions',
      {
        'capability': capability,
        'granted': granted ? 1 : 0,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<int> startToolAudit({
    required String requestId,
    required String origin,
    required String toolName,
    required String risk,
    required String argumentsRedacted,
    required String decision,
  }) async {
    final db = await database;
    return db.insert('tool_audit_events', {
      'request_id': requestId,
      'origin': origin,
      'tool_name': toolName,
      'risk': risk,
      'arguments_redacted': argumentsRedacted,
      'decision': decision,
      'status': 'running',
      'started_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<void> finishToolAudit({
    required int id,
    required String status,
    String? errorCode,
  }) async {
    final db = await database;
    await db.update(
      'tool_audit_events',
      {
        'status': status,
        'finished_at': DateTime.now().toIso8601String(),
        'error_code': errorCode,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<List<Map<String, dynamic>>> getRecentToolAudits(
      {int limit = 50}) async {
    final db = await database;
    return db.query(
      'tool_audit_events',
      orderBy: 'started_at DESC',
      limit: limit.clamp(1, 200),
    );
  }

  static Future<void> purgeExpiredToolAudits({int retentionDays = 7}) async {
    final db = await database;
    final cutoff = DateTime.now()
        .subtract(Duration(days: retentionDays.clamp(1, 30)))
        .toIso8601String();
    await db.delete(
      'tool_audit_events',
      where: 'started_at < ?',
      whereArgs: [cutoff],
    );
  }

  static Future<void> clearToolAudits() async {
    final db = await database;
    await db.delete('tool_audit_events');
  }

  // ═══════════════════════════════════════
  // 对话操作（CONVERSATIONS）
  // ═══════════════════════════════════════

  /// 获取所有对话列表 — 含消息计数，按更新时间倒序
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

  /// 创建新对话
  static Future<Conversation> createConversation({String title = '新对话'}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('conversations', {
      'title': title,
      'created_at': now,
      'updated_at': now,
    });
    return Conversation(
        id: id,
        title: title,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now());
  }

  static Future<void> updateConversationTitle(int id, String title) async {
    final db = await database;
    await db.update(
      'conversations',
      {'title': title, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 更新对话时间戳 — 用于排序（置顶最近活跃对话）
  static Future<void> touchConversation(int id) async {
    final db = await database;
    await db.update(
      'conversations',
      {'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 删除对话 — 级联删除关联消息（外键ON DELETE CASCADE）
  static Future<void> deleteConversation(int id) async {
    final db = await database;
    await db.delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  /// 获取当前活跃对话ID
  ///
  /// 策略：config表active_conversation → 第一个存在的对话 → 创建新对话
  static Future<int> getActiveConversationId() async {
    final c = await getConfig();
    final idStr = c['active_conversation'] ?? '';
    final id = int.tryParse(idStr);
    if (id != null && id > 0) return id;
    // 回退：取最早创建的对话
    final db = await database;
    final first = await db.query('conversations', orderBy: 'id ASC', limit: 1);
    if (first.isNotEmpty) {
      final fid = first.first['id'] as int;
      await setConfig('active_conversation', fid.toString());
      return fid;
    }
    // 无对话 → 创建一个
    final conv = await createConversation();
    await setConfig('active_conversation', conv.id.toString());
    return conv.id!;
  }

  static Future<void> setActiveConversation(int id) async {
    await setConfig('active_conversation', id.toString());
  }

  // ═══════════════════════════════════════
  // 消息操作（MESSAGES）
  // ═══════════════════════════════════════

  /// 获取指定对话的消息 — 按时间升序，默认50条
  static Future<List<Map<String, dynamic>>> getMessages(int conversationId,
      {int limit = 50}) async {
    final db = await database;
    return db.query(
      'messages',
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

  /// 全文搜索消息 — FTS5优先，失败回退LIKE
  ///
  /// ⚠️ FTS5特殊字符(* " ( ) + -)需转义，否则查询语法错误
  static Future<List<Map<String, dynamic>>> searchMessages(String query,
      {int limit = 20}) async {
    final db = await database;
    try {
      // 转义FTS5特殊字符 — 避免MATCH语法错误
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
      // FTS不可用 → LIKE回退（无索引，大数据量慢）
      return await db.rawQuery('''
        SELECT content, role, conversation_id, timestamp
        FROM messages
        WHERE content LIKE ?
        ORDER BY timestamp DESC
        LIMIT ?
      ''', ['%$query%', limit]);
    }
  }

  /// Token估算 — 中日韩文字~1.5token/字，ASCII~0.25token/字，+10%格式开销
  ///
  /// 用于context窗口预算判断，在发送API请求前评估是否超出模型上限
  /// Unicode范围覆盖：中日韩统一表意文字+扩展+兼容表意文字+谚文+标点
  static int estimateTokens(
      List<Map<String, dynamic>> messages, String systemPrompt) {
    int chars = systemPrompt.length;
    for (final m in messages) {
      chars += (m['content'] as String?)?.length ?? 0;
    }
    int cjk = 0;
    // 统计system prompt中的CJK字符数
    for (var i = 0; i < systemPrompt.length; i++) {
      final c = systemPrompt.codeUnitAt(i);
      if ((c >= 0x2E80 && c <= 0x2FDF) || // CJK部首
          (c >= 0x3000 && c <= 0x33FF) || // 标点+假名
          (c >= 0x3400 && c <= 0x4DBF) || // CJK扩展A
          (c >= 0x4E00 && c <= 0x9FFF) || // CJK统一表意
          (c >= 0xF900 && c <= 0xFAFF) || // CJK兼容
          (c >= 0xFE30 && c <= 0xFE4F) || // CJK兼容格式
          (c >= 0xAC00 && c <= 0xD7AF)) {
        // 谚文
        cjk++;
      }
    }
    // 统计消息中的CJK字符
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
    // CJK~1.5 + ASCII~0.25，+10%开销（special tokens/格式）
    return ((cjk * 1.5 + ascii * 0.25) * 1.1).round();
  }

  /// 按模型名返回上下文窗口大小
  ///
  /// ⚠️ 注意：匹配顺序很重要 — 先匹配更具体的模型（如deepseek-v4 1M），
  /// 再匹配通用前缀（doubao 128K），最后返回默认值131072
  static int contextWindow(String model) {
    final m = model.toLowerCase();
    // 1M context模型
    if (m.contains('deepseek-v4')) return 1048576;
    if (m.contains('doubao-seed-2')) return 1048576;
    // 128K/131K
    if (m.contains('deepseek-reasoner') || m.contains('r1')) return 131072;
    if (m.contains('doubao-seed-1.6')) return 131072;
    if (m.contains('doubao') || m.contains('seed')) return 131072;
    if (m.contains('gpt-4o')) return 128000;
    // 200K
    if (m.contains('claude-3.5') || m.contains('claude-4')) return 200000;
    if (m.contains('claude')) return 200000;
    // 旧模型
    if (m.contains('gpt-4')) return 8192;
    if (m.contains('qwen')) return 32768;
    return 131072; // 默认
  }

  // ═══════════════════════════════════════
  // 人格操作（PERSONAS）
  // ═══════════════════════════════════════

  static Future<List<Persona>> getPersonas() async {
    final db = await database;
    final rows = await db.query('personas', orderBy: 'created_at ASC');
    return rows.map((r) => Persona.fromMap(r)).toList();
  }

  static Future<Persona> createPersona(
      {required String name, String prompt = ''}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final id = await db.insert('personas', {
      'name': name,
      'prompt': prompt,
      'active': 0,
      'created_at': now,
    });
    return Persona(
        id: id,
        name: name,
        prompt: prompt,
        active: false,
        createdAt: DateTime.now());
  }

  static Future<void> updatePersona(int id,
      {String? name, String? prompt}) async {
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

  /// 激活指定人格 — 先全部置0再激活目标，保证仅一个人格active
  /// id=null → 全部置0（回退到基底人格）
  static Future<void> activatePersona(int? id) async {
    final db = await database;
    await db.update('personas', {'active': 0});
    if (id != null) {
      await db.update('personas', {'active': 1},
          where: 'id = ?', whereArgs: [id]);
    }
  }

  static Future<Persona?> getActivePersona() async {
    final db = await database;
    final rows = await db.query('personas', where: 'active = 1', limit: 1);
    if (rows.isEmpty) return null;
    return Persona.fromMap(rows.first);
  }

  // ═══════════════════════════════════════
  // 全局记忆（GLOBAL MEMORIES）
  // ═══════════════════════════════════════

  /// 获取所有全局记忆 → 按分类分组的Map
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

  /// 搜索全局记忆 — LIKE模糊匹配
  static Future<Map<String, List<String>>> searchGlobalMemories(
      String query) async {
    final db = await database;
    final rows = await db.query(
      'global_memories',
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

  /// 保存全局记忆 — 先查重（同分类+同内容），再插入
  static Future<void> saveGlobalMemory({
    required String category,
    required String content,
    int? sourceConversationId,
  }) async {
    final db = await database;
    // 去重检查 — 完全相同的记忆不重复存储
    final existing = await db.query(
      'global_memories',
      where: 'category = ? AND content = ?',
      whereArgs: [category, content],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    await db.rawInsert(
      'INSERT INTO global_memories (category, content, source_conversation_id, created_at) VALUES (?, ?, ?, ?)',
      [
        category,
        content,
        sourceConversationId,
        DateTime.now().toIso8601String()
      ],
    );
  }

  static Future<void> clearGlobalMemories() async {
    final db = await database;
    await db.delete('global_memories');
  }

  // ═══════════════════════════════════════
  // 技能操作（SKILLS）
  // ═══════════════════════════════════════

  /// 获取已启用的技能 → 按优先级降序+时间升序
  static Future<List<Map<String, dynamic>>> getEnabledSkills() async {
    final db = await database;
    return db.query(
      'skills',
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
    await db.update('skills', {'enabled': enable ? 1 : 0},
        where: 'name = ?', whereArgs: [name]);
  }

  /// 添加/更新技能 — INSERT OR REPLACE实现幂等
  static Future<void> addSkill(String name, String content,
      {int priority = 0}) async {
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

  /// 转义FTS5查询中的特殊字符 → 去除*"()+-
  ///
  /// FTS5将这些字符视为操作符，未转义会导致MATCH语法错误
  static String _escapeFts5(String query) {
    // 剥离所有FTS5特殊字符 — 保持查询简单安全
    return query.replaceAll(RegExp(r'[*\"()+\\-]'), '').trim();
  }

  // ═══════════════════════════════════════
  // 语音配置操作（VOICE PROFILES）
  // ═══════════════════════════════════════

  static Future<List<Map<String, dynamic>>> getVoiceProfiles() async {
    final db = await database;
    return db.query('voice_profiles', orderBy: 'created_at ASC');
  }

  static Future<void> createVoiceProfile({
    required String name,
    String voiceId = 'zh-CN-XiaoxiaoNeural',
    double pitch = 0.0,
    double rate = 1.0,
    double volume = 1.0,
    String locale = 'zh-CN',
    DateTime? createdAt,
  }) async {
    final db = await database;
    await db.insert('voice_profiles', {
      'name': name,
      'voice_id': voiceId,
      'pitch': pitch,
      'rate': rate,
      'volume': volume,
      'locale': locale,
      'active': 0,
      'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
    });
  }

  /// 激活语音配置 — 先全部置0再激活目标
  static Future<void> activateVoiceProfile(int? id) async {
    final db = await database;
    await db.update('voice_profiles', {'active': 0});
    if (id != null) {
      await db.update('voice_profiles', {'active': 1},
          where: 'id = ?', whereArgs: [id]);
    }
  }

  static Future<void> deleteVoiceProfile(int id) async {
    final db = await database;
    await db.delete('voice_profiles', where: 'id = ?', whereArgs: [id]);
  }
}
