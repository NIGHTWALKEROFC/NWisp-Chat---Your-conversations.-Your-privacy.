import 'dart:async';
import 'dart:math';
import 'package:sensors_plus/sensors_plus.dart';

/// Feature: "shake to lock". Watches the phone's accelerometer and calls
/// [onShake] after a deliberate shake — three sharp jolts within about a
/// second and a half. A single bump, putting the phone down, or walking
/// with it in a pocket does not count.
///
/// Only ever running while it's needed: the lock gate (auth_gate.dart)
/// starts it when the app is unlocked, in the foreground, and the person has
/// switched "Shake to lock" on in Settings > Security, and stops it
/// otherwise — so it isn't quietly draining battery or listening to the
/// sensor the rest of the time.
class ShakeDetector {
  final void Function() onShake;
  ShakeDetector({required this.onShake});

  StreamSubscription<AccelerometerEvent>? _sub;
  final List<DateTime> _spikes = [];
  DateTime? _lastSpike;
  DateTime? _cooldownUntil;

  // A phone lying still reads 1 g. A hard shake easily reaches 2.5-4 g.
  static const double _spikeThresholdG = 2.6;
  static const Duration _minGapBetweenSpikes = Duration(milliseconds: 180);
  static const Duration _window = Duration(milliseconds: 1500);
  static const Duration _cooldown = Duration(seconds: 2);
  static const int _spikesNeeded = 3;

  bool get isRunning => _sub != null;

  void start() {
    if (_sub != null) return;
    try {
      _sub = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen(
        _onEvent,
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {
      // No accelerometer, or the OS refused — shake-to-lock just won't work
      // on this phone; the Lock now button still does.
      _sub = null;
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _spikes.clear();
    _lastSpike = null;
  }

  void _onEvent(AccelerometerEvent e) {
    final now = DateTime.now();
    final cooldownUntil = _cooldownUntil;
    if (cooldownUntil != null && now.isBefore(cooldownUntil)) return;

    final g = sqrt(e.x * e.x + e.y * e.y + e.z * e.z) / 9.80665;
    if (g < _spikeThresholdG) return;

    final last = _lastSpike;
    if (last != null && now.difference(last) < _minGapBetweenSpikes) return;
    _lastSpike = now;

    _spikes.removeWhere((t) => now.difference(t) > _window);
    _spikes.add(now);
    if (_spikes.length >= _spikesNeeded) {
      _spikes.clear();
      _cooldownUntil = now.add(_cooldown);
      onShake();
    }
  }
}
