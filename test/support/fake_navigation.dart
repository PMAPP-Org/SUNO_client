import 'dart:async';

import 'package:visitacampo/core/location/location_source.dart';
import 'package:visitacampo/core/location/navigation_target.dart';

class FakeNavigationGps implements LocationSource {
  final controller = StreamController<LocationFix>.broadcast();
  LocationStatus status = LocationStatus.ready;
  Future<LocationStatus>? pendingPermission;
  bool failReadiness = false;
  bool failSettings = false;
  int permissionChecks = 0;
  LocationStatus? settingsOpened;

  Future<void> close() => controller.close();

  @override
  Future<LocationStatus> ensureReady() async {
    permissionChecks++;
    if (failReadiness) throw StateError('GPS unavailable');
    return pendingPermission ?? status;
  }

  @override
  Stream<LocationFix> watch() => controller.stream;

  @override
  Future<void> openSettings(LocationStatus status) async {
    if (failSettings) throw StateError('Settings unavailable');
    settingsOpened = status;
  }
}

class FakeRouteLauncher implements RouteLauncher {
  final opened = <NavigationTarget>[];
  bool result = true;
  bool throws = false;
  Completer<bool>? pending;

  @override
  Future<bool> open(NavigationTarget target) async {
    opened.add(target);
    if (throws) throw StateError('Launcher unavailable');
    return pending?.future ?? result;
  }
}
