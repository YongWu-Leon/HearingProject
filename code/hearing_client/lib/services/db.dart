import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../models/node_session.dart';

/// Authoritative result storage.
///
/// This is where test data actually lives. The nodes each keep a CSV as an
/// offline backup, but that is a fallback for link outages only -- what the
/// operator reads, exports and trusts is this database.
///
/// Two tables, which is exactly how the records view renders:
///   tests  one row per tone = one thick-bordered group
///   steps  one row per level the subject held = one coloured line in that group
class Db {
  Db._();
  static final Db instance = Db._();

  Database? _db;

  // Encryption at rest: the SQLite file is opened through SQLCipher with a
  // random 256-bit key kept in the platform secure store (Android Keystore /
  // iOS Keychain). It is transparent -- no password prompt and no change to any
  // read/write path -- so subject data is unreadable if the DB file is copied
  // off the device. The exported CSV stays plaintext on purpose: export exists
  // to hand results to analysis tools.
  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  static const _kDbKey = 'db_key_v1';
  static const _kEncrypted = 'db_encrypted_v1';

  Future<Database> get _handle async => _db ??= await _open();

  /// Read the DB key from secure storage, generating one on first run.
  Future<String> _dbKey() async {
    var k = await _secure.read(key: _kDbKey);
    if (k == null || k.isEmpty) {
      final rnd = Random.secure();
      k = List<int>.generate(32, (_) => rnd.nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await _secure.write(key: _kDbKey, value: k);
    }
    return k;
  }

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'hearing_results.db');
    final key = await _dbKey();
    final encrypted = (await _secure.read(key: _kEncrypted)) == '1';

    // A database written by an earlier, unencrypted build is migrated in place
    // the first time this build opens it, so existing records are preserved.
    if (!encrypted && await File(path).exists()) {
      final ok = await _migrateToEncrypted(path, key);
      if (!ok) {
        // Never lose access to the data: keep working on the plaintext file and
        // retry the migration on the next launch.
        return openDatabase(path, version: 1, onCreate: _createSchema);
      }
    }

    final db = await openDatabase(path,
        password: key, version: 1, onCreate: _createSchema);
    await _secure.write(key: _kEncrypted, value: '1');
    return db;
  }

  /// Copy a plaintext database into a new SQLCipher-encrypted file and swap it
  /// in, keeping a .bak of the original as a safety net. Returns false (leaving
  /// the plaintext file untouched) if anything goes wrong.
  Future<bool> _migrateToEncrypted(String path, String key) async {
    final encPath = '$path.enc';
    try {
      await File(path).copy('$path.bak');
      final enc = File(encPath);
      if (await enc.exists()) await enc.delete();

      final plain = await openDatabase(path); // no password = plaintext
      await plain.execute("ATTACH DATABASE '$encPath' AS enc KEY '$key'");
      await plain.rawQuery("SELECT sqlcipher_export('enc')");
      await plain.execute('DETACH DATABASE enc');
      await plain.close();

      await File(path).delete();
      await enc.rename(path);
      return true;
    } catch (e) {
      debugPrint('[db] encryption migration failed, staying plaintext: $e');
      final enc = File(encPath);
      if (await enc.exists()) await enc.delete();
      return false;
    }
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tests (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        node_id       TEXT    NOT NULL,
        seq           INTEGER NOT NULL,
        freq_hz       REAL    NOT NULL,
        ear           TEXT    NOT NULL,
        start_ts      INTEGER NOT NULL,
        end_ts        INTEGER,
        reason        TEXT,
        threshold_db  REAL
      )
    ''');
    await db.execute('''
      CREATE TABLE steps (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        test_id      INTEGER NOT NULL,
        idx          INTEGER NOT NULL,
        db           REAL    NOT NULL,
        linear       REAL,
        from_btn     TEXT    NOT NULL,
        remaining_s  REAL,
        ts           INTEGER NOT NULL,
        FOREIGN KEY (test_id) REFERENCES tests (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_tests_node ON tests (node_id, start_ts DESC)');
    await db.execute('CREATE INDEX idx_steps_test ON steps (test_id, idx)');
  }

  // ---------- writes ----------

  /// Persist a finished test and its steps in one transaction, so a group is
  /// never half-written if the app is killed mid-save.
  Future<int> saveTest(TestRecord test) async {
    final db = await _handle;
    return db.transaction((txn) async {
      final testId = await txn.insert('tests', test.toDbMap());
      for (final s in test.steps) {
        await txn.insert('steps', s.toDbMap(testId));
      }
      return testId;
    });
  }

  // ---------- reads ----------

  /// Tests newest first, each with its steps attached.
  /// [nodeId] null means every node.
  Future<List<TestRecord>> loadTests({String? nodeId, int limit = 500}) async {
    final db = await _handle;
    final rows = await db.query(
      'tests',
      where: nodeId == null ? null : 'node_id = ?',
      whereArgs: nodeId == null ? null : [nodeId],
      orderBy: 'start_ts DESC',
      limit: limit,
    );
    if (rows.isEmpty) return [];

    final ids = rows.map((r) => r['id'] as int).toList();
    final stepRows = await db.query(
      'steps',
      where: 'test_id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
      orderBy: 'test_id, idx',
    );
    final byTest = <int, List<TestStep>>{};
    for (final r in stepRows) {
      byTest.putIfAbsent(r['test_id'] as int, () => []).add(TestStep.fromDbMap(r));
    }

    return [
      for (final r in rows)
        TestRecord.fromDbMap(r, steps: byTest[r['id'] as int] ?? const []),
    ];
  }

  /// Node ids that appear anywhere in the history, so records stay reachable for
  /// a node that is currently offline.
  Future<List<String>> knownNodeIds() async {
    final db = await _handle;
    final rows = await db.rawQuery(
        'SELECT DISTINCT node_id FROM tests ORDER BY node_id');
    return [for (final r in rows) r['node_id'] as String];
  }

  Future<int> testCount({String? nodeId}) async {
    final db = await _handle;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) c FROM tests${nodeId == null ? '' : ' WHERE node_id = ?'}',
      nodeId == null ? null : [nodeId],
    );
    return (rows.first['c'] as num).toInt();
  }

  // ---------- delete ----------

  Future<void> deleteAll({String? nodeId}) async {
    final db = await _handle;
    await db.transaction((txn) async {
      if (nodeId == null) {
        await txn.delete('steps');
        await txn.delete('tests');
      } else {
        await txn.rawDelete(
          'DELETE FROM steps WHERE test_id IN (SELECT id FROM tests WHERE node_id = ?)',
          [nodeId],
        );
        await txn.delete('tests', where: 'node_id = ?', whereArgs: [nodeId]);
      }
    });
  }

  // ---------- export ----------

  /// Flatten tests + steps into one CSV, one line per step, so the file carries
  /// the same information the records view shows.
  String buildCsv(List<TestRecord> tests) {
    final b = StringBuffer()
      ..writeln('NodeID,Seq,Timestamp,Frequency_Hz,Ear,Step,Level_dB,'
          'Change,Remaining_s,Reason,Threshold_dB');
    for (final t in tests) {
      final threshold = t.thresholdDb?.toStringAsFixed(1) ?? '';
      if (t.steps.isEmpty) {
        b.writeln('${t.nodeId},${t.seq},${_iso(t.startTs)},'
            '${t.freqHz.toStringAsFixed(0)},${t.ear},,,,,'
            '${t.reason ?? ''},$threshold');
        continue;
      }
      for (final s in t.steps) {
        b.writeln('${t.nodeId},${t.seq},${_iso(s.ts)},'
            '${t.freqHz.toStringAsFixed(0)},${t.ear},${s.index},'
            '${s.db.toStringAsFixed(1)},${stepFromLabel(s.from)},'
            '${s.remainingS.toStringAsFixed(1)},'
            '${s.index == t.steps.length - 1 ? (t.reason ?? '') : ''},'
            '${s.index == t.steps.length - 1 ? threshold : ''}');
      }
    }
    return b.toString();
  }

  /// Write the CSV to a temp file and return it, ready to hand to the share sheet.
  Future<File> writeCsvFile(String csv, {String? nodeId}) async {
    final dir = await getTemporaryDirectory();
    final stamp = _iso(DateTime.now()).replaceAll(RegExp(r'[: ]'), '-');
    final name = 'hearing_${nodeId ?? 'all'}_$stamp.csv';
    final f = File(p.join(dir.path, name));
    return f.writeAsString(csv);
  }

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';
}
