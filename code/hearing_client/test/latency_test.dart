import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_client/services/latency.dart';

void main() {
  group('ClockOffset', () {
    test('is unusable until an exchange completes', () {
      final c = ClockOffset();
      expect(c.known, isFalse);
      expect(c.toAppMs(12345), isNull);
    });

    test('recovers a known offset from a symmetric round trip', () {
      // Phone sends at 1000 and receives at 1100, so the node's reply is taken to
      // have happened at 1050 phone-time. The node stamped it 6050 on its own
      // clock, which puts its clock 5000 ms ahead.
      final c = ClockOffset()
        ..update(sentAppMs: 1000, nodeMs: 6050, receivedAppMs: 1100);
      expect(c.known, isTrue);
      expect(c.offsetMs, closeTo(5000, 0.001));
      expect(c.toAppMs(6050), closeTo(1050, 0.001));
    });

    test('keeps the fastest exchange and ignores slower ones', () {
      final c = ClockOffset()
        ..update(sentAppMs: 0, nodeMs: 5400, receivedAppMs: 800); // rtt 800
      expect(c.bestRttMs, 800);

      c.update(sentAppMs: 2000, nodeMs: 7020, receivedAppMs: 2040); // rtt 40
      expect(c.bestRttMs, 40);
      expect(c.offsetMs, closeTo(5000, 0.001));

      // A later, slower exchange must not displace the better estimate.
      c.update(sentAppMs: 5000, nodeMs: 12000, receivedAppMs: 6000);
      expect(c.bestRttMs, 40);
      expect(c.offsetMs, closeTo(5000, 0.001));
    });

    test('ignores a negative round trip', () {
      final c = ClockOffset()
        ..update(sentAppMs: 500, nodeMs: 100, receivedAppMs: 400);
      expect(c.known, isFalse);
    });
  });

  group('LatencyStats', () {
    test('no samples yields no stats', () {
      expect(LatencyStats.of(const []), isNull);
    });

    test('computes the summary of a known series', () {
      final s = LatencyStats.of([10, 20, 30, 40, 50])!;
      expect(s.count, 5);
      expect(s.meanMs, closeTo(30, 0.001));
      expect(s.medianMs, closeTo(30, 0.001));
      expect(s.minMs, 10);
      expect(s.maxMs, 50);
      expect(s.p95Ms, closeTo(48, 0.001));
    });

    test('is order independent', () {
      final a = LatencyStats.of([50, 10, 30, 20, 40])!;
      expect(a.medianMs, closeTo(30, 0.001));
      expect(a.minMs, 10);
    });
  });

  group('LatencyTracker', () {
    test('pairs a command with its acknowledgement', () {
      final t = LatencyTracker()
        ..noteCommandSent('node01', 7, 1000)
        ..noteCommandAcked('node01', 7, 1042);
      final s = t.stats('node01', LatencyKind.commandRoundTrip)!;
      expect(s.count, 1);
      expect(s.meanMs, closeTo(42, 0.001));
    });

    test('an acknowledgement with no matching send is ignored', () {
      final t = LatencyTracker()..noteCommandAcked('node01', 99, 1000);
      expect(t.stats('node01', LatencyKind.commandRoundTrip), isNull);
      expect(t.isEmpty, isTrue);
    });

    test('rejects impossible samples', () {
      final t = LatencyTracker()
        ..add('node01', LatencyKind.audioApply, -5)
        ..add('node01', LatencyKind.audioApply, double.nan)
        ..add('node01', LatencyKind.audioApply, 12);
      expect(t.stats('node01', LatencyKind.audioApply)!.count, 1);
    });

    test('pools every node for the overall figure', () {
      final t = LatencyTracker()
        ..add('node01', LatencyKind.audioApply, 10)
        ..add('node02', LatencyKind.audioApply, 30);
      expect(t.statsAll(LatencyKind.audioApply)!.count, 2);
      expect(t.statsAll(LatencyKind.audioApply)!.meanMs, closeTo(20, 0.001));
    });

    test('bounds memory by dropping the oldest samples', () {
      final t = LatencyTracker();
      for (var i = 0; i < LatencyTracker.maxSamplesPerSeries + 25; i++) {
        t.add('node01', LatencyKind.commandRoundTrip, i.toDouble());
      }
      final s = t.stats('node01', LatencyKind.commandRoundTrip)!;
      expect(s.count, LatencyTracker.maxSamplesPerSeries);
      expect(s.minMs, 25); // the first 25 were dropped
    });

    test('exports one CSV row per sample', () {
      final t = LatencyTracker()
        ..add('node01', LatencyKind.commandRoundTrip, 10)
        ..add('node01', LatencyKind.commandRoundTrip, 20);
      final lines = t.buildCsv().trim().split('\n');
      expect(lines.first, contains('NodeID'));
      expect(lines.length, 3); // header + 2 samples
    });
  });
}
