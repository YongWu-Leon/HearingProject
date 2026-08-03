import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_client/models/node_session.dart';

void main() {
  group('TestRecord ambient fields', () {
    TestRecord base() => TestRecord(
          nodeId: 'node01',
          seq: 1,
          freqHz: 1000,
          ear: 'both',
          startTs: DateTime.fromMillisecondsSinceEpoch(0),
        );

    test('default to not measured rather than to quiet', () {
      final r = base();
      expect(r.ambientPeakDb, isNull);
      expect(r.ambientOverLimit, isFalse);
    });

    test('survive a round trip through the database map', () {
      final r = base().copyWith(ambientPeakDb: 61.4, ambientOverLimit: true);
      final back = TestRecord.fromDbMap(r.toDbMap());
      expect(back.ambientPeakDb, closeTo(61.4, 0.001));
      expect(back.ambientOverLimit, isTrue);
    });

    test('a legacy row with no ambient columns reads as not measured', () {
      final legacy = <String, Object?>{
        'node_id': 'node01',
        'seq': 5,
        'freq_hz': 1000.0,
        'ear': 'both',
        'start_ts': 0,
        'reason': 'completed',
        'threshold_db': -40.0,
        // ambient_db / ambient_over absent, as on a pre-v3 database
      };
      final r = TestRecord.fromDbMap(legacy);
      expect(r.ambientPeakDb, isNull);
      expect(r.ambientOverLimit, isFalse);
    });

    test('a measured but quiet room is distinguishable from not measured', () {
      final quiet = base().copyWith(ambientPeakDb: 32.0);
      expect(quiet.ambientPeakDb, 32.0);
      expect(quiet.ambientOverLimit, isFalse);

      final unmeasured = base();
      expect(unmeasured.ambientPeakDb, isNull);
      // Both are "not over limit", so the peak is what tells them apart.
      expect(unmeasured.ambientOverLimit, quiet.ambientOverLimit);
    });
  });
}
