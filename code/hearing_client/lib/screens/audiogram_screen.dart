import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/node_session.dart';
import '../services/db.dart';
import '../theme.dart';

/// Audiogram view: the subject's hearing threshold plotted against frequency in
/// the conventional clinical layout -- log frequency across the bottom, and
/// quieter (better) hearing towards the top. Right ear = red circles, left ear =
/// blue crosses, unspecified/both = grey dots, following audiometric convention.
///
/// IMPORTANT: the vertical axis is the device's own digital full-scale dB, NOT
/// calibrated dB HL, and it is labelled as such. Once the transducer is
/// calibrated (a per-frequency offset), the same plot becomes a real dB HL
/// audiogram with no change to this screen beyond the axis label.
class AudiogramScreen extends StatefulWidget {
  /// null shows every node's data together.
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

  /// ear -> (frequency -> threshold dB), keeping the most recent test for each
  /// frequency. loadTests returns newest first, so the first value we see for a
  /// frequency is the newest and putIfAbsent keeps it.
  Map<String, Map<double, double>> _series() {
    final out = <String, Map<double, double>>{};
    for (final t in _tests) {
      if (!t.isComplete || t.thresholdDb == null) continue;
      out.putIfAbsent(t.ear, () => {}).putIfAbsent(t.freqHz, () => t.thresholdDb!);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final series = _series();
    final hasData = series.values.any((m) => m.isNotEmpty);
    return Scaffold(
      appBar: AppBar(
        title: Text(
            widget.nodeId == null ? 'Audiogram' : 'Audiogram - ${widget.nodeId}'),
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
            : !hasData
                ? _empty()
                : _chart(series),
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
                'appears on the audiogram.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ),
      );

  Widget _chart(Map<String, Map<double, double>> series) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _legend(),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(4, 12, 12, 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: CustomPaint(
                painter: _AudiogramPainter(series),
                size: Size.infinite,
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Vertical axis is uncalibrated device dB (digital full scale), not '
            'clinical dB HL. Quieter (better) hearing is towards the top.',
            style: TextStyle(color: Colors.white, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _legend() {
    Widget item(Widget mark, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark,
            const SizedBox(width: 5),
            Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 12)),
          ],
        );
    return Wrap(
      spacing: 18,
      runSpacing: 6,
      children: [
        item(const Icon(Icons.circle_outlined, color: _red, size: 16), 'Right'),
        item(const Icon(Icons.close, color: _blue, size: 16), 'Left'),
        item(const Icon(Icons.circle, color: _grey, size: 13), 'Both'),
      ],
    );
  }
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
  static const _dbTop = -80.0;
  static const _dbBottom = 0.0;
  static const _dbGrid = <double>[-80, -60, -40, -20, 0];

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

    // Horizontal dB gridlines + labels down the left edge.
    for (final db in _dbGrid) {
      final y = yFor(db);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final t = _label('${db.toInt()}');
      t.paint(canvas, Offset(plot.left - t.width - 5, y - t.height / 2));
    }
    // Vertical frequency gridlines + labels along the bottom.
    for (final f in _labelFreqs) {
      final x = xFor(f);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      final t = _label(AppTheme.formatHz(f));
      t.paint(canvas, Offset(x - t.width / 2, plot.bottom + 5));
    }
    canvas.drawRect(plot, axis);

    // Series. Right and left first (named colours + clinical markers), then any
    // 'both'/unspecified ears as grey dots.
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
