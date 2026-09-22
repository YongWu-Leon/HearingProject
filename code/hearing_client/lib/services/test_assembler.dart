import '../models/node_session.dart';

/// Turns one node's message stream into a stored test record.
///
/// Kept apart from WsServer's socket plumbing so it can be tested without a
/// WebSocket or database.
///
/// The node reports each level as it CLOSES, not as it opens: a
/// volume_changed message carries the level that just ended (dB + seconds
/// remaining) plus the level the subject moved to. So every message finalises
/// the previous row and opens the next; tone_done finalises the last row with
/// 0 s left, making its level the threshold.
class TestAssembler {
  TestRecord? _pending;
  final List<TestStep> _steps = [];

  bool get active => _pending != null;
  int? get seq => _pending?.seq;
  List<TestStep> get steps => List.unmodifiable(_steps);

  /// Called when the app sends play_tone.
  void begin({
    required String nodeId,
    int patientId = 0,
    required int seq,
    required double freqHz,
    required String ear,
  }) {
    _pending = TestRecord(
      nodeId: nodeId,
      patientId: patientId,
      seq: seq,
      freqHz: freqHz,
      ear: ear,
      startTs: DateTime.now(),
    );
    _steps.clear();
  }

  /// The node reports the level it actually opened with, which is authoritative
  /// over what we asked for (the node clamps to its own dB floor/ceiling).
  void onToneStarted({required int? seq, required double? db}) {
    if (!_matches(seq) || db == null) return;
    _steps
      ..clear()
      ..add(TestStep(
        index: 0,
        db: db,
        linear: 0,
        from: StepFrom.init,
        remainingS: 0,
        ts: DateTime.now(),
      ));
  }

  /// The subject pressed X or Y.
  void onVolumeChanged({
    required int? seq,
    required double? segDb,
    required String? segFrom,
    required double segRemainingS,
    required double? currentDb,
    required double? currentLinear,
    required String? button,
  }) {
    if (!_matches(seq) || segDb == null || currentDb == null) return;

    if (_steps.isEmpty) {
      // tone_started never arrived; seg_from covers how the first level was reached.
      _steps.add(TestStep(
        index: 0,
        db: segDb,
        linear: 0,
        from: stepFromWire(segFrom),
        remainingS: segRemainingS,
        ts: DateTime.now(),
      ));
    } else {
      // Close the open row with the node's account.
      final open = _steps.last;
      _steps[_steps.length - 1] = TestStep(
        index: open.index,
        db: segDb,
        linear: open.linear,
        from: open.from,
        remainingS: segRemainingS,
        ts: open.ts,
      );
    }

    // Open the row for the new level; remaining_s stays 0 until it's closed.
    _steps.add(TestStep(
      index: _steps.length,
      db: currentDb,
      linear: currentLinear ?? 0,
      from: button == 'X' ? StepFrom.down : StepFrom.up,
      remainingS: 0,
      ts: DateTime.now(),
    ));
  }

  /// The tone ended. Returns the finished record to store, or null if this
  /// message belongs to a test we are not tracking.
  TestRecord? onToneDone({
    required int? seq,
    required String reason,
    required double? finalDb,
    required double? finalLinear,
    required double segRemainingS,
  }) {
    if (!_matches(seq)) return null;

    if (_steps.isNotEmpty && finalDb != null) {
      final open = _steps.last;
      _steps[_steps.length - 1] = TestStep(
        index: open.index,
        db: finalDb,
        linear: finalLinear ?? open.linear,
        from: open.from,
        remainingS: segRemainingS,
        ts: open.ts,
      );
    }
    // Only a countdown that expired naturally yields a threshold.
    return _finish(reason, reason == 'completed' ? finalDb : null);
  }

  /// Link dropped or safety-net timeout fired. Keep what was reached, but not
  /// as a threshold.
  TestRecord? abandon(String reason) {
    if (!active) return null;
    return _finish(reason, null);
  }

  TestRecord? _finish(String reason, double? thresholdDb) {
    final pending = _pending;
    if (pending == null) return null;
    final record = pending.copyWith(
      endTs: DateTime.now(),
      reason: reason,
      thresholdDb: thresholdDb,
      steps: List.of(_steps),
    );
    _pending = null;
    _steps.clear();
    return record;
  }

  void reset() {
    _pending = null;
    _steps.clear();
  }

  /// Guards against a late message from a previous test (seq is phone-generated,
  /// echoed by the node).
  bool _matches(int? seq) => _pending != null && seq != null && _pending!.seq == seq;
}
