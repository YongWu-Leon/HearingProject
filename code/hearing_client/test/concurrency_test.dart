import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_client/models/node_session.dart';
import 'package:hearing_client/services/ws_server.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Concurrency and stress tests against the real hub.
///
/// These drive the shipping WsServer over real WebSocket connections, so what is
/// exercised is the actual protocol handling, seq isolation and reconnect logic
/// rather than a stand-in for them. That makes them the evidence for the claim
/// the whole system rests on: that one operator can run several subjects at once
/// without their results being confused with each other.
///
/// What they deliberately do NOT cover, because no test on a development machine
/// can: real Wi-Fi behaviour, Android's background and power management, the
/// Pi's audio hardware under load, and physical faults such as pulling a node's
/// power. Those stay with the on-hardware procedure.
///
/// Result storage is also out of scope here -- the database needs platform
/// channels that a VM test does not have, and WsServer already treats a storage
/// failure as non-fatal. Persistence is covered by the schema round-trip tests.
void main() {
  late WsServer server;

  setUp(() async {
    server = WsServer();
    await server.start();
    // A hub that failed to bind would make every assertion below meaningless in
    // a way that is easy to misread as a protocol fault, so stop here instead.
    expect(server.running, isTrue,
        reason: 'hub did not bind port ${WsServer.port}: ${server.lastError}');
  });

  tearDown(() async {
    await server.shutdown();
    server.dispose();
  });

  // ---------------------------------------------------------------- helpers

  Future<_FakeNode> join(String id) async {
    final n = _FakeNode(id);
    await n.connect();
    // Waiting on everRegistered alone would return immediately on a RECONNECT,
    // since it stays set from the previous session -- so wait for the link the
    // node has just opened to actually be live.
    await _until(
        () =>
            server.nodes[id]?.channel != null &&
            server.nodes[id]?.everRegistered == true,
        what: '$id to register');
    return n;
  }

  NodeSession session(String id) => server.nodes[id]!;

  // ------------------------------------------------------------------ tests

  test('several nodes register at once and each gets its own card', () async {
    final ids = ['node01', 'node02', 'node03'];
    final nodes = [for (final id in ids) await join(id)];

    for (final id in ids) {
      expect(session(id).online, isTrue, reason: '$id should be online');
      expect(session(id).hw, 'fake-pi', reason: '$id reported the wrong hw');
    }
    for (final n in nodes) {
      await n.close();
    }
  });

  test('concurrent tests keep their levels and frequencies apart', () async {
    final nodes = [
      for (final id in ['node01', 'node02', 'node03']) await join(id),
    ];

    // Distinct parameters per node: if any wire crossed, a node would end up
    // holding another's numbers and the assertions below would catch it.
    final wanted = {
      'node01': (freq: 500.0, level: -20.0),
      'node02': (freq: 1000.0, level: -45.0),
      'node03': (freq: 2000.0, level: -70.0),
    };
    for (final e in wanted.entries) {
      session(e.key)
        ..frequency = e.value.freq
        ..levelDb = e.value.level
        ..selected = true;
    }

    server.playSelected();
    await _until(
        () => nodes.every((n) => n.lastPlay != null), what: 'all nodes to start');

    // Every node must have been asked for its own parameters, and every seq must
    // be distinct -- that is what keeps three conversations from merging.
    final seqs = <int>{};
    for (final n in nodes) {
      final play = n.lastPlay!;
      expect(play['f'], wanted[n.id]!.freq, reason: '${n.id} got a wrong f');
      expect(play['level_db'], wanted[n.id]!.level,
          reason: '${n.id} got a wrong level');
      seqs.add(play['seq'] as int);
    }
    expect(seqs.length, nodes.length, reason: 'seq values were reused');

    for (final n in nodes) {
      await n.completeTest(pressCount: 3);
    }
    await _until(() => nodes.every((n) => !session(n.id).awaitingResult),
        what: 'all nodes to report a result');

    for (final n in nodes) {
      expect(session(n.id).frequency, wanted[n.id]!.freq,
          reason: '${n.id} frequency changed');
      expect(session(n.id).isPlaying, isFalse);
    }
    for (final n in nodes) {
      await n.close();
    }
  });

  test('a message carrying another test\'s seq is ignored', () async {
    final n = await join('node01');
    session('node01').selected = true;
    server.play(session('node01'));
    await _until(() => n.lastPlay != null, what: 'the tone to start');

    final liveSeq = n.lastPlay!['seq'] as int;
    // tone_started opens the record with the level the tone began at, so one
    // step already exists; the question is whether a stale message adds another.
    final stepsBefore = session('node01').assembler.steps.length;
    expect(stepsBefore, 1, reason: 'tone_started should have opened one step');

    // A late message from a test that has already gone must not be recorded.
    n.send({
      'type': 'volume_changed',
      'seq': liveSeq - 500,
      'button': 'X',
      'current_db': 12.0,
      'seg_db': 12.0,
      'seg_from': 'X',
      'seg_remaining_s': 1.0,
    });
    await Future<void>.delayed(const Duration(milliseconds: 120));

    expect(session('node01').assembler.steps.length, stepsBefore,
        reason: 'a stale seq must not add a step');

    // The live tone is still the one that was started, and still tracked.
    expect(session('node01').assembler.seq, liveSeq);
    expect(session('node01').awaitingResult, isTrue);

    await n.close();
  });

  test('losing one node leaves the others running', () async {
    final a = await join('node01');
    final b = await join('node02');
    for (final id in ['node01', 'node02']) {
      session(id).selected = true;
    }

    server.playSelected();
    await _until(() => a.lastPlay != null && b.lastPlay != null,
        what: 'both nodes to start');

    await a.close();
    await _until(() => server.nodes['node01']!.channel == null,
        what: 'node01 to be seen as gone');

    // The dropped node's interrupted test must not be left blocking its card,
    // and the surviving node must be able to finish normally.
    expect(session('node01').awaitingResult, isFalse,
        reason: 'a dropped node must not stay stuck awaiting a result');
    await b.completeTest(pressCount: 2);
    await _until(() => !session('node02').awaitingResult,
        what: 'node02 to finish');
    expect(session('node02').isPlaying, isFalse);

    await b.close();
  });

  test('a node that reconnects is usable again', () async {
    var n = await join('node01');
    await n.close();
    await _until(() => server.nodes['node01']!.channel == null,
        what: 'the drop to register');

    n = await join('node01');
    expect(session('node01').online, isTrue);

    session('node01').selected = true;
    server.play(session('node01'));
    await _until(() => n.lastPlay != null, what: 'the tone to start');
    await n.completeTest(pressCount: 1);
    await _until(() => !session('node01').awaitingResult, what: 'the result');

    await n.close();
  });

  test('repeated rounds on three nodes all complete', () async {
    const rounds = 15;
    final nodes = [
      for (final id in ['node01', 'node02', 'node03']) await join(id),
    ];
    for (final n in nodes) {
      session(n.id).selected = true;
    }

    var completed = 0;
    for (var r = 0; r < rounds; r++) {
      for (final n in nodes) {
        n.lastPlay = null;
      }
      server.playSelected();
      await _until(() => nodes.every((n) => n.lastPlay != null),
          what: 'round $r to start');
      for (final n in nodes) {
        await n.completeTest(pressCount: 2);
      }
      await _until(() => nodes.every((n) => !session(n.id).awaitingResult),
          what: 'round $r to finish');
      completed += nodes.length;
    }

    expect(completed, rounds * nodes.length);
    for (final n in nodes) {
      await n.close();
    }
  });

  test('scales past the three boards that exist in hardware', () async {
    // The roster names three nodes; the architecture is not supposed to care.
    const count = 12;
    final nodes = [
      for (var i = 1; i <= count; i++)
        await join('node${i.toString().padLeft(2, '0')}'),
    ];
    for (final n in nodes) {
      session(n.id).selected = true;
    }

    server.playSelected();
    await _until(() => nodes.every((n) => n.lastPlay != null),
        what: 'all $count nodes to start',
        timeout: const Duration(seconds: 15));

    final seqs = {for (final n in nodes) n.lastPlay!['seq'] as int};
    expect(seqs.length, count, reason: 'seq collision across $count nodes');

    for (final n in nodes) {
      await n.completeTest(pressCount: 1);
    }
    await _until(() => nodes.every((n) => !session(n.id).awaitingResult),
        what: 'all $count nodes to finish',
        timeout: const Duration(seconds: 15));

    for (final n in nodes) {
      await n.close();
    }
  });
}

// ---------------------------------------------------------------------------

/// A node with the protocol but no hardware: it speaks the real wire format over
/// a real socket, and answers commands the way a board would.
class _FakeNode {
  final String id;
  WebSocketChannel? _ch;

  /// The most recent play_tone this node was given, or null before the first.
  Map<String, dynamic>? lastPlay;

  _FakeNode(this.id);

  Future<void> connect() async {
    final ch = WebSocketChannel.connect(
        Uri.parse('ws://localhost:${WsServer.port}/ws'));
    await ch.ready;
    _ch = ch;
    ch.stream.listen((raw) {
      final msg = jsonDecode(raw as String) as Map<String, dynamic>;
      switch (msg['type']) {
        case 'play_tone':
          lastPlay = msg;
          send({
            'type': 'tone_started',
            'seq': msg['seq'],
            'freq': msg['f'],
            'db': msg['level_db'],
            'ear': msg['ear'],
          });
          break;
        case 'ping':
          send({
            'type': 'pong',
            't_app_ms': msg['t_app_ms'],
            't_node_ms': DateTime.now().microsecondsSinceEpoch / 1000.0,
          });
          break;
      }
    }, onError: (_) {}, cancelOnError: false);

    send({
      'type': 'register',
      'hw': 'fake-pi',
      'audio': 'fake',
      'fw_version': 'test',
    });
  }

  void send(Map<String, dynamic> msg) {
    _ch?.sink.add(jsonEncode({...msg, 'node_id': id}));
  }

  /// Play out a subject's hunt: a few adjustments, then the countdown expiring.
  Future<void> completeTest({int pressCount = 2}) async {
    final play = lastPlay;
    if (play == null) return;
    final seq = play['seq'];
    var db = (play['level_db'] as num).toDouble();

    for (var i = 0; i < pressCount; i++) {
      final prev = db;
      db -= 10;
      send({
        'type': 'volume_changed',
        'seq': seq,
        'button': 'X',
        'current_db': db,
        'current_linear': 0.01,
        'seg_db': prev,
        'seg_from': i == 0 ? 'init' : 'X',
        'seg_remaining_s': 12.0,
        't_node_ms': DateTime.now().microsecondsSinceEpoch / 1000.0,
      });
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    send({
      'type': 'tone_done',
      'seq': seq,
      'reason': 'completed',
      'final_db': db,
      'final_linear': 0.01,
      'seg_remaining_s': 0.0,
    });
  }

  Future<void> close() async {
    await _ch?.sink.close();
    _ch = null;
  }
}

/// Wait for [condition], polling until it holds or the timeout expires.
///
/// The protocol is asynchronous end to end, so a fixed sleep would either be
/// slower than necessary or flaky under load; [what] makes a timeout say which
/// step never happened.
Future<void> _until(
  bool Function() condition, {
  required String what,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
