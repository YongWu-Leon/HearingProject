import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/node_session.dart';
import '../services/db.dart';
import '../theme.dart';

/// Audiogram view. One chart PER PATIENT: the tests taken on a node between two
/// "New patient" marks form one patient group, and each group is drawn as its
/// own audiogram, so different subjects are never mixed onto one chart.
///
/// Layout follows the clinical convention -- log frequency across the bottom,
/// quieter (better) hearing towards the top, right ear = red circles, left ear =
/// blue crosses. The vertical axis is uncalibrated device dB, not dB HL, and is
/// labelled as such; a per-frequency calibration offset turns it into dB HL.
class AudiogramScreen extends StatefulWidget {
  /// null shows every node's groups together.
  final String? nodeId;

  const AudiogramScreen({super.key, this.nodeId});

  @override
  State<AudiogramScreen> createState() => _AudiogramScreenState();
}

class _AudiogramScreenState extends State<AudiogramScreen> {
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

  /// Completed tests grouped by (node, patient), newest group first. Within a
  /// group the newest threshold for each frequency wins (loadTests is newest
  /// first, so the first value seen is kept).
  List<_PatientGroup> _groups() {
    final byKey = <String, _PatientGroup>{};
    final order = <String>[];
    for (final t in _tests) {
      if (!t.isComplete || t.thresholdDb == null) continue;
      final key = '${t.nodeId}#${t.patientId}';
      var g = byKey[key];
      if (g == null) {
        g = _PatientGroup(t.nodeId, t.patientId);
        byKey[key] = g;
        order.add(key);
      }
      if (g.firstStart == null || t.startTs.isBefore(g.firstStart!)) {
        g.firstStart = t.startTs;
      }
      final end = t.endTs ?? t.startTs;
      if (g.lastEnd == null || end.isAfter(g.lastEnd!)) g.lastEnd = end;
      g.series
          .putIfAbsent(t.ear, () => {})
          .putIfAbsent(t.freqHz, () => t.thresholdDb!);
    }
    final list = [for (final k in order) byKey[k]!];
    // order is newest-first (tests are newest first), so the earliest group is
    // last -- number it Patient 1 and the newest the highest.
    for (var i = 0; i < list.length; i++) {
      list[i].patientNo = list.length - i;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.nodeId == null
            ? 'Audiograms'
            : 'Audiograms - ${widget.nodeId}'),
        backgroundColor: AppTheme.darkCyan,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _load,
          ),
        ],
      ),
      backgroundColor: AppTheme.cyan,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : groups.isEmpty
                ? _empty()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                        child: _legendAndNote(),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                          itemCount: groups.length,
                          itemBuilder: (_, i) => _groupCard(groups[i]),
                        ),
                      ),
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
              Icon(Icons.show_chart, color: Colors.white54, size: 42),
              SizedBox(height: 12),
              Text('No completed tests yet',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text(
                'Finish a test (let the countdown run out) and its threshold '
                'appears on that patient\'s audiogram. Use the "New patient" '
                'button on a node to start a fresh group.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      );

  Widget _legendAndNote() {
    Widget item(Widget mark, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            const SizedBox(width: 5),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 18,
          runSpacing: 6,
          children: [
            item(const Icon(Icons.circle_outlined, color: _red, size: 16),
                'Right'),
            item(const Icon(Icons.close, color: _blue, size: 16), 'Left'),
            item(const Icon(Icons.circle, color: _grey, size: 13), 'Both'),
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          'Uncalibrated device dB (not dB HL). Quieter/better hearing is higher.',
          style: TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }

  Widget _groupCard(_PatientGroup g) {
    final border = AppTheme.nodeColor(g.nodeId);
    final onNode = AppTheme.onNodeColor(g.nodeId);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: border, width: 2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: AppTheme.paleCyan,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.person, size: 15, color: Color(0xFF00595E)),
                const SizedBox(width: 6),
                Text('Patient ${g.patientNo}',
                    style: const TextStyle(
                        color: Color(0xFF00595E),
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(_timeSpanLabel(g),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Color(0xFF00595E), fontSize: 11)),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                      color: border, borderRadius: BorderRadius.circular(6)),
                  child: Text(g.nodeId,
                      style: TextStyle(
                          color: onNode,
                          fontSize: 10,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 10, 10, 8),
            child: SizedBox(
              height: 240,
              child: CustomPaint(
                painter: _AudiogramPainter(g.series),
                size: Size.infinite,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _timeSpanLabel(_PatientGroup g) {
    final s = g.firstStart;
    if (s == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    final e = g.lastEnd ?? s;
    return '${two(s.month)}-${two(s.day)}  '
        '${two(s.hour)}:${two(s.minute)}~${two(e.hour)}:${two(e.minute)}';
  }
}

class _PatientGroup {
  final String nodeId;
  final int patientId;

  /// ear -> (frequency -> threshold dB)
  final Map<String, Map<double, double>> series = {};

  /// Start of the first test and end of the last test in this group, for the
  /// "date  HH:MM~HH:MM" header. patientNo is a running mark (1 = earliest).
  DateTime? firstStart;
  DateTime? lastEnd;
  int patientNo = 0;

  _PatientGroup(this.nodeId, this.patientId);
}

const _red = Color(0xFFD32F2F);
const _blue = Color(0xFF1976D2);
const _grey = Color(0xFF616161);

enum _Marker { circle, cross, dot }

class _AudiogramPainter extends CustomPainter {
  final Map<String, Map<double, double>> series;

  _AudiogramPainter(this.series);

  // Frequency axis (log), the audiometric octaves.
  static const _fMin = 125.0;
  static const _fMax = 8000.0;
  static const _labelFreqs = <double>[125, 250, 500, 1000, 2000, 4000, 8000];

  // Level axis (device dB): quieter/better at the top, louder/worse at the bottom
  // -- the same orientation a clinical audiogram uses for dB HL.
  static const _dbTop = -120.0;
  static const _dbBottom = 0.0;
  static const _dbGrid = <double>[-120, -100, -80, -60, -40, -20, 0];

  @override
  void paint(Canvas canvas, Size size) {
    const padL = 40.0, padR = 10.0, padT = 6.0, padB = 24.0;
    final plot =
        Rect.fromLTRB(padL, padT, size.width - padR, size.height - padB);
    if (plot.width <= 0 || plot.height <= 0) return;

    final grid = Paint()
      ..color = const Color(0xFFECEFF1)
      ..strokeWidth = 1;
    final axis = Paint()
      ..color = const Color(0xFFB0BEC5)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    double xFor(double f) {
      final t = (math.log(f) - math.log(_fMin)) /
          (math.log(_fMax) - math.log(_fMin));
      return plot.left + t * plot.width;
    }

    double yFor(double db) =>
        plot.top + (db - _dbTop) / (_dbBottom - _dbTop) * plot.height;

    for (final db in _dbGrid) {
      final y = yFor(db);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final t = _label('${db.toInt()}');
      t.paint(canvas, Offset(plot.left - t.width - 5, y - t.height / 2));
    }
    for (final f in _labelFreqs) {
      final x = xFor(f);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      final t = _label(AppTheme.formatHz(f));
      t.paint(canvas, Offset(x - t.width / 2, plot.bottom + 5));
    }
    canvas.drawRect(plot, axis);

    _drawSeries(canvas, series['R'], _red, _Marker.circle, xFor, yFor);
    _drawSeries(canvas, series['L'], _blue, _Marker.cross, xFor, yFor);
    for (final e in series.entries) {
      if (e.key == 'R' || e.key == 'L') continue;
      _drawSeries(canvas, e.value, _grey, _Marker.dot, xFor, yFor);
    }
  }

  void _drawSeries(
    Canvas canvas,
    Map<double, double>? data,
    Color color,
    _Marker marker,
    double Function(double) xFor,
    double Function(double) yFor,
  ) {
    if (data == null || data.isEmpty) return;
    final freqs = data.keys.toList()..sort();
    final line = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    Offset? prev;
    for (final f in freqs) {
      final db = data[f]!.clamp(_dbTop, _dbBottom);
      final pt = Offset(xFor(f), yFor(db));
      if (prev != null) canvas.drawLine(prev, pt, line);
      prev = pt;
    }
    for (final f in freqs) {
      final db = data[f]!.clamp(_dbTop, _dbBottom);
      _marker(canvas, Offset(xFor(f), yFor(db)), color, marker);
    }
  }

  void _marker(Canvas c, Offset o, Color color, _Marker m) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    const r = 5.0;
    switch (m) {
      case _Marker.circle:
        c.drawCircle(o, r, stroke);
        break;
      case _Marker.cross:
        c.drawLine(o.translate(-r, -r), o.translate(r, r), stroke);
        c.drawLine(o.translate(-r, r), o.translate(r, -r), stroke);
        break;
      case _Marker.dot:
        c.drawCircle(o, r - 1, Paint()..color = color);
        break;
    }
  }

  TextPainter _label(String s) => TextPainter(
        text: TextSpan(
            text: s,
            style: const TextStyle(color: Color(0xFF546E7A), fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  bool shouldRepaint(covariant _AudiogramPainter old) => true;
}
