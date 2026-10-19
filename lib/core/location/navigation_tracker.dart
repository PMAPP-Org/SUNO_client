import 'dart:async';

import 'package:flutter/foundation.dart';

import 'location_source.dart';
import 'navigation_target.dart';

enum NavigationStatus { checking, tracking, serviceDisabled, permissionDenied, permissionDeniedForever, noSignal }

/// GPS de primer plano. Descarta lecturas inválidas y caduca la última
/// posición para no presentar un rumbo antiguo como si siguiera en vivo.
class NavigationTracker extends ChangeNotifier {
  NavigationTracker(this.source);

  static const signalTimeout = Duration(seconds: 30);
  final LocationSource source;
  NavigationStatus status = NavigationStatus.checking;
  LocationFix? fix;
  StreamSubscription<LocationFix>? _subscription;
  Timer? _expiry;
  int _generation = 0;
  bool _disposed = false;

  Future<void> start() async {
    final generation = ++_generation;
    _expiry?.cancel();
    final previous = _subscription;
    _subscription = null;
    fix = null;
    status = NavigationStatus.checking;
    notifyListeners();
    await previous?.cancel();
    if (!_current(generation)) return;
    try {
      final ready = await source.ensureReady();
      if (!_current(generation)) return;
      status = switch (ready) {
        LocationStatus.ready => NavigationStatus.tracking,
        LocationStatus.serviceDisabled => NavigationStatus.serviceDisabled,
        LocationStatus.permissionDenied => NavigationStatus.permissionDenied,
        LocationStatus.permissionDeniedForever => NavigationStatus.permissionDeniedForever,
      };
      notifyListeners();
      if (ready != LocationStatus.ready) return;
      _armExpiry(generation);
      _subscription = source.watch().listen(
        (reading) {
          if (!_current(generation) ||
              NavigationTarget.tryCreate(reading.lat, reading.lon) == null ||
              !reading.accuracyM.isFinite ||
              reading.accuracyM < 0) {
            return;
          }
          fix = reading;
          status = NavigationStatus.tracking;
          _armExpiry(generation);
          notifyListeners();
        },
        onError: (Object error, StackTrace stack) => _lost(generation),
        onDone: () => _lost(generation),
      );
    } on Object {
      _lost(generation);
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  void _armExpiry(int generation) {
    _expiry?.cancel();
    _expiry = Timer(signalTimeout, () {
      if (!_current(generation)) return;
      fix = null;
      status = NavigationStatus.noSignal;
      notifyListeners();
    });
  }

  void _lost(int generation) {
    if (!_current(generation)) return;
    stop();
    status = NavigationStatus.noSignal;
    notifyListeners();
  }

  void stop() {
    ++_generation;
    _expiry?.cancel();
    unawaited(_subscription?.cancel());
    _subscription = null;
    fix = null;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
