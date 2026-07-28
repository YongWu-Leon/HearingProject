/// A minimal scalar (1-D) Kalman filter.
///
/// It estimates a single, slowly-varying quantity -- here the ambient noise
/// level in dB -- from a stream of noisy measurements. Every step blends the
/// previous estimate (the prediction) with the new measurement, weighting each
/// by its uncertainty, so the output is far steadier than the raw microphone
/// readings but without the lag of a long moving average.
///
/// Model: a random walk. The true value is assumed to drift a little between
/// samples (process-noise variance [q]); every measurement carries noise
/// (measurement-noise variance [r]).
///   - larger [q]  -> trust new readings more   (faster to react, jumpier)
///   - larger [r]  -> trust the estimate more   (smoother, slower to react)
///
/// The two-line predict/update core is the standard 1-D Kalman recursion:
///   predict:  P += Q
///   update :  K = P / (P + R);  x += K*(z - x);  P *= (1 - K)
class KalmanFilter {
  /// Process-noise variance: how much the true value may drift per step.
  final double q;

  /// Measurement-noise variance: how noisy a single reading is.
  final double r;

  double _x = 0; // current estimate
  double _p = 1; // estimate error covariance
  bool _seeded = false;

  KalmanFilter({this.q = 0.08, this.r = 4.0});

  /// The current smoothed estimate.
  double get value => _x;

  /// False until the first measurement has seeded the filter.
  bool get hasEstimate => _seeded;

  /// Feed one measurement and return the updated estimate.
  double update(double measurement) {
    if (!_seeded) {
      // Seed on the first reading so the estimate starts at the signal instead
      // of crawling up from zero.
      _x = measurement;
      _p = r;
      _seeded = true;
      return _x;
    }
    // Predict: random walk leaves the estimate unchanged but grows uncertainty.
    _p += q;
    // Update: Kalman gain, then pull the estimate towards the measurement.
    final k = _p / (_p + r);
    _x += k * (measurement - _x);
    _p *= (1 - k);
    return _x;
  }

  /// Forget all history so the next measurement re-seeds the filter.
  void reset() {
    _x = 0;
    _p = 1;
    _seeded = false;
  }
}
