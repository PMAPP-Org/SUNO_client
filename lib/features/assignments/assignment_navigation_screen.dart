import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location/location_source.dart';
import '../../core/location/navigation_target.dart';
import '../../core/location/navigation_tracker.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_page_body.dart';

/// Orientación local al punto planificado. No registra una visita ni cambia
/// la asignación; el azimut se refiere al norte, no a la postura del teléfono.
class AssignmentNavigationScreen extends ConsumerStatefulWidget {
  const AssignmentNavigationScreen({super.key, required this.target, required this.title});

  final NavigationTarget target;
  final String title;

  @override
  ConsumerState<AssignmentNavigationScreen> createState() => _AssignmentNavigationScreenState();
}

class _AssignmentNavigationScreenState extends ConsumerState<AssignmentNavigationScreen> with WidgetsBindingObserver {
  late final NavigationTracker _tracker;
  bool _suspended = false;
  bool _opening = false;
  bool _launchFailed = false;
  bool _settingsFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tracker = NavigationTracker(ref.read(appDependenciesProvider).locationSource)..addListener(_changed);
    unawaited(_tracker.start());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      _suspended = true;
      _tracker.stop();
    } else if (state == AppLifecycleState.resumed && _suspended) {
      _suspended = false;
      unawaited(_tracker.start());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tracker.dispose();
    super.dispose();
  }

  Future<void> _openRoute() async {
    setState(() {
      _opening = true;
      _launchFailed = false;
    });
    var opened = false;
    try {
      opened = await ref.read(appDependenciesProvider).routeLauncher.open(widget.target);
    } on Object {
      // Una app externa ausente o un fallo de plataforma no cierran SUNO.
    }
    if (!mounted) return;
    setState(() {
      _opening = false;
      _launchFailed = !opened;
    });
  }

  Future<void> _openSettings() async {
    setState(() => _settingsFailed = false);
    try {
      await _tracker.source.openSettings(
        _tracker.status == NavigationStatus.serviceDisabled
            ? LocationStatus.serviceDisabled
            : LocationStatus.permissionDeniedForever,
      );
    } on Object {
      if (mounted) setState(() => _settingsFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dependencies = ref.read(appDependenciesProvider);
    final fix = _tracker.fix;
    final distance = fix == null ? null : widget.target.distanceFrom(fix);
    // Dentro del margen de error no se presenta una dirección engañosa ni
    // se declara cumplida la asignación. La visita se inicia aparte.
    final near = fix != null && distance! <= math.max(fix.accuracyM, 1);
    final bearing = fix == null || near ? null : widget.target.bearingFrom(fix);
    final status = _tracker.status;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.navigationTitle)),
      body: AppPageBody(
        children: [
          Text(widget.title, style: textTheme.titleLarge),
          const AppGap.sm(),
          Text(l10n.navigationDestination),
          SelectableText(
            dependencies.coordinates.current.value.format(widget.target.lat, widget.target.lon),
            key: const Key('navigation_destination'),
          ),
          const AppGap.lg(),
          if (fix != null) ...[
            Text(
              l10n.navigationDistance(distance!.round()),
              key: const Key('navigation_distance'),
              style: textTheme.headlineSmall,
            ),
            Text(l10n.gpsAccuracy(fix.accuracyM.round())),
            const AppGap.sm(),
            if (near)
              Text(l10n.navigationNear, key: const Key('navigation_near'))
            else if (bearing != null) ...[
              ExcludeSemantics(
                child: Transform.rotate(
                  angle: bearing * math.pi / 180,
                  child: const Icon(Icons.navigation, size: AppSizes.navigationArrow),
                ),
              ),
              Text(
                l10n.navigationBearing(bearing.round() % 360),
                key: const Key('navigation_bearing'),
                textAlign: TextAlign.center,
                style: textTheme.titleLarge,
              ),
            ] else
              Text(l10n.navigationNoBearing),
            if (fix.accuracyM > dependencies.gpsPolicy.targetAccuracyM) ...[
              const AppGap.sm(),
              Text(l10n.navigationLowAccuracy, key: const Key('navigation_low_accuracy')),
            ],
            if (fix.isMocked) ...[const AppGap.sm(), Text(l10n.gpsMocked, key: const Key('navigation_mocked'))],
          ] else
            Text(switch (status) {
              NavigationStatus.checking => l10n.navigationChecking,
              NavigationStatus.tracking => l10n.navigationSearching,
              NavigationStatus.serviceDisabled => l10n.gpsServiceDisabled,
              NavigationStatus.permissionDenied => l10n.navigationPermissionDenied,
              NavigationStatus.permissionDeniedForever => l10n.gpsPermissionDeniedForever,
              NavigationStatus.noSignal => l10n.navigationNoSignal,
            }, key: const Key('navigation_status')),
          const AppGap.sm(),
          Text(l10n.navigationNorthHint),
          if (status == NavigationStatus.serviceDisabled || status == NavigationStatus.permissionDeniedForever)
            OutlinedButton(
              key: const Key('navigation_settings'),
              onPressed: _openSettings,
              child: Text(l10n.gpsOpenSettings),
            ),
          if (_settingsFailed) Text(l10n.navigationSettingsFailed),
          if (status != NavigationStatus.checking && status != NavigationStatus.tracking)
            OutlinedButton(key: const Key('navigation_retry'), onPressed: _tracker.start, child: Text(l10n.gpsRetry)),
          const AppGap.lg(),
          FilledButton.icon(
            key: const Key('navigation_external'),
            onPressed: _opening ? null : _openRoute,
            icon: const Icon(Icons.open_in_new),
            label: Text(l10n.navigationExternal),
          ),
          Text(l10n.navigationExternalHint, style: textTheme.bodySmall),
          if (_launchFailed) ...[
            const AppGap.sm(),
            Text(l10n.navigationLaunchFailed, key: const Key('navigation_launch_failed')),
          ],
        ],
      ),
    );
  }
}
