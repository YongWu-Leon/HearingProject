import 'package:web_socket_channel/web_socket_channel.dart';

import '../services/test_assembler.dart';

/// Nodes the operator expects to exist. A card is shown for each of these from
/// the moment the app starts, greyed out until it registers, so a board that is
/// powered down or not yet deployed is visibly absent rather than silently
/// missing from the list.
///
/// This is only a display roster. A node that registers with an id not on this
/// list still gets a card automatically, so adding a fourth board needs no code
/// change -- listing it here just means it shows as offline beforehand.
const kExpectedNodes = ['node01', 'node02', 'node03'];

/// A node that has not sent a heartbeat for this long counts as offline. Nodes
/// beat every 5 s, so this tolerates two missed beats before raising the alarm.
const kHeartbeatTimeout = Duration(seconds: 15);

/// How long the app waits for tone_done before re-enabling Play on its own.
/// The app deliberately runs no countdown of its own -- the node owns the clock,
/// because every X/Y press restarts it. This is only a safety net for a node that
/// dies mid-tone, and it matches the node's own MAX_TONE_TOTAL_SEC ceiling.
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
///
/// [remainingS] is how much of the 15 s countdown was still on the clock when
/// this level ended, i.e. how long it had been held before they changed it. The
/// last step of a test always ends at 0 -- the countdown ran out, which is what
/// makes its level the threshold.
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

  /// Groups the tests taken on one node into one patient/session. Every test
  /// between two "new patient" marks shares this value (the mark's timestamp),
  /// so the audiogram draws one chart per patient instead of mixing them. 0 for
  /// legacy rows saved before grouping existed.
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

  /// Loudest ambient level measured while this test ran, and whether it went
  /// over the configured limit. Recorded rather than enforced: a portable
  /// screener has no sound booth, so the honest thing is to say how quiet the
  /// room actually was and let the analysis decide what to do about it.
  /// Null on rows saved before ambient monitoring existed.
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

/// Everything the app knows about one node: its link state, the parameters the
/// operator has dialled in for it, and what it is doing right now.
///
/// Each node carries its OWN frequency / volume / ear, which is what lets three
/// nodes run different tones at the same time.
class NodeSession {
  final String nodeId;
  WebSocketChannel? channel;

  // --- reported by the node ---
  String hw = '?';
  String audio = '?';
  String fwVersion = '?';
  String state = 'IDLE'; // IDLE | PLAYING
  DateTime lastSeen = DateTime.now();

  /// False for a roster entry that has never connected. Distinguishes "not
  /// deployed yet" from "was here and dropped", which read very differently to
  /// whoever is running the test.
  bool everRegistered = false;

  double remainingS = 0;

  // --- operator-set parameters, per node ---

  /// Marks the start of the current patient/session on this node. Every completed
  /// test stamps this value, so the audiogram can group tests by patient. Set
  /// once when the session starts and advanced only by "New patient".
  int patientGroupTs = DateTime.now().millisecondsSinceEpoch;

  void startNewPatient() =>
      patientGroupTs = DateTime.now().millisecondsSinceEpoch;

  double frequency = 1000;
  int freqSliderIndex = 4;

  /// The playback level in dB -- one merged value. When idle it is the operator's
  /// set point (the slider / text box control it, and it is what Play sends). When
  /// a tone is playing, node messages update it on every X/Y press, so the same
  /// control tracks the subject live -- which is why there is no separate
  /// "subject level" readout any more. After a tone ends it holds the threshold.
  double levelDb = -10.0;

  String ear = 'both';

  // --- UI state ---
  bool expanded = false;
  bool selected = true;

  /// True from the moment play_tone is sent until tone_done arrives (or the
  /// timeout fires). The Play button is disabled while it is set -- the app does
  /// not run its own countdown, it waits to be told.
  bool awaitingResult = false;
  bool timedOut = false;
  int? activeSeq;
  DateTime? playSentAt;

  /// Builds the test record from this node's message stream. See TestAssembler.
  final TestAssembler assembler = TestAssembler();

  /// Last value [online] reported, so the 1 Hz housekeeping tick can repaint on
  /// the transition instead of repainting unconditionally every second.
  bool lastKnownOnline = false;

  NodeSession(this.nodeId);

  /// Connected AND still sending heartbeats. Both halves matter: a phone that
  /// walks out of range leaves a half-open socket that looks alive until the
  /// heartbeats stop arriving.
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
