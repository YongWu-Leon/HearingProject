// Regression tests for how a node's message stream becomes a stored test.
//
// This is the fiddly part of the phone side. The node reports each level as it
// CLOSES, not as it opens: a volume_changed says "the level that just ended was
// X dB with Y seconds left, and the subject has now moved to Z dB". Getting that
// off by one would silently shift every level against its remaining time, and
// nothing would crash -- the records page would just be quietly wrong. Hence
// these tests.
import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_client/models/node_session.dart';
import 'package:hearing_client/services/test_assembler.dart';

void main() {
  late TestAssembler a;

  setUp(() {
    a = TestAssembler()
      ..begin(nodeId: 'node01', seq: 42, freqHz: 1000, ear: 'L');
  });

  test('a full hunt produces one row per level, in order, correctly coloured',
      () {
    // Mirrors a real session: start at -10.5, subject goes up, down, down, then
    // stops pressing and the countdown expires.
    a.onToneStarted(seq: 42, db: -10.5);
    a.onVolumeChanged(
        seq: 42, segDb: -10.5, segFrom: 'init', segRemainingS: 14.5,
        currentDb: -5.5, currentLinear: 0.53, button: 'Y');
    a.onVolumeChanged(
        seq: 42, segDb: -5.5, segFrom: 'Y', segRemainingS: 11.2,
        currentDb: -15.5, currentLinear: 0.17, button: 'X');
    a.onVolumeChanged(
        seq: 42, segDb: -15.5, segFrom: 'X', segRemainingS: 9.8,
        currentDb: -25.5, currentLinear: 0.05, button: 'X');

    final rec = a.onToneDone(
        seq: 42, reason: 'completed', finalDb: -25.5, finalLinear: 0.05,
        segRemainingS: 0.0);

    expect(rec, isNotNull);
    expect(rec!.steps, hasLength(4));

    // Level, how it was reached, and how long it was held before being changed.
    expect(rec.steps[0].db, -10.5);
    expect(rec.steps[0].from, StepFrom.init); // white row
    expect(rec.steps[0].remainingS, 14.5);

    expect(rec.steps[1].db, -5.5);
    expect(rec.steps[1].from, StepFrom.up); // light green
    expect(rec.steps[1].remainingS, 11.2);

    expect(rec.steps[2].db, -15.5);
    expect(rec.steps[2].from, StepFrom.down); // light red
    expect(rec.steps[2].remainingS, 9.8);

    // The last row is the countdown running out, so it always ends at 0.
    expect(rec.steps[3].db, -25.5);
    expect(rec.steps[3].from, StepFrom.down);
    expect(rec.steps[3].remainingS, 0.0);

    // ...and its level is the threshold.
    expect(rec.thresholdDb, -25.5);
    expect(rec.isComplete, isTrue);
    expect(rec.steps.map((s) => s.index), [0, 1, 2, 3]);
  });

  test('a tone with no presses at all still yields one row and a threshold', () {
    a.onToneStarted(seq: 42, db: -6.0);
    final rec = a.onToneDone(
        seq: 42, reason: 'completed', finalDb: -6.0, finalLinear: 0.5,
        segRemainingS: 0.0);

    expect(rec!.steps, hasLength(1));
    expect(rec.steps.single.from, StepFrom.init);
    expect(rec.thresholdDb, -6.0);
  });

  test('an operator stop records the levels but NOT a threshold', () {
    a.onToneStarted(seq: 42, db: -6.0);
    a.onVolumeChanged(
        seq: 42, segDb: -6.0, segFrom: 'init', segRemainingS: 12.0,
        currentDb: -16.0, currentLinear: 0.16, button: 'X');

    final rec = a.onToneDone(
        seq: 42, reason: 'stopped', finalDb: -16.0, finalLinear: 0.16,
        segRemainingS: 7.3);

    expect(rec!.steps, hasLength(2));
    expect(rec.steps.last.remainingS, 7.3, reason: 'stopped early, time was left');
    expect(rec.thresholdDb, isNull,
        reason: 'a tone cut short says nothing about where they would settle');
    expect(rec.isComplete, isFalse);
  });

  test('messages from a different seq are ignored', () {
    a.onToneStarted(seq: 42, db: -6.0);
    // A late message from the previous test on this node.
    a.onVolumeChanged(
        seq: 41, segDb: -99.0, segFrom: 'init', segRemainingS: 1.0,
        currentDb: -99.0, currentLinear: 0.0, button: 'X');

    expect(a.steps, hasLength(1));
    expect(a.steps.single.db, -6.0);
    expect(a.onToneDone(
        seq: 41, reason: 'completed', finalDb: -99, finalLinear: 0,
        segRemainingS: 0), isNull);
    expect(a.active, isTrue, reason: 'the real test must still be open');
  });

  test('a lost tone_started still produces a correct first row', () {
    // tone_started dropped; the first volume_changed carries the init level.
    a.onVolumeChanged(
        seq: 42, segDb: -6.0, segFrom: 'init', segRemainingS: 13.0,
        currentDb: -16.0, currentLinear: 0.16, button: 'X');

    expect(a.steps, hasLength(2));
    expect(a.steps[0].db, -6.0);
    expect(a.steps[0].from, StepFrom.init);
    expect(a.steps[0].remainingS, 13.0);
    expect(a.steps[1].from, StepFrom.down);
  });

  test('abandon keeps partial data but never invents a threshold', () {
    a.onToneStarted(seq: 42, db: -6.0);
    a.onVolumeChanged(
        seq: 42, segDb: -6.0, segFrom: 'init', segRemainingS: 10.0,
        currentDb: -16.0, currentLinear: 0.16, button: 'X');

    final rec = a.abandon('disconnected');
    expect(rec!.steps, hasLength(2));
    expect(rec.reason, 'disconnected');
    expect(rec.thresholdDb, isNull);
    expect(a.active, isFalse);
    expect(a.abandon('disconnected'), isNull, reason: 'nothing left to abandon');
  });

  test('a new test does not inherit the previous one\'s rows', () {
    a.onToneStarted(seq: 42, db: -6.0);
    a.onVolumeChanged(
        seq: 42, segDb: -6.0, segFrom: 'init', segRemainingS: 10.0,
        currentDb: -16.0, currentLinear: 0.16, button: 'X');
    a.onToneDone(
        seq: 42, reason: 'completed', finalDb: -16.0, finalLinear: 0.16,
        segRemainingS: 0);

    a.begin(nodeId: 'node01', seq: 43, freqHz: 2000, ear: 'R');
    a.onToneStarted(seq: 43, db: -6.0);
    final rec = a.onToneDone(
        seq: 43, reason: 'completed', finalDb: -6.0, finalLinear: 0.5,
        segRemainingS: 0);

    expect(rec!.steps, hasLength(1));
    expect(rec.seq, 43);
    expect(rec.freqHz, 2000);
    expect(rec.ear, 'R');
  });
}
