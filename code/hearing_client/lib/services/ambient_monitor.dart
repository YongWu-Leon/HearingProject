import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:noise_meter/noise_meter.dart';
import 'package:permission_handler/permission_handler.dart';

import 'kalman.dart';

/// Watches ambient noise through the phone's microphone and reports a smoothed
/// level, so the operator is warned when the room is too loud for a valid
/// screening.
///
/// A portable hearing test has no sound booth, so ambient noise is the biggest
/// threat to the result's validity -- this is the same "check your environment"
/// feature that clinical portable-audiometry apps provide. The raw dB stream
/// from the microphone is jittery, so it is smoothed by a scalar [KalmanFilter]
/// into a steady reading without the lag of a long moving average.
class AmbientMonitor extends ChangeNotifier {
  /// Above this smoothed level the environment is flagged as too noisy. This is
  /// an uncalibrated device figure (not a dB SPL limit); tune it on real
  /// hardware against a sound-level meter.
  final double warnDb;

  AmbientMonitor({this.warnDb = 70});

  final KalmanFilter _filter = KalmanFilter();
  NoiseMeter? _meter;
  StreamSubscription<NoiseReading>? _sub;

  double _smoothed = 0;
  bool _running = false;
  String? _error;

  /// Kalman-smoothed ambient level in (uncalibrated) dB.
  double get smoothedDb => _smoothed;
  bool get running => _running;
  String? get error => _error;

  /// True once we have a real estimate that sits above [warnDb].
  bool get tooNoisy => _running && _filter.hasEstimate && _smoothed > warnDb;

  /// True once at least one reading has been smoothed.
  bool get hasReading => _filter.hasEstimate;

  // --- per-test window -----------------------------------------------------
  // A single reading taken when a test ends says little: the room may have been
  // quiet at that instant and loud throughout. So each test opens a window here
  // and the loudest smoothed level inside it is what gets recorded with the
  // result. Tests are never blocked -- the environment is reported, not policed,
  // and whether to keep a noisy measurement is a decision for analysis.

  double? _windowPeakDb;
  bool _windowExceeded = false;

  /// Loudest smoothed level seen since [beginWindow], or null if none.
  double? get windowPeakDb => _windowPeakDb;

  /// Whether [warnDb] was exceeded at any point in the current window.
  bool get windowExceeded => _windowExceeded;

  void beginWindow() {
    _windowPeakDb = null;
    _windowExceeded = false;
  }

  /// Request microphone permission and begin monitoring. Safe to call twice.
  Future<void> start() async {
    if (_running) return;
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _error = 'Microphone permission denied';
      notifyListeners();
      return;
    }
    try {
      _meter = NoiseMeter();
      _sub = _meter!.noise.listen(_onReading, onError: _onError, cancelOnError: true);
      _running = true;
      _error = null;
      notifyListeners();
    } catch (e) {
      _error = 'Cannot start microphone: $e';
      notifyListeners();
    }
  }

  void _onReading(NoiseReading reading) {
    final z = reading.meanDecibel;
    if (z.isNaN || z.isInfinite) return;
    _smoothed = _filter.update(z);
    if (_windowPeakDb == null || _smoothed > _windowPeakDb!) {
      _windowPeakDb = _smoothed;
    }
    if (_smoothed > warnDb) _windowExceeded = true;
    notifyListeners();
  }

  void _onError(Object e) {
    _error = 'Microphone error: $e';
    _running = false;
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _meter = null;
    _running = false;
    _filter.reset();
    _smoothed = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
