import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solvhen/core/llm/llm_config_store.dart';
import 'package:solvhen/core/storage/secret_store.dart';
import 'package:solvhen/services/database_service.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  for (final version in [7, 8, 9, 10]) {
    test('v$version fixture upgrades without losing user data or plaintext key',
        () async {
      final temp = await Directory.systemTemp.createTemp('solvhen-v$version-');
      final path = '${temp.path}${Platform.pathSeparator}fixture.db';
      Database? upgraded;
      try {
        await _createFixture(path, version);
        upgraded = await DB.openDatabaseForTesting(path);
        DB.attachDatabaseForTesting(upgraded);

        expect(await upgraded.getVersion(), DB.schemaVersion);
        expect(await _count(upgraded, 'conversations'), 2);
        expect(await _count(upgraded, 'messages'), 3);
        expect(await _count(upgraded, 'personas'), 1);
        expect(await _count(upgraded, 'global_memories'), 2);
        expect(await _count(upgraded, 'memory_entries'), 2);
        expect(await _count(upgraded, 'config'), 3);
        expect(await _tableExists(upgraded, 'agent_runs'), isTrue);
        expect(await _tableExists(upgraded, 'tool_permissions'), isTrue);
        expect(await _tableExists(upgraded, 'tool_audit_events'), isTrue);

        final secrets = _MemorySecretStore();
        await LlmConfigStore(secrets: secrets).migrateLegacySecrets();
        final config = await DB.getConfig();
        expect(config['api_key'], isEmpty);
        expect(
            await secrets.read(SecretKeys.apiKey), 'legacy-secret-v$version');
        expect(await _count(upgraded, 'config'), 3);
      } finally {
        DB.detachDatabaseForTesting();
        await upgraded?.close();
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    });
  }
}

Future<void> _createFixture(String path, int version) async {
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE conversations (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            consolidated_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id INTEGER NOT NULL,
            content TEXT NOT NULL,
            role TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            token_count INTEGER DEFAULT 0,
            tool_call_id TEXT,
            tool_calls_json TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE personas (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            prompt TEXT NOT NULL DEFAULT '',
            active INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        await db.execute('''
          CREATE TABLE global_memories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            category TEXT NOT NULL,
            content TEXT NOT NULL,
            source_conversation_id INTEGER,
            created_at TEXT NOT NULL
          )
        ''');
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
        if (version >= 8) await _createVoiceFixture(db, version);
        if (version >= 10) await _createMemoryFixture(db);

        const now = '2026-01-01T00:00:00.000Z';
        await db.insert('conversations', {
          'id': 1,
          'title': '旧对话一',
          'created_at': now,
          'updated_at': now,
        });
        await db.insert('conversations', {
          'id': 2,
          'title': '旧对话二',
          'created_at': now,
          'updated_at': now,
        });
        for (var index = 0; index < 3; index++) {
          await db.insert('messages', {
            'conversation_id': index == 2 ? 2 : 1,
            'content': '旧消息 $index',
            'role': index.isEven ? 'user' : 'assistant',
            'timestamp': now,
          });
        }
        await db.insert('personas', {
          'name': '旧人格',
          'prompt': '保留这段人格',
          'active': 1,
          'created_at': now,
        });
        await db.insert('config', {
          'key': 'api_key',
          'value': 'legacy-secret-v$version',
        });
        await db.insert('config', {'key': 'model', 'value': 'legacy-model'});
        await db.insert('config', {
          'key': 'active_conversation',
          'value': '2',
        });
        for (var index = 0; index < 2; index++) {
          await db.insert('global_memories', {
            'category': index == 0 ? 'fact' : 'preference',
            'content': '旧记忆 $index',
            'source_conversation_id': 1,
            'created_at': now,
          });
        }
        if (version >= 10) {
          for (var index = 0; index < 2; index++) {
            await db.insert('memory_entries', {
              'category': index == 0 ? 'fact' : 'preference',
              'content': '旧重型记忆 $index',
              'importance': 0.5,
              'access_count': 1,
              'source_conversation_id': 1,
              'created_at': now,
              'updated_at': now,
            });
          }
        }
      },
    ),
  );
  await db.close();
}

Future<void> _createVoiceFixture(Database db, int version) async {
  final voiceId = version >= 9
      ? "voice_id TEXT NOT NULL DEFAULT 'zh-CN-XiaoxiaoNeural',"
      : '';
  await db.execute('''
    CREATE TABLE voice_profiles (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      $voiceId
      pitch REAL NOT NULL DEFAULT 0.0,
      rate REAL NOT NULL DEFAULT 1.0,
      volume REAL NOT NULL DEFAULT 1.0,
      locale TEXT NOT NULL DEFAULT 'zh-CN',
      active INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL
    )
  ''');
}

Future<void> _createMemoryFixture(Database db) async {
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
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE memory_links (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      source_id INTEGER NOT NULL,
      target_id INTEGER NOT NULL,
      relation TEXT NOT NULL DEFAULT 'related_to',
      strength REAL NOT NULL DEFAULT 0.5,
      created_at TEXT NOT NULL
    )
  ''');
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
      created_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE working_memory (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      conversation_id INTEGER NOT NULL,
      turn_index INTEGER NOT NULL,
      user_msg TEXT NOT NULL,
      assistant_msg TEXT NOT NULL,
      key_points TEXT,
      created_at TEXT NOT NULL
    )
  ''');
}

Future<int> _count(Database db, String table) async =>
    Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM $table')) ??
    0;

Future<bool> _tableExists(Database db, String table) async => (await db.query(
      'sqlite_master',
      columns: const ['name'],
      where: 'type = ? AND name = ?',
      whereArgs: ['table', table],
      limit: 1,
    ))
        .isNotEmpty;

class _MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
