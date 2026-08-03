import 'dart:math' as math;

/// Which link timing a sample describes.
enum LatencyKind {
  /// Phone sends play_tone -> node's tone_started comes back. Measured entirely
  /// on the phone's clock, so it needs no clock agreement and is the most
  /// trustworthy figure. It is also what the operator actually feels: the delay
  /// between pressing Play and the tone existing.
  commandRoundTrip,

  /// Subject's X/Y press -> the phone has the event. One-way, so it only exists
  /// once the node's clock has been related to the phone's (see [ClockOffset]).
  buttonOneWay,

  /// The node's own measurement: press -> first audio chunk built at the new
  /// level. Node-local, so no clock agreement is involved.
  audioApply,
}

extension LatencyKindLabel on LatencyKind {
  String get label {
    switch (this) {
      case LatencyKind.commandRoundTrip:
        return 'Command round-trip';
      case LatencyKind.buttonOneWay:
        return 'Button to phone';
      case LatencyKind.audioApply:
        return 'Press to audio';
    }
  }

  String get csvKey {
    switch (this) {
      case LatencyKind.commandRoundTrip:
        return 'command_round_trip';
      case LatencyKind.buttonOneWay:
        return 'button_one_way';
      case LatencyKind.audioApply:
        return 'audio_apply';
    }
  }
}

/// Relates one node's monotonic clock to the phone's.
///
/// The two clocks share no epoch, so a node timestamp is meaningless on the
/// phone until the difference between them is known. A ping/pong exchange gives
/// it: the phone sends its own stamp, the node echoes that back beside its own,
/// and assuming the two legs of the round trip are roughly symmetric the node's
/// stamp corresponds to the midpoint of the exchange. Each new exchange refines
/// the estimate, and the one with the SHORTEST round trip is kept -- a fast
/// exchange had least room for asymmetry, so it carries the least error. (This
/// "keep the best round trip" rule is the same reason NTP prefers low-delay
/// samples.)
class ClockOffset {
  double? _offsetMs;
  double _bestRttMs = double.infinity;

  bool get known => _offsetMs != null;
  double? get offsetMs => _offsetMs;
  double get bestRttMs => _bestRttMs;

  /// Fold in one completed exchange. All arguments are in milliseconds.
  void update({
    required double sentAppMs,
    required double nodeMs,
    required double receivedAppMs,
  }) {
    final rtt = receivedAppMs - sentAppMs;
    if (rtt < 0) return;
    if (rtt >= _bestRttMs) return;
    _bestRttMs = rtt;
    _offsetMs = nodeMs - (sentAppMs + rtt / 2);
  }

  /// Convert a node timestamp into phone time, or null while unsynchronised.
  double? toAppMs(double nodeMs) =>
      _offsetMs == null ? null : nodeMs - _offsetMs!;

  void reset() {
    _offsetMs = null;
    _bestRttMs = double.infinity;
  }
}

/// Summary of one series of samples.
class LatencyStats {
  final int count;
  final double meanMs;
  final double medianMs;
  final double p95Ms;
  final double minMs;
  final double maxMs;

  const LatencyStats({
    required this.count,
    required this.meanMs,
    required this.medianMs,
    required this.p95Ms,
    required this.minMs,
    required this.maxMs,
  });

  static LatencyStats? of(List<double> samples) {
    if (samples.isEmpty) return null;
    final s = List<double>.from(samples)..sort();
    final mean = s.reduce((a, b) => a + b) / s.length;
    return LatencyStats(
      count: s.length,
      meanMs: mean,
      medianMs: _quantile(s, 0.50),
      p95Ms: _quantile(s, 0.95),
      minMs: s.first,
      maxMs: s.last,
    );
  }

  /// Linear-interpolated quantile of an already-sorted list.
  static double _quantile(List<double> sorted, double q) {
    if (sorted.length == 1) return sorted.first;
    final pos = (sorted.length - 1) * q;
    final lo = pos.floor();
    final hi = math.min(lo + 1, sorted.length - 1);
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - lo);
  }
}

/// Collects latency samples per node so they can be summarised and exported.
///
/// Everything is held in memory: this is a measurement instrument for
/// characterising the system, not part of a screening result, so it deliberately
/// does not touch the results database.
class LatencyTracker {
  /// Keeps memory bounded during a long stress run while still leaving far more
  /// samples than any statistic needs.
  static const int maxSamplesPerSeries = 500;

  final Map<String, Map<LatencyKind, List<double>>> _samples = {};
  final Map<String, ClockOffset> _offsets = {};

  /// Pending play_tone sends, keyed "node#seq", holding the send time in ms.
  final Map<String, double> _pendingCommands = {};

  ClockOffset offsetFor(String nodeId) =>
      _offsets.putIfAbsent(nodeId, () => ClockOffset());

  List<String> get nodeIds {
    final ids = _samples.keys.toList()..sort();
    return ids;
  }

  bool get isEmpty => _samples.values.every((m) =>
      m.values.every((l) => l.isEmpty));

  int get totalSamples => _samples.values
      .expand((m) => m.values)
      .fold(0, (sum, l) => sum + l.length);

  void add(String nodeId, LatencyKind kind, double ms) {
    if (ms.isNaN || ms.isInfinite || ms < 0) return;
    final series = _samples
        .putIfAbsent(nodeId, () => {})
        .putIfAbsent(kind, () => <double>[]);
    series.add(ms);
    if (series.length > maxSamplesPerSeries) series.removeAt(0);
  }

  List<double> samples(String nodeId, LatencyKind kind) =>
      List.unmodifiable(_samples[nodeId]?[kind] ?? const <double>[]);

  LatencyStats? stats(String nodeId, LatencyKind kind) =>
      LatencyStats.of(_samples[nodeId]?[kind] ?? const <double>[]);

  /// Every node's samples of one kind pooled together.
  LatencyStats? statsAll(LatencyKind kind) {
    final pooled = <double>[];
    for (final byKind in _samples.values) {
      pooled.addAll(byKind[kind] ?? const <double>[]);
    }
    return LatencyStats.of(pooled);
  }

  // ---------- command round-trip ----------

  void noteCommandSent(String nodeId, int seq, double nowMs) {
    _pendingCommands['$nodeId#$seq'] = nowMs;
  }

  /// Close the round trip opened by [noteCommandSent]. Silently ignores a reply
  /// with no matching send (a node restart can produce one).
  void noteCommandAcked(String nodeId, int? seq, double nowMs) {
    if (seq == null) return;
    final sent = _pendingCommands.remove('$nodeId#$seq');
    if (sent == null) return;
    add(nodeId, LatencyKind.commandRoundTrip, nowMs - sent);
  }

  void forgetNode(String nodeId) {
    _samples.remove(nodeId);
    _offsets.remove(nodeId);
    _pendingCommands.removeWhere((k, _) => k.startsWith('$nodeId#'));
  }

  void clear() {
    _samples.clear();
    _offsets.clear();
    _pendingCommands.clear();
  }

  /// One row per sample, so the distribution can be re-analysed off-device
  /// rather than only the summary that the screen shows.
  String buildCsv() {
    final b = StringBuffer()..writeln('NodeID,Measurement,Index,Latency_ms');
    for (final nodeId in nodeIds) {
      for (final kind in LatencyKind.values) {
        final series = _samples[nodeId]?[kind] ?? const <double>[];
        for (var i = 0; i < series.length; i++) {
          b.writeln('$nodeId,${kind.csvKey},$i,${series[i].toStringAsFixed(3)}');
        }
      }
    }
    return b.toString();
  }

  /// Compact summary suitable for pasting straight into a report table.
  String buildSummaryCsv() {
    final b = StringBuffer()
      ..writeln('NodeID,Measurement,N,Mean_ms,Median_ms,P95_ms,Min_ms,Max_ms');
    void row(String nodeId, LatencyKind kind, LatencyStats? s) {
      if (s == null) return;
      b.writeln('$nodeId,${kind.csvKey},${s.count},'
          '${s.meanMs.toStringAsFixed(2)},${s.medianMs.toStringAsFixed(2)},'
          '${s.p95Ms.toStringAsFixed(2)},${s.minMs.toStringAsFixed(2)},'
          '${s.maxMs.toStringAsFixed(2)}');
    }

    for (final nodeId in nodeIds) {
      for (final kind in LatencyKind.values) {
        row(nodeId, kind, stats(nodeId, kind));
      }
    }
    for (final kind in LatencyKind.values) {
      row('ALL', kind, statsAll(kind));
    }
    return b.toString();
  }
}
