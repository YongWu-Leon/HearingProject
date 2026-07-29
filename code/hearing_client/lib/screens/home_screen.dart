import 'package:flutter/material.dart';

import '../models/node_session.dart';
import '../services/ambient_monitor.dart';
import '../services/foreground.dart';
import '../services/ws_server.dart';
import '../theme.dart';
import '../widgets/node_card.dart';
import 'records_screen.dart';

/// Main screen: the hub status, one card per node, and a live event feed.
///
/// The phone no longer picks a board to talk to -- it IS the hub, and nodes
/// appear here by themselves as they register on its hotspot. Each card holds
/// its own frequency / volume / ear, so nodes can be driven independently
/// (start node 1, then start node 2 on a different tone) or together via
/// sync mode plus Play All.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final WsServer _server = WsServer();
  final AmbientMonitor _ambient = AmbientMonitor();

  static const _appVersion = 'v2.0';

  @override
  void initState() {
    super.initState();
    _server.addListener(_onServerChanged);
    _ambient.addListener(_onAmbient);
    _boot();
  }

  void _onAmbient() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    // The foreground service must be up before the socket, or Android may kill
    // the listener the moment the screen locks.
    await Foreground.start(nodeCount: 0);
    await _server.start();
    if (mounted && !_server.running) {
      _showStatus('Server failed to start: ${_server.lastError}');
    }
    // Ambient-noise monitoring is a best-effort helper; a denied mic permission
    // just leaves the noise card showing a hint and never blocks screening.
    await _ambient.start();
  }

  void _onServerChanged() {
    if (mounted) setState(() {});
    Foreground.update(nodeCount: _server.nodes.values.where((n) => n.online).length);
  }

  @override
  void dispose() {
    _server.removeListener(_onServerChanged);
    _server.dispose();
    _ambient.removeListener(_onAmbient);
    _ambient.dispose();
    Foreground.stop();
    super.dispose();
  }

  // The old persistent status line at the bottom is gone; the live event feed
  // covers activity. Kept as a hook so the card callbacks still have somewhere
  // to report to (debug log only).
  void _showStatus(String msg) => debugPrint('[ui] $msg');

  void _openRecords({String? nodeId}) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RecordsScreen(nodeId: nodeId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final nodes = _server.nodes.values.toList()
      ..sort((a, b) => a.nodeId.compareTo(b.nodeId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Hearing Screener'),
        backgroundColor: AppTheme.darkCyan,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: 'All records',
            onPressed: () => _openRecords(),
          ),
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(
              child: Text(_appVersion,
                  style: TextStyle(fontSize: 12, color: Colors.white60)),
            ),
          ),
        ],
      ),
      backgroundColor: AppTheme.cyan,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _hubCard(nodes),
              const SizedBox(height: 10),
              _noiseCard(),
              const SizedBox(height: 10),
              if (nodes.isEmpty) _emptyState() else ...[
                for (final n in nodes)
                  NodeCard(
                    key: ValueKey(n.nodeId),
                    node: n,
                    server: _server,
                    onToggleExpand: () =>
                        setState(() => n.expanded = !n.expanded),
                    onOpenRecords: () => _openRecords(nodeId: n.nodeId),
                    onStatus: _showStatus,
                  ),
              ],
              const SizedBox(height: 4),
              _eventFeed(),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- hub status + global controls ----------

  Widget _hubCard(List<NodeSession> nodes) {
    final online = nodes.where((n) => n.online).length;
    final selected = nodes.where((n) => n.selected && n.online).length;

    return Container(
      decoration: AppTheme.panelBox(),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(_server.running ? Icons.wifi_tethering : Icons.wifi_off,
                  color: _server.running ? Colors.white : AppTheme.amber,
                  size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _server.running
                      ? 'Hub on ${_server.listenAddress ?? '?'}:${WsServer.port}'
                      : 'Server not running',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              Text('$online/${nodes.length} online',
                  style: const TextStyle(
                      color: AppTheme.amber,
                      fontSize: 12,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _globalButton(
                  label: 'Play all',
                  icon: Icons.play_arrow,
                  color: Colors.green.shade700,
                  enabled: selected > 0,
                  onTap: () {
                    _server.playSelected();
                    _showStatus('Started $selected selected node(s)');
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _globalButton(
                  label: 'Stop all',
                  icon: Icons.stop,
                  color: Colors.orange.shade700,
                  enabled: selected > 0,
                  onTap: () {
                    _server.stopSelected();
                    _showStatus('Stopped $selected selected node(s)');
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _globalButton({
    required String label,
    required IconData icon,
    required Color color,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return ElevatedButton.icon(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 16),
      label: Text(label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Colors.white24,
        disabledForegroundColor: Colors.white38,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        elevation: 0,
      ),
    );
  }

  // ---------- ambient noise (Kalman-smoothed) ----------

  Widget _noiseCard() {
    final m = _ambient;
    Color c;
    IconData icon;
    String text;
    if (m.error != null) {
      c = Colors.white54;
      icon = Icons.mic_off;
      text = m.error!;
    } else if (!m.hasReading) {
      c = Colors.white54;
      icon = Icons.mic_none;
      text = 'Starting ambient-noise monitor...';
    } else if (m.tooNoisy) {
      c = AppTheme.amber;
      icon = Icons.warning_amber_rounded;
      text = 'Too noisy for a reliable test';
    } else {
      c = AppTheme.online;
      icon = Icons.mic;
      text = 'Environment OK';
    }
    return Container(
      decoration: AppTheme.panelBox(border: m.tooNoisy ? AppTheme.amber : null),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Row(
        children: [
          Icon(icon, color: c, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: c, fontSize: 13)),
          ),
          if (m.hasReading)
            Text('${m.smoothedDb.toStringAsFixed(0)} dB',
                style: TextStyle(
                    color: c, fontSize: 15, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  // ---------- empty state ----------

  Widget _emptyState() {
    return Container(
      decoration: AppTheme.panelBox(),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Column(
        children: [
          const Icon(Icons.devices_other, color: Colors.white54, size: 40),
          const SizedBox(height: 10),
          const Text('No nodes connected',
              style: TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'Nodes join automatically once they are on this phone\'s hotspot.\n'
            '1. Turn on the hotspot in Android settings\n'
            '2. Power the nodes on\n'
            '3. They register here within about 30 seconds',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () => _openRecords(),
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('View saved records'),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }

  // ---------- live event feed ----------

  Widget _eventFeed() {
    final events = _server.events.take(8).toList();
    if (events.isEmpty) return const SizedBox.shrink();

    return Container(
      decoration: AppTheme.panelBox(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('Live events',
                style: TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
          ),
          for (final e in events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(_eventIcon(e.kind), size: 13, color: _eventColor(e.kind)),
                  const SizedBox(width: 6),
                  Text('${e.nodeId}${e.seq == null ? '' : ' #${e.seq}'}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(e.text,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ),
                  Text(_hhmmss(e.ts),
                      style: const TextStyle(color: Colors.white38, fontSize: 10)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static IconData _eventIcon(StepFrom kind) {
    switch (kind) {
      case StepFrom.down:
        return Icons.arrow_downward;
      case StepFrom.up:
        return Icons.arrow_upward;
      case StepFrom.init:
        return Icons.circle_outlined;
    }
  }

  static Color _eventColor(StepFrom kind) {
    switch (kind) {
      case StepFrom.down:
        return const Color(0xFFFF8A80);
      case StepFrom.up:
        return const Color(0xFFB9F6CA);
      case StepFrom.init:
        return Colors.white54;
    }
  }

  static String _hhmmss(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';
}
