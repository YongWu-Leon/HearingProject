import 'package:flutter_test/flutter_test.dart';
import 'package:hearing_client/services/kalman.dart';

void main() {
  test('seeds on the first measurement instead of crawling up from zero', () {
    final k = KalmanFilter();
    expect(k.hasEstimate, isFalse);
    expect(k.update(42), 42);
    expect(k.hasEstimate, isTrue);
    expect(k.value, 42);
  });

  test('smooths a noisy constant signal towards its mean', () {
    final k = KalmanFilter();
    const truth = 50.0;
    const noisy = <double>[54, 46, 53, 47, 52, 48, 51, 49, 50, 50];
    var last = 0.0;
    for (final z in noisy) {
      last = k.update(z);
    }
    expect((last - truth).abs(), lessThan(2.0));
  });

  test('tracks a step change, but not in a single sample', () {
    final k = KalmanFilter();
    for (var i = 0; i < 40; i++) {
      k.update(20);
    }
    expect((k.value - 20).abs(), lessThan(1.0));
    // A jump in the input must not jump the estimate all the way at once.
    final afterOne = k.update(60);
    expect(afterOne, greaterThan(20));
    expect(afterOne, lessThan(60));
  });

  test('reset forgets history so the next reading re-seeds', () {
    final k = KalmanFilter();
    k.update(10);
    k.reset();
    expect(k.hasEstimate, isFalse);
    expect(k.update(99), 99);
  });
}
