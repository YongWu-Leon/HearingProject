import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

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

  Future<Database> get _handle async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      p.join(dir.path, 'hearing_results.db'),
      version: 3,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE tests (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            node_id       TEXT    NOT NULL,
            patient_id    INTEGER,
            seq           INTEGER NOT NULL,
            freq_hz       REAL    NOT NULL,
            ear           TEXT    NOT NULL,
            start_ts      INTEGER NOT NULL,
            end_ts        INTEGER,
            reason        TEXT,
            threshold_db  REAL,
            ambient_db    REAL,
            ambient_over  INTEGER
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
        await db.execute('CREATE INDEX idx_tests_node ON tests (node_id, start_ts DESC)');
        await db.execute('CREATE INDEX idx_steps_test ON steps (test_id, idx)');
      },
      // v2 adds patient grouping. Existing rows get a NULL patient_id, which the
      // model reads as group 0 (legacy / ungrouped). ADD COLUMN is non-destructive.
      onUpgrade: (db, oldV, _) async {
        if (oldV < 2) {
          await db.execute('ALTER TABLE tests ADD COLUMN patient_id INTEGER');
        }
        // v3 records how loud the room was during each test. Existing rows get
        // NULL, which reads back as "not measured" rather than as "it was quiet".
        if (oldV < 3) {
          await db.execute('ALTER TABLE tests ADD COLUMN ambient_db REAL');
          await db.execute('ALTER TABLE tests ADD COLUMN ambient_over INTEGER');
        }
      },
    );
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
          'Change,Remaining_s,Reason,Threshold_dB,Ambient_dB,Ambient_over_limit');
    for (final t in tests) {
      final threshold = t.thresholdDb?.toStringAsFixed(1) ?? '';
      // Ambient columns repeat on the group's last line only, beside the
      // threshold they qualify, so one test still reads as one result.
      final ambient = t.ambientPeakDb?.toStringAsFixed(1) ?? '';
      final ambientOver = t.ambientPeakDb == null
          ? ''
          : (t.ambientOverLimit ? 'yes' : 'no');
      if (t.steps.isEmpty) {
        b.writeln('${t.nodeId},${t.seq},${_iso(t.startTs)},'
            '${t.freqHz.toStringAsFixed(0)},${t.ear},,,,,'
            '${t.reason ?? ''},$threshold,$ambient,$ambientOver');
        continue;
      }
      for (final s in t.steps) {
        b.writeln('${t.nodeId},${t.seq},${_iso(s.ts)},'
            '${t.freqHz.toStringAsFixed(0)},${t.ear},${s.index},'
            '${s.db.toStringAsFixed(1)},${stepFromLabel(s.from)},'
            '${s.remainingS.toStringAsFixed(1)},'
            '${s.index == t.steps.length - 1 ? (t.reason ?? '') : ''},'
            '${s.index == t.steps.length - 1 ? threshold : ''},'
            '${s.index == t.steps.length - 1 ? ambient : ''},'
            '${s.index == t.steps.length - 1 ? ambientOver : ''}');
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
