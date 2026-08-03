import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/node_session.dart';
import '../services/db.dart';
import '../theme.dart';
import 'audiogram_screen.dart';

/// Saved test records, read from the phone's database.
///
/// One test = one thick-bordered group. Inside it, one row per level the subject
/// held, colour coded by how they got there:
///   white        the level the operator started them on
///   light red    they pressed X to go quieter
///   light green  they pressed Y to go louder
/// The right-hand column is how much of the 15 s countdown was left when that
/// level ended -- i.e. how long they sat on it before changing it. The last row
/// always ends at 0.0 s, because that is the countdown running out, and its
/// level is the threshold shown in the footer.
///
/// Levels here are in dB. The 0-100 volume control on the main screen is only a
/// send-side convenience; it never appears in the record.
class RecordsScreen extends StatefulWidget {
  /// null shows every node.
  final String? nodeId;

  const RecordsScreen({super.key, this.nodeId});

  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends State<RecordsScreen> {
  List<TestRecord> _tests = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final tests = await Db.instance.loadTests(nodeId: widget.nodeId);
    if (!mounted) return;
    setState(() {
      _tests = tests;
      _loading = false;
    });
  }

  Future<void> _export() async {
    if (_tests.isEmpty) {
      _toast('Nothing to export');
      return;
    }
    try {
      final csv = Db.instance.buildCsv(_tests);
      final file = await Db.instance.writeCsvFile(csv, nodeId: widget.nodeId);
      await Share.shareXFiles([XFile(file.path)],
          subject: 'Hearing test results');
    } catch (e) {
      _toast('Export failed: $e');
    }
  }

  Future<void> _delete() async {
    final scope = widget.nodeId ?? 'all nodes';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete records'),
        content:
            Text('Delete every saved test for $scope? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await Db.instance.deleteAll(nodeId: widget.nodeId);
    _toast('Records deleted');
    _load();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
            widget.nodeId == null ? 'All records' : '${widget.nodeId} records'),
        backgroundColor: AppTheme.darkCyan,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _load,
          ),
          IconButton(
            icon: const Icon(Icons.show_chart),
            tooltip: 'Audiogram',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => AudiogramScreen(nodeId: widget.nodeId)),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export CSV',
            onPressed: _export,
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever),
            tooltip: 'Delete records',
            onPressed: _delete,
          ),
        ],
      ),
      backgroundColor: AppTheme.cyan,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : _tests.isEmpty
                ? _empty()
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _tests.length,
                    itemBuilder: (_, i) => _testGroup(_tests[i]),
                  ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox, color: Colors.white54, size: 42),
            const SizedBox(height: 12),
            const Text('No records yet',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
              widget.nodeId == null
                  ? 'Run a test and the result is saved here automatically.'
                  : 'No tests recorded for ${widget.nodeId} yet.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- one test = one bordered group ----------

  Widget _testGroup(TestRecord t) {
    // Border colour is the node's signature colour, so in the combined "all
    // records" view you can tell at a glance which node each test came from --
    // and it matches that node's card on the main screen.
    final border = AppTheme.nodeColor(t.nodeId);
    final onNode = AppTheme.onNodeColor(t.nodeId);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        // The thick border is what visually separates one test from the next.
        border: Border.all(color: border, width: 2.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _groupHeader(t, border, onNode),
            for (final s in t.steps)
              _stepRow(s, isLast: s.index == t.steps.length - 1),
            _groupFooter(t, border, onNode),
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(TestRecord t, Color nodeColor, Color onNode) {
    return Container(
      color: AppTheme.paleCyan,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      child: Row(
        children: [
          Text(
            '${AppTheme.formatHz(t.freqHz)} Hz  -  ${AppTheme.earLabel(t.ear)}',
            style: const TextStyle(
                color: Color(0xFF00595E),
                fontSize: 13,
                fontWeight: FontWeight.bold),
          ),
          if (widget.nodeId == null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: nodeColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(t.nodeId,
                  style: TextStyle(
                      color: onNode, fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ],
          const Spacer(),
          Text(_stamp(t.startTs),
              style: const TextStyle(color: Color(0xFF00595E), fontSize: 11)),
        ],
      ),
    );
  }

  Widget _stepRow(TestStep s, {required bool isLast}) {
    late Color bg, text, icon;
    late IconData mark;
    switch (s.from) {
      case StepFrom.down:
        bg = AppTheme.rowLowered;
        text = AppTheme.rowLoweredText;
        icon = AppTheme.rowLoweredIcon;
        mark = Icons.arrow_downward;
        break;
      case StepFrom.up:
        bg = AppTheme.rowRaised;
        text = AppTheme.rowRaisedText;
        icon = AppTheme.rowRaisedIcon;
        mark = Icons.arrow_upward;
        break;
      case StepFrom.init:
        bg = AppTheme.rowInitial;
        text = AppTheme.rowInitialText;
        icon = const Color(0xFF78909C);
        mark = Icons.radio_button_checked;
        break;
    }

    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: isLast
            ? null
            : const Border(bottom: BorderSide(color: Color(0xFFECEFF1))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      child: Row(
        children: [
          Icon(mark, size: 16, color: icon),
          const SizedBox(width: 9),
          SizedBox(
            width: 74,
            child: Text('${s.db.toStringAsFixed(1)} dB',
                style: TextStyle(
                    color: text, fontSize: 14, fontWeight: FontWeight.bold)),
          ),
          Text(stepFromLabel(s.from),
              style: TextStyle(color: text, fontSize: 12)),
          const Spacer(),
          Text('${s.remainingS.toStringAsFixed(1)} s left',
              style: TextStyle(color: text, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _groupFooter(TestRecord t, Color nodeColor, Color onNode) {
    // Only completed tests are ever stored now, so the footer always shows a
    // threshold; the incomplete branch stays as defensive fallback.
    final complete = t.isComplete && t.thresholdDb != null;
    // Dark text on the soft node colour; white on the grey fallback.
    final fg = complete ? onNode : Colors.white;
    return Container(
      color: complete ? nodeColor : const Color(0xFF78909C),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(complete ? Icons.check : Icons.info_outline,
                  size: 16, color: fg),
              const SizedBox(width: 7),
              Text(
                  complete
                      ? 'Threshold'
                      : 'Incomplete (${t.reason ?? 'unknown'})',
                  style: TextStyle(
                      color: fg, fontSize: 13, fontWeight: FontWeight.w500)),
              const Spacer(),
              Text(
                complete ? '${t.thresholdDb!.toStringAsFixed(1)} dB' : '-',
                style: TextStyle(
                    color: fg, fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          // Flagged, never withheld: the result stands, and a reader can see that
          // the room was louder than the limit while it was being measured.
          if (t.ambientOverLimit) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 15, color: fg),
                const SizedBox(width: 7),
                Text(
                  t.ambientPeakDb == null
                      ? 'Ambient noise over limit'
                      : 'Ambient noise over limit  '
                          '(peak ${t.ambientPeakDb!.round()} dB)',
                  style: TextStyle(color: fg, fontSize: 11),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _stamp(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}:'
      '${d.second.toString().padLeft(2, '0')}';
}
