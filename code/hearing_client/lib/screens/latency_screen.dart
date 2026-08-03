import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/latency.dart';
import '../services/ws_server.dart';
import '../theme.dart';

/// Link-timing measurements, for characterising the system rather than for
/// screening anyone.
///
/// Three figures are shown, and they are deliberately not interchangeable:
///   - command round-trip is measured entirely on the phone's clock, so it needs
///     no clock agreement and is the figure to trust;
///   - button one-way depends on the ping/pong clock offset, and is blank until
///     that offset is established;
///   - press-to-audio is measured by the node against its own clock.
/// One part is invisible to software and so appears in none of them: finger
/// contact until the GPIO poll notices it, bounded by the node's poll interval.
class LatencyScreen extends StatefulWidget {
  final WsServer server;

  const LatencyScreen({super.key, required this.server});

  @override
  State<LatencyScreen> createState() => _LatencyScreenState();
}

class _LatencyScreenState extends State<LatencyScreen> {
  LatencyTracker get t => widget.server.latency;

  Future<void> _export() async {
    if (t.isEmpty) {
      _toast('No samples yet');
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final raw = File(p.join(dir.path, 'latency_samples_$stamp.csv'));
      final summary = File(p.join(dir.path, 'latency_summary_$stamp.csv'));
      await raw.writeAsString(t.buildCsv());
      await summary.writeAsString(t.buildSummaryCsv());
      await Share.shareXFiles([XFile(raw.path), XFile(summary.path)],
          subject: 'Latency measurements');
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  void _clear() {
    setState(t.clear);
    _toast('Samples cleared');
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final nodeIds = t.nodeIds;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Latency'),
        backgroundColor: AppTheme.darkCyan,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => setState(() {}),
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export CSV',
            onPressed: _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever),
            tooltip: 'Clear samples',
            onPressed: _clear,
          ),
        ],
      ),
      backgroundColor: AppTheme.cyan,
      body: SafeArea(
        child: nodeIds.isEmpty
            ? _empty()
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _overall(),
                  for (final id in nodeIds) _nodeCard(id),
                ],
              ),
      ),
    );
  }

  Widget _empty() => const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.timer_outlined, color: Colors.white54, size: 42),
              SizedBox(height: 12),
              Text('No latency samples yet',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text(
                'Samples are collected automatically as tests run. Press Play a '
                'few times, and have the subject press X or Y, then come back.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      );

  Widget _overall() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: AppTheme.panelBox(),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.functions, color: Colors.white, size: 17),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('All nodes pooled',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
              ),
              Text('${t.totalSamples} samples',
                  style: const TextStyle(color: AppTheme.amber, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          for (final k in LatencyKind.values) _statRow(k, t.statsAll(k)),
        ],
      ),
    );
  }

  Widget _nodeCard(String nodeId) {
    final offset = t.offsetFor(nodeId);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: AppTheme.panelBox(border: AppTheme.nodeColor(nodeId)),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(right: 7),
                decoration: BoxDecoration(
                  color: AppTheme.nodeColor(nodeId),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Text(nodeId,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
              ),
              Text(
                offset.known
                    ? 'clock synced ${offset.bestRttMs.round()} ms'
                    : 'syncing clock',
                style: TextStyle(
                    color: offset.known ? AppTheme.online : Colors.white38,
                    fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final k in LatencyKind.values) _statRow(k, t.stats(nodeId, k)),
        ],
      ),
    );
  }

  Widget _statRow(LatencyKind kind, LatencyStats? s) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(kind.label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 2),
          if (s == null)
            const Text('no samples',
                style: TextStyle(color: Colors.white38, fontSize: 12))
          else
            // Median and p95 are what characterise a link; mean, min and max add
            // little on screen and are all in the CSV export anyway.
            Text(
              'n=${s.count}    median ${s.medianMs.round()}    '
              'p95 ${s.p95Ms.round()} ms',
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
            ),
        ],
      ),
    );
  }

}
