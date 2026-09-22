import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/node_session.dart';
import 'ambient_monitor.dart';
import 'db.dart';
import 'latency.dart';

/// The phone is the hub. Runs the WebSocket server every node dials, owns the
/// node registry, and turns the message stream into stored test records.
///
/// The phone does not open the hotspot -- the operator does that in Android
/// settings; this just listens on whatever address it gets.
///
/// seq is generated here and only here; nodes echo it back on every message,
/// which is what keeps events from multiple nodes (or a rebooted node) from
/// being confused with each other.
class WsServer extends ChangeNotifier {
  static const int port = 8765;

  HttpServer? _server;
  Timer? _tick;
  int _seq = 0;

  final Map<String, NodeSession> nodes = {};
  final List<LiveEvent> events = [];
  static const _maxEvents = 60;

  /// Link-timing instrument, kept out of the results database on purpose --
  /// it characterises the system, not the screening result.
  final LatencyTracker latency = LatencyTracker();

  /// Ambient-noise monitor, attached by the screen that owns it. Optional:
  /// screening carries on without microphone permission.
  AmbientMonitor? ambient;

  /// How often each node is probed for clock offset. Frequent enough to
  /// track drift, rare enough to stay invisible next to the 5 s heartbeat.
  static const _clockProbeEvery = Duration(seconds: 10);
  DateTime _lastClockProbe = DateTime.fromMillisecondsSinceEpoch(0);

  /// Monotonic-ish millisecond reading for latency arithmetic.
  static double _nowMs() =>
      DateTime.now().microsecondsSinceEpoch / 1000.0;

  String? listenAddress;
  String? lastError;
  bool get running => _server != null;

  WsServer() {
    // Seed the roster so every expected board has a greyed-out card until it
    // registers, instead of simply not appearing.
    for (final id in kExpectedNodes) {
      nodes[id] = NodeSession(id);
    }
  }

  // ---------- lifecycle ----------

  Future<void> start() async {
    if (_server != null) return;
    // Resume seq above the highest on record so it never repeats across
    // restarts. Best-effort: a db problem here must not block the socket.
    try {
      final past = await Db.instance.loadTests(limit: 1);
      if (past.isNotEmpty) _seq = past.first.seq;
    } catch (e) {
      debugPrint('[ws] seq resume skipped (db unavailable): $e');
    }
    try {
      final ws = webSocketHandler((WebSocketChannel channel, String? _) {
        _onConnect(channel);
      });

      // Nodes dial /ws; anything else is a stray probe.
      FutureOr<Response> root(Request req) {
        final path = req.url.path;
        if (path == 'ws' || path.isEmpty) return ws(req);
        return Response.notFound('hearing hub');
      }

      _server = await shelf_io.serve(root, InternetAddress.anyIPv4, port);
      listenAddress = await _localIp();
      lastError = null;
      _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
      debugPrint('[ws] listening on $listenAddress:$port');
    } catch (e) {
      lastError = '$e';
      debugPrint('[ws] failed to start: $e');
    }
    _safeNotify();
  }

  /// Tear the listener down. Named shutdown (not stop) to avoid confusion with
  /// stop(node) below, which ends a tone.
  Future<void> shutdown() async {
    _tick?.cancel();
    _tick = null;
    for (final n in nodes.values) {
      await n.channel?.sink.close();
      n.channel = null;
    }
    await _server?.close(force: true);
    _server = null;
    _safeNotify();
  }

  @override
  void dispose() {
    // Set first: async shutdown()/socket/db callbacks route through
    // _safeNotify, which goes quiet once this is set.
    _disposed = true;
    shutdown();
    super.dispose();
  }

  bool _disposed = false;

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// This phone's address on the hotspot, so the operator can confirm the
  /// hotspot is up before blaming the nodes.
  Future<String?> _localIp() async {
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (_) {}
    return null;
  }

  // ---------- connection handling ----------

  void _onConnect(WebSocketChannel channel) {
    String? nodeId;
    channel.stream.listen(
      (raw) {
        Map<String, dynamic> msg;
        try {
          final decoded = jsonDecode(raw as String);
          if (decoded is! Map<String, dynamic>) return;
          msg = decoded;
        } catch (_) {
          debugPrint('[ws] ignoring non-JSON frame');
          return;
        }
        nodeId = msg['node_id'] as String? ?? nodeId;
        if (nodeId == null) return;
        _handle(nodeId!, channel, msg);
      },
      onDone: () => _onDisconnect(nodeId, channel),
      onError: (e) {
        debugPrint('[ws] socket error ($nodeId): $e');
        _onDisconnect(nodeId, channel);
      },
      cancelOnError: true,
    );
  }

  void _onDisconnect(String? nodeId, WebSocketChannel channel) {
    if (nodeId == null) return;
    final n = nodes[nodeId];
    // Stale callback from a socket the node already replaced; ignore.
    if (n == null || !identical(n.channel, channel)) return;
    n.channel = null;
    // Interrupted tone is not a result; abandon it so Play isn't stuck disabled.
    if (n.awaitingResult) n.assembler.abandon('disconnected');
    n.resetPlayback();
    _pushEvent(LiveEvent(nodeId, null, 'Disconnected', StepFrom.init));
    _safeNotify();
  }

  // ---------- protocol ----------

  void _handle(String nodeId, WebSocketChannel channel, Map<String, dynamic> msg) {
    final n = nodes.putIfAbsent(nodeId, () => NodeSession(nodeId));
    n.channel = channel;
    n.lastSeen = DateTime.now();

    switch (msg['type'] as String?) {
      case 'register':
        n.hw = msg['hw'] as String? ?? '?';
        n.audio = msg['audio'] as String? ?? '?';
        n.fwVersion = msg['fw_version'] as String? ?? '?';
        n.everRegistered = true;
        n.resetPlayback();
        _pushEvent(LiveEvent(nodeId, null, 'Registered (${n.hw})', StepFrom.init));
        break;

      case 'heartbeat':
        n.state = msg['state'] as String? ?? 'IDLE';
        // Only follow the node's level while playing; an idle heartbeat must
        // not overwrite the operator's set point for the next tone.
        if (n.state == 'PLAYING') {
          final d = _d(msg['current_db']);
          if (d != null) n.levelDb = d;
        }
        n.remainingS = _d(msg['remaining_s']) ?? 0;
        break;

      case 'pong':
        // Clock-offset probe closing; this is where the node's clock becomes
        // comparable to ours.
        final sent = _d(msg['t_app_ms']);
        final nodeMs = _d(msg['t_node_ms']);
        if (sent != null && nodeMs != null) {
          latency.offsetFor(nodeId).update(
                sentAppMs: sent,
                nodeMs: nodeMs,
                receivedAppMs: _nowMs(),
              );
        }
        return; // nothing user-visible changed

      case 'audio_latency':
        // Node-measured locally (press -> first chunk); no clock conversion needed.
        final ms = _d(msg['ms']);
        if (ms != null) latency.add(nodeId, LatencyKind.audioApply, ms);
        return;

      case 'tone_started':
        final seq = _i(msg['seq']);
        latency.noteCommandAcked(nodeId, seq, _nowMs());
        n.state = 'PLAYING';
        n.levelDb = _d(msg['db']) ?? n.levelDb;
        n.assembler.onToneStarted(seq: seq, db: n.levelDb);
        _pushEvent(LiveEvent(nodeId, seq,
            'Playing ${_fmtHz(_d(msg['freq']))} at ${n.levelDb.toStringAsFixed(1)} dB',
            StepFrom.init));
        break;

      case 'volume_changed':
        // seg_* describes the level that just ended (one records-view row);
        // current_db is the new level, tracked live by the control.
        final seq = _i(msg['seq']);
        final remaining = _d(msg['seg_remaining_s']) ?? 0;
        n.levelDb = _d(msg['current_db']) ?? n.levelDb;

        // One-way press-to-phone latency; skipped, not guessed, until this
        // node's clock offset is known.
        final tNode = _d(msg['t_node_ms']);
        if (tNode != null) {
          final pressedAppMs = latency.offsetFor(nodeId).toAppMs(tNode);
          if (pressedAppMs != null) {
            latency.add(
                nodeId, LatencyKind.buttonOneWay, _nowMs() - pressedAppMs);
          }
        }
        n.assembler.onVolumeChanged(
          seq: seq,
          segDb: _d(msg['seg_db']),
          segFrom: msg['seg_from'] as String?,
          segRemainingS: remaining,
          currentDb: _d(msg['current_db']),
          currentLinear: _d(msg['current_linear']),
          button: msg['button'] as String?,
        );

        final kind = _buttonKind(msg['button']);
        _pushEvent(LiveEvent(
            nodeId,
            seq,
            '${kind == StepFrom.down ? 'Lowered' : 'Raised'} to '
            '${n.levelDb.toStringAsFixed(1)} dB  (held ${remaining.toStringAsFixed(1)}s)',
            kind));
        break;

      case 'tone_done':
        final seq = _i(msg['seq']);
        final finalDb = _d(msg['final_db']);
        final reason = msg['reason'] as String? ?? 'completed';
        final remaining = _d(msg['seg_remaining_s']) ?? 0;
        n.state = 'IDLE';
        n.remainingS = 0;
        if (finalDb != null) n.levelDb = finalDb;

        final ambientPeak = ambient?.windowPeakDb;
        final ambientOver = ambient?.windowExceeded ?? false;
        final record = n.assembler.onToneDone(
          seq: seq,
          reason: reason,
          finalDb: finalDb,
          finalLinear: _d(msg['final_linear']),
          segRemainingS: remaining,
        );
        // Only a completed countdown is a real result; an early stop is discarded.
        if (reason == 'completed') {
          _store(record?.copyWith(
              ambientPeakDb: ambientPeak, ambientOverLimit: ambientOver));
        }

        n.awaitingResult = false;
        n.timedOut = false;
        n.activeSeq = null;
        n.playSentAt = null;

        _pushEvent(LiveEvent(
            nodeId,
            seq,
            reason == 'completed'
                ? 'Threshold ${finalDb?.toStringAsFixed(1)} dB'
                : 'Stopped (discarded)',
            reason == 'completed' ? StepFrom.up : StepFrom.init));
        break;

      case 'error':
        final detail = '${msg['code']}: ${msg['detail']}';
        lastError = '$nodeId $detail';
        _pushEvent(LiveEvent(nodeId, _i(msg['seq']), detail, StepFrom.down));
        break;

      default:
        // Unknown types ignored, not fatal: a node may be a newer build.
        debugPrint('[ws] unknown message type ${msg['type']} from $nodeId');
        return;
    }
    _safeNotify();
  }

  /// Persist a finished test. Fire and forget so a slow write doesn't stall
  /// the message pump.
  void _store(TestRecord? record) {
    if (record == null) return;
    Db.instance.saveTest(record).catchError((e) {
      debugPrint('[db] save failed: $e');
      return -1;
    });
  }

  // ---------- outbound commands ----------

  int _nextSeq() => ++_seq;

  /// Start a tone on one node using that node's own dialled-in parameters.
  void play(NodeSession n) {
    if (!n.online) return;
    // Safety net: discard any test still in flight when Play is pressed again.
    if (n.assembler.active) n.assembler.abandon('restarted');

    final seq = _nextSeq();
    n.activeSeq = seq;
    n.awaitingResult = true;
    n.timedOut = false;
    n.playSentAt = DateTime.now();
    n.assembler.begin(
      nodeId: n.nodeId,
      patientId: n.patientGroupTs,
      seq: seq,
      freqHz: n.frequency,
      ear: n.ear,
    );
    // Fresh ambient window so the stored level describes this test only.
    ambient?.beginWindow();
    latency.noteCommandSent(n.nodeId, seq, _nowMs());
    _send(n, {
      'type': 'play_tone',
      'seq': seq,
      'f': n.frequency,
      'level_db': n.levelDb,   // dB directly now, not the old 0-100 v
      'ear': n.ear,
    });
    _safeNotify();
  }

  void stop(NodeSession n) {
    if (!n.online) return;
    _send(n, {'type': 'stop', 'seq': n.activeSeq});
  }

  /// Fan out to every selected node, each with its own card's parameters, so
  /// concurrent subjects can run different frequencies/levels/ears.
  void playSelected() {
    for (final n in nodes.values) {
      if (n.selected && n.online && !n.awaitingResult) play(n);
    }
  }

  void stopSelected() {
    for (final n in nodes.values) {
      if (n.selected && n.online) stop(n);
    }
  }

  void _send(NodeSession n, Map<String, Object?> msg) {
    try {
      n.channel?.sink.add(jsonEncode(msg));
    } catch (e) {
      debugPrint('[ws] send to ${n.nodeId} failed: $e');
    }
  }

  // ---------- housekeeping ----------

  /// Repaint after the UI mutates a node's parameters in place. notifyListeners
  /// is protected, so widgets go through this instead.
  void refresh() => _safeNotify();

  /// Start a new patient/session on a node: tests taken from now on are grouped
  /// separately in the audiogram. A test still in flight keeps its old group.
  void newPatient(NodeSession n) {
    n.startNewPatient();
    _safeNotify();
  }

  void _onTick() {
    var changed = false;
    final now = DateTime.now();

    // Clock-offset probe, riding the 1 Hz tick so it can't outlive the server.
    if (now.difference(_lastClockProbe) >= _clockProbeEvery) {
      _lastClockProbe = now;
      for (final n in nodes.values) {
        if (n.channel != null) {
          _send(n, {'type': 'ping', 't_app_ms': _nowMs()});
        }
      }
    }

    for (final n in nodes.values) {
      // Safety net for a node that died mid-tone (normally tone_done re-enables Play).
      if (n.awaitingResult &&
          n.playSentAt != null &&
          now.difference(n.playSentAt!) > kPlayTimeout) {
        n.awaitingResult = false;
        n.timedOut = true;
        _store(n.assembler.abandon('timeout'));
        n.activeSeq = null;
        n.playSentAt = null;
        _pushEvent(LiveEvent(n.nodeId, null,
            'No result after ${kPlayTimeout.inSeconds}s -- ready again',
            StepFrom.down));
        changed = true;
      }
      // Heartbeats stopped: grey the card even though the socket is still open.
      if (n.channel != null && n.staleFor(kHeartbeatTimeout) && n.isPlaying) {
        n.state = 'IDLE';
        changed = true;
      }
      // online is time-derived; nothing else signals when it flips.
      if (n.online != n.lastKnownOnline) {
        n.lastKnownOnline = n.online;
        changed = true;
      }
    }
    // Repaint only on a real transition, or 1 Hz repaints fight number-field typing.
    if (changed) _safeNotify();
  }

  void _pushEvent(LiveEvent e) {
    events.insert(0, e);
    if (events.length > _maxEvents) events.removeRange(_maxEvents, events.length);
  }

  // ---------- helpers ----------

  static StepFrom _buttonKind(Object? button) =>
      button == 'X' ? StepFrom.down : StepFrom.up;

  static double? _d(Object? v) => v is num ? v.toDouble() : null;
  static int? _i(Object? v) => v is num ? v.toInt() : null;

  static String _fmtHz(double? hz) {
    if (hz == null) return '?';
    return hz >= 1000 && hz % 1000 == 0
        ? '${(hz / 1000).toStringAsFixed(0)} kHz'
        : '${hz.toStringAsFixed(0)} Hz';
  }
}
