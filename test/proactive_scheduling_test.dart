import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:solvhen/services/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database database;

  setUp(() async {
    databaseFactory = databaseFactoryFfi;
    database = await DB.openDatabaseForTesting(inMemoryDatabasePath);
    DB.attachDatabaseForTesting(database);
    await DB.setConfig('proactive_enabled', 'true');
    await DB.setConfig('proactive_interval', '15');
  });

  tearDown(() async {
    DB.detachDatabaseForTesting();
    await database.close();
  });

  test('atomic proactive claim prevents duplicate isolates and crash replay',
      () async {
    final first = DateTime.utc(2026, 8, 9, 10);

    expect(
      await DB.tryClaimProactiveTick(
        now: first,
        intervalMinutes: 15,
      ),
      isTrue,
    );
    // Simulates a second isolate waking at the same time.
    expect(
      await DB.tryClaimProactiveTick(
        now: first.add(const Duration(seconds: 1)),
        intervalMinutes: 15,
      ),
      isFalse,
    );
    // No "sent" marker is written: a crash still must not replay the claim.
    expect(
      await DB.tryClaimProactiveTick(
        now: first.add(const Duration(minutes: 5)),
        intervalMinutes: 15,
      ),
      isFalse,
    );
    expect(
      await DB.tryClaimProactiveTick(
        now: first.add(const Duration(minutes: 15)),
        intervalMinutes: 15,
      ),
      isTrue,
    );
  });

  test('disabled proactive scheduling cannot claim a slot', () async {
    await DB.setConfig('proactive_enabled', 'false');

    expect(
      await DB.tryClaimProactiveTick(
        now: DateTime.utc(2026, 8, 9, 10),
        intervalMinutes: 1,
        force: true,
      ),
      isFalse,
    );
  });
}
