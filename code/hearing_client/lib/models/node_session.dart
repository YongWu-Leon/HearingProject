import 'package:web_socket_channel/web_socket_channel.dart';

import '../services/test_assembler.dart';

/// Nodes the operator expects to exist. Each gets a card from app start,
/// greyed out until it registers. Display roster only -- a node not listed
/// here still gets a card automatically when it registers.
const kExpectedNodes = ['node01', 'node02', 'node03'];

/// A node that has not sent a heartbeat for this long counts as offline. Nodes
/// beat every 5 s, so this tolerates two missed beats before raising the alarm.
const kHeartbeatTimeout = Duration(seconds: 15);

/// Fallback timeout to re-enable Play if tone_done never arrives (the node
/// owns the tone clock, not the app). Matches the node's MAX_TONE_TOTAL_SEC.
const kPlayTimeout = Duration(seconds: 120);

/// How a level was arrived at. Drives the row colour in the records view:
/// init = white, down = light red, up = light green.
enum StepFrom { init, down, up }

StepFrom stepFromWire(String? s) {
  switch (s) {
    case 'X':
      return StepFrom.down;
    case 'Y':
      return StepFrom.up;
    default:
      return StepFrom.init;
  }
}

String stepFromToWire(StepFrom f) {
  switch (f) {
    case StepFrom.down:
      return 'X';
    case StepFrom.up:
      return 'Y';
    case StepFrom.init:
      return 'init';
  }
}

String stepFromLabel(StepFrom f) {
  switch (f) {
    case StepFrom.down:
      return 'Lowered';
    case StepFrom.up:
      return 'Raised';
    case StepFrom.init:
      return 'Initial';
  }
}

/// One level the subject held during a test = one row in the records view.
/// [remainingS] is the countdown left when this level ended; the last step
/// always ends at 0, making its level the threshold.
class TestStep {
  final int index;
  final double db;
  final double linear;
  final StepFrom from;
  final double remainingS;
  final DateTime ts;

  const TestStep({
    required this.index,
    required this.db,
    required this.linear,
    required this.from,
    required this.remainingS,
    required this.ts,
  });

  Map<String, Object?> toDbMap(int testId) => {
        'test_id': testId,
        'idx': index,
        'db': db,
        'linear': linear,
        'from_btn': stepFromToWire(from),
        'remaining_s': remainingS,
        'ts': ts.millisecondsSinceEpoch,
      };

  static TestStep fromDbMap(Map<String, Object?> m) => TestStep(
        index: (m['idx'] as num).toInt(),
        db: (m['db'] as num).toDouble(),
        linear: (m['linear'] as num?)?.toDouble() ?? 0,
        from: stepFromWire(m['from_btn'] as String?),
        remainingS: (m['remaining_s'] as num?)?.toDouble() ?? 0,
        ts: DateTime.fromMillisecondsSinceEpoch((m['ts'] as num).toInt()),
      );
}

/// One complete test: a tone at one frequency, from the first level the operator
/// sent to the level the subject settled on. Rendered as one thick-bordered group.
class TestRecord {
  final int? id;
  final String nodeId;

  /// Groups tests into one patient/session (shared timestamp between "new
  /// patient" marks). 0 for legacy rows predating grouping.
  final int patientId;

  final int seq;
  final double freqHz;
  final String ear;
  final DateTime startTs;
  final DateTime? endTs;

  /// 'completed' = countdown expired, so [thresholdDb] is a real threshold.
  /// 'stopped'   = the operator ended it early; treat the level as provisional.
  final String? reason;
  final double? thresholdDb;

  /// Loudest ambient level during this test, and whether it exceeded the
  /// configured limit. Recorded, not enforced. Null on rows predating
  /// ambient monitoring.
  final double? ambientPeakDb;
  final bool ambientOverLimit;

  final List<TestStep> steps;

  const TestRecord({
    this.id,
    required this.nodeId,
    this.patientId = 0,
    required this.seq,
    required this.freqHz,
    required this.ear,
    required this.startTs,
    this.endTs,
    this.reason,
    this.thresholdDb,
    this.ambientPeakDb,
    this.ambientOverLimit = false,
    this.steps = const [],
  });

  bool get isComplete => reason == 'completed';

  TestRecord copyWith({
    int? id,
    DateTime? endTs,
    String? reason,
    double? thresholdDb,
    double? ambientPeakDb,
    bool? ambientOverLimit,
    List<TestStep>? steps,
  }) =>
      TestRecord(
        id: id ?? this.id,
        nodeId: nodeId,
        patientId: patientId,
        seq: seq,
        freqHz: freqHz,
        ear: ear,
        startTs: startTs,
        endTs: endTs ?? this.endTs,
        reason: reason ?? this.reason,
        thresholdDb: thresholdDb ?? this.thresholdDb,
        ambientPeakDb: ambientPeakDb ?? this.ambientPeakDb,
        ambientOverLimit: ambientOverLimit ?? this.ambientOverLimit,
        steps: steps ?? this.steps,
      );

  Map<String, Object?> toDbMap() => {
        if (id != null) 'id': id,
        'node_id': nodeId,
        'patient_id': patientId,
        'seq': seq,
        'freq_hz': freqHz,
        'ear': ear,
        'start_ts': startTs.millisecondsSinceEpoch,
        'end_ts': endTs?.millisecondsSinceEpoch,
        'reason': reason,
        'threshold_db': thresholdDb,
        'ambient_db': ambientPeakDb,
        'ambient_over': ambientOverLimit ? 1 : 0,
      };

  static TestRecord fromDbMap(Map<String, Object?> m,
          {List<TestStep> steps = const []}) =>
      TestRecord(
        id: (m['id'] as num?)?.toInt(),
        nodeId: m['node_id'] as String,
        patientId: (m['patient_id'] as num?)?.toInt() ?? 0,
        seq: (m['seq'] as num).toInt(),
        freqHz: (m['freq_hz'] as num).toDouble(),
        ear: m['ear'] as String? ?? 'both',
        startTs: DateTime.fromMillisecondsSinceEpoch((m['start_ts'] as num).toInt()),
        endTs: m['end_ts'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((m['end_ts'] as num).toInt()),
        reason: m['reason'] as String?,
        thresholdDb: (m['threshold_db'] as num?)?.toDouble(),
        ambientPeakDb: (m['ambient_db'] as num?)?.toDouble(),
        ambientOverLimit: ((m['ambient_over'] as num?)?.toInt() ?? 0) == 1,
        steps: steps,
      );
}

/// A line in the live event feed on the main screen.
class LiveEvent {
  final String nodeId;
  final int? seq;
  final String text;
  final StepFrom kind;
  final DateTime ts;

  LiveEvent(this.nodeId, this.seq, this.text, this.kind) : ts = DateTime.now();
}

/// Everything the app knows about one node: link state, operator-set
/// parameters, and current activity. Each node has its own frequency/volume/
/// ear, so nodes run independently.
class NodeSession {
  final String nodeId;
  WebSocketChannel? channel;

  // --- reported by the node ---
  String hw = '?';
  String audio = '?';
  String fwVersion = '?';
  String state = 'IDLE'; // IDLE | PLAYING
  DateTime lastSeen = DateTime.now();

  /// False for a roster entry that has never connected (vs. connected then
  /// dropped).
  bool everRegistered = false;

  double remainingS = 0;

  // --- operator-set parameters, per node ---

  /// Start of the current patient/session; stamped onto completed tests for
  /// audiogram grouping. Advanced only by "New patient".
  int patientGroupTs = DateTime.now().millisecondsSinceEpoch;

  void startNewPatient() =>
      patientGroupTs = DateTime.now().millisecondsSinceEpoch;

  double frequency = 1000;
  int freqSliderIndex = 4;

  /// Playback level in dB. Idle: operator's set point (sent by Play). Playing:
  /// updated live from the node on each X/Y press. After a tone ends: holds
  /// the threshold.
  double levelDb = -10.0;

  String ear = 'both';

  // --- UI state ---
  bool expanded = false;
  bool selected = true;

  /// True from play_tone until tone_done arrives or the timeout fires; Play
  /// stays disabled meanwhile.
  bool awaitingResult = false;
  bool timedOut = false;
  int? activeSeq;
  DateTime? playSentAt;

  /// Builds the test record from this node's message stream. See TestAssembler.
  final TestAssembler assembler = TestAssembler();

  /// Last value [online] reported, so the housekeeping tick repaints only on
  /// transitions.
  bool lastKnownOnline = false;

  NodeSession(this.nodeId);

  /// Connected AND still sending heartbeats -- a socket can look alive after
  /// the phone walks out of range until heartbeats stop.
  bool get online => channel != null && !staleFor(kHeartbeatTimeout);
  bool get isPlaying => state == 'PLAYING';

  bool staleFor(Duration d) => DateTime.now().difference(lastSeen) > d;

  void resetPlayback() {
    awaitingResult = false;
    activeSeq = null;
    playSentAt = null;
    assembler.reset();
    state = 'IDLE';
    remainingS = 0;
  }
}
