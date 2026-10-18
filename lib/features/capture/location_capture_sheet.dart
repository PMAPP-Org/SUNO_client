// Hoja "Obtener ubicación" (Fase A, GPS fiable).
//
// En vez de guardar la primera lectura a ciegas, el agente ve en vivo la
// precisión y cuántas lecturas buenas lleva (como QField). La hoja:
// - se cierra sola con el promedio cuando llega a la precisión objetivo;
// - deja "Usar esta ubicación" en cualquier momento con lo que haya, avisando
//   si la precisión es baja o la posición es simulada;
// - si el GPS está apagado o falta el permiso, lo dice y abre los ajustes.
//
// Devuelve `null` si el agente cancela o no hay señal: la visita se puede
// guardar sin ubicación.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/location/coordinate_system.dart';
import '../../core/location/gps_sampler.dart';
import '../../core/location/location_source.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_page_body.dart';

Future<LocationFix?> showLocationCaptureSheet(
  BuildContext context, {
  required LocationSource source,
  required GpsPolicy policy,
  CoordinateSystem coordinateSystem = CoordinateSystem.wgs84,
}) => showModalBottomSheet<LocationFix>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => LocationCaptureSheet(source: source, policy: policy, coordinateSystem: coordinateSystem),
);

class LocationCaptureSheet extends StatefulWidget {
  const LocationCaptureSheet({
    super.key,
    required this.source,
    required this.policy,
    this.coordinateSystem = CoordinateSystem.wgs84,
  });

  final LocationSource source;
  final GpsPolicy policy;

  /// En qué sistema se muestran las coordenadas (Fase C).
  final CoordinateSystem coordinateSystem;

  @override
  State<LocationCaptureSheet> createState() => _LocationCaptureSheetState();
}

class _LocationCaptureSheetState extends State<LocationCaptureSheet> {
  LocationStatus? _status;
  GpsReading? _reading;
  StreamSubscription<GpsReading>? _sampling;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    // Cerrar la hoja apaga el GPS.
    unawaited(_sampling?.cancel());
    super.dispose();
  }

  Future<void> _start() async {
    await _sampling?.cancel();
    setState(() {
      _status = null;
      _reading = null;
    });
    final status = await widget.source.ensureReady();
    if (!mounted) return;
    setState(() => _status = status);
    if (status != LocationStatus.ready) return;
    _sampling = GpsSampler(widget.policy).sample(widget.source).listen((
      reading,
    ) {
      if (!mounted) return;
      setState(() => _reading = reading);
      // Objetivo alcanzado y posición real: no hace falta que el agente pulse.
      if (reading.done && !reading.timedOut && !reading.isMocked) _use();
    });
  }

  void _use() => Navigator.of(context).pop(_reading?.fix);

  Future<void> _openSettings() async {
    final status = _status;
    if (status == null) return;
    await widget.source.openSettings(status);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = _status;
    return SafeArea(
      // Desplazable: en teléfonos pequeños o con letra grande no se corta.
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.page,
            right: AppSpacing.page,
            bottom: AppSpacing.page,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.gpsTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const AppGap.sm(),
              if (status == null)
                const Center(child: CircularProgressIndicator())
              else if (status != LocationStatus.ready)
                ..._notReady(l10n, status)
              else
                ..._sampled(l10n),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _notReady(AppLocalizations l10n, LocationStatus status) => [
    Text(switch (status) {
      LocationStatus.serviceDisabled => l10n.gpsServiceDisabled,
      LocationStatus.permissionDenied => l10n.gpsPermissionDenied,
      _ => l10n.gpsPermissionDeniedForever,
    }, key: const Key('gps_not_ready')),
    const AppGap.sm(),
    if (status != LocationStatus.permissionDenied)
      FilledButton(
        key: const Key('gps_open_settings'),
        onPressed: _openSettings,
        child: Text(l10n.gpsOpenSettings),
      ),
    OutlinedButton(
      key: const Key('gps_retry'),
      onPressed: _start,
      child: Text(l10n.gpsRetry),
    ),
    TextButton(
      key: const Key('gps_cancel'),
      onPressed: () => Navigator.of(context).pop(),
      child: Text(l10n.gpsCancel),
    ),
  ];

  List<Widget> _sampled(AppLocalizations l10n) {
    final reading = _reading;
    final fix = reading?.fix;
    final policy = widget.policy;
    final warning = context.statusColors.warning;
    return [
      if (fix == null)
        Text(l10n.gpsSearching, key: const Key('gps_searching'))
      else ...[
        Text(
          l10n.gpsAccuracy(fix.accuracyM.round()),
          key: const Key('gps_accuracy'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(widget.coordinateSystem.format(fix.lat, fix.lon), key: const Key('gps_coordinates')),
      ],
      const AppGap.sm(),
      LinearProgressIndicator(
        value: reading == null ? null : reading.goodSamples / policy.samples,
      ),
      Text(
        l10n.gpsSamples(
          reading?.goodSamples ?? 0,
          policy.samples,
          policy.targetAccuracyM.round(),
        ),
        key: const Key('gps_samples'),
      ),
      if (reading != null && fix != null && !reading.meetsTarget) ...[
        const AppGap.sm(),
        Text(
          reading.done
              ? l10n.gpsTimedOut(policy.targetAccuracyM.round())
              : l10n.gpsLowAccuracy,
          key: const Key('gps_low_accuracy'),
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: warning),
        ),
      ],
      if (reading?.isMocked ?? false) ...[
        const AppGap.sm(),
        Text(
          l10n.gpsMocked,
          key: const Key('gps_mocked'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ],
      if (reading != null && reading.done && fix == null) ...[
        const AppGap.sm(),
        Text(l10n.gpsNoSignal, key: const Key('gps_no_signal')),
      ],
      const AppGap.lg(),
      FilledButton(
        key: const Key('gps_use'),
        onPressed: fix == null ? null : _use,
        child: Text(l10n.gpsUse),
      ),
      if (reading != null && reading.done)
        OutlinedButton(
          key: const Key('gps_retry'),
          onPressed: _start,
          child: Text(l10n.gpsRetry),
        ),
      TextButton(
        key: const Key('gps_cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.gpsCancel),
      ),
    ];
  }
}
