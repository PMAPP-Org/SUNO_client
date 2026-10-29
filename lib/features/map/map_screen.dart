// Mapa (Fase B): dónde están las visitas del teléfono, las asignaciones del
// agente y él mismo, como en QField. Todo sale de la BD local: funciona sin
// red.
//
// - Visitas: por color según su sincronización (pendiente / sincronizada /
//   rechazada).
// - Asignaciones del agente con punto: pendiente o hecha.
// - Mi posición en vivo mientras el mapa está abierto (el GPS se apaga al
//   salir).
//
// El mapa base offline (paquetes por organización) llega en B3; sin él, el
// fondo es liso y los puntos siguen siendo útiles para orientarse entre sí.
// **No se piden teselas a servidores de terceros**: el teléfono del agente no
// le cuenta a nadie dónde está trabajando.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/auth/auth_state.dart';
import '../../core/basemaps/basemap_manager.dart';
import '../../core/forms/geometry.dart';
import '../../core/layers/layer_manager.dart';
import '../../core/location/location_source.dart';
import '../../core/providers.dart';
import '../../data/local/assignment_repository.dart';
import '../../data/map/mbtiles_tile_provider.dart';
import '../../data/local/visit_status_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_colors.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_page_body.dart';
import '../capture/capture_screen.dart';
import '../assignments/assignment_navigation_screen.dart';
import '../visits/visit_detail_screen.dart';

/// Centro por defecto sin ningún punto: Bogotá.
const _fallbackCenter = LatLng(4.6097, -74.0817);

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  final _controller = MapController();
  List<MapVisit>? _visits;
  List<AssignmentItem> _assignments = const [];
  LocationFix? _me;

  /// Mapas base descargados (B3), con su lector de teselas abierto.
  List<({BasemapInfo info, MbtilesTileProvider tiles})> _basemaps = const [];

  /// Entidades de las capas de referencia descargadas (Fase C).
  List<LayerFeature> _features = const [];
  final _layerHits = LayerHitNotifier<LayerFeature>(null);
  StreamSubscription<LocationFix>? _position;
  int _gpsGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_follow());
  }

  @override
  void dispose() {
    ++_gpsGeneration;
    unawaited(_position?.cancel());
    _controller.dispose();
    _layerHits.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final dependencies = ref.read(appDependenciesProvider);
    final auth = dependencies.authController.state;
    if (auth is! Authenticated) return;
    final visits = await dependencies.visitStatus.mapVisits(orgId: auth.user.orgId);
    final assignments = await dependencies.assignments.forUser(orgId: auth.user.orgId, userId: auth.user.id);
    if (_basemaps.isEmpty) {
      final downloaded = await dependencies.basemaps.downloaded();
      final opened = <({BasemapInfo info, MbtilesTileProvider tiles})>[];
      for (final entry in downloaded) {
        try {
          opened.add((info: entry.info, tiles: MbtilesTileProvider(entry.localPath!)));
        } on Object {
          // Un archivo que no abre no tumba el mapa: se omite esa capa.
        }
      }
      if (!mounted) {
        for (final b in opened) {
          unawaited(b.tiles.dispose());
        }
        return;
      }
      _basemaps = opened;
    }
    if (_features.isEmpty) {
      final features = <LayerFeature>[];
      for (final entry in await dependencies.layers.downloaded()) {
        features.addAll(await dependencies.layers.features(entry));
      }
      _features = features;
    }
    if (!mounted) return;
    setState(() {
      _visits = visits;
      _assignments = [
        for (final a in assignments)
          if (a.hasPoint) a,
      ];
    });
  }

  /// Mi posición en vivo. Sin permiso o con el GPS apagado, el mapa funciona
  /// igual sin ella.
  Future<void> _follow() async {
    final generation = ++_gpsGeneration;
    final source = ref.read(appDependenciesProvider).locationSource;
    if (await source.ensureReady() != LocationStatus.ready || !mounted || generation != _gpsGeneration) return;
    _position = source.watch().listen((fix) {
      if (mounted) setState(() => _me = fix);
    });
  }

  void _centerOnMe() {
    final me = _me;
    if (me != null) _controller.move(LatLng(me.lat, me.lon), 17);
  }

  Future<void> _openVisit(String visitId) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => VisitDetailScreen(visitId: visitId)));
    await _load();
  }

  Future<void> _openAssignment(AssignmentItem item) async {
    final visitId = item.visitId;
    if (visitId != null) return _openVisit(visitId);
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CaptureScreen(assignmentId: item.id)));
    await _load();
  }

  Future<void> _showVisit(VisitSummary visit) => _sheet(
    title: visit.templateName ?? context.l10n.homeVisitUntitled,
    subtitle: _statusLabel(context.l10n, visit.status),
    action: context.l10n.mapOpenVisit,
    onAction: () => _openVisit(visit.id),
  );

  Future<void> _showAssignment(AssignmentItem item) {
    final l10n = context.l10n;
    return _sheet(
      title: item.title ?? item.templateName ?? l10n.homeVisitUntitled,
      subtitle: item.done ? l10n.assignmentDone : l10n.assignmentPending,
      action: item.done ? l10n.mapOpenVisit : l10n.mapStartVisit,
      onAction: () => _openAssignment(item),
      onNavigate: item.navigationTarget == null ? null : () => _navigate(item),
    );
  }

  Future<void> _navigate(AssignmentItem item) async {
    // La pantalla de navegación toma el GPS; al volver lo recupera el mapa,
    // solo si ya lo tenía: sin permiso, volver no repite la pregunta.
    final wasFollowing = _position != null;
    ++_gpsGeneration;
    await _position?.cancel();
    _position = null;
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AssignmentNavigationScreen(
          target: item.navigationTarget!,
          title: item.title ?? item.templateName ?? context.l10n.homeVisitUntitled,
        ),
      ),
    );
    if (mounted && wasFollowing) await _follow();
  }

  Future<void> _showFeature(LayerFeature feature) {
    final properties = feature.properties.entries.where((e) => e.value != null).take(30).toList();
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(left: AppSpacing.page, right: AppSpacing.page, bottom: AppSpacing.page),
          child: Column(
            key: const Key('map_feature_sheet'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(feature.title, style: Theme.of(sheetContext).textTheme.titleMedium),
              Text(feature.layerName, style: Theme.of(sheetContext).textTheme.bodySmall),
              const AppGap.sm(),
              for (final p in properties)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.key),
                  subtitle: Text(p.value.toString()),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _onLayerTap() {
    final hit = _layerHits.value;
    if (hit != null && hit.hitValues.isNotEmpty) {
      unawaited(_showFeature(hit.hitValues.first));
    }
  }

  Future<void> _sheet({
    required String title,
    required String subtitle,
    required String action,
    required Future<void> Function() onAction,
    Future<void> Function()? onNavigate,
  }) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(left: AppSpacing.page, right: AppSpacing.page, bottom: AppSpacing.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
            Text(subtitle),
            const AppGap.sm(),
            FilledButton(
              key: const Key('map_sheet_action'),
              onPressed: () {
                Navigator.of(sheetContext).pop();
                unawaited(onAction());
              },
              child: Text(action),
            ),
            if (onNavigate != null)
              OutlinedButton.icon(
                key: const Key('map_navigate'),
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(onNavigate());
                },
                icon: const Icon(Icons.directions),
                label: Text(context.l10n.navigationTitle),
              ),
          ],
        ),
      ),
    ),
  );

  static Color _statusColor(VisitSyncStatus s, AppStatusColors colors, ColorScheme scheme) => switch (s) {
    VisitSyncStatus.pending => colors.warning,
    VisitSyncStatus.synced => colors.success,
    VisitSyncStatus.rejected => scheme.error,
  };

  static String _statusLabel(AppLocalizations l10n, VisitSyncStatus status) => switch (status) {
    VisitSyncStatus.pending => l10n.visitStatusPending,
    VisitSyncStatus.synced => l10n.visitStatusSynced,
    VisitSyncStatus.rejected => l10n.visitStatusRejected,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final visits = _visits;
    final scheme = Theme.of(context).colorScheme;
    final status = context.statusColors;

    if (visits == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.mapTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final points = [for (final v in visits) LatLng(v.lat, v.lon), for (final a in _assignments) LatLng(a.lat!, a.lon!)];
    final me = _me;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.mapTitle)),
      floatingActionButton: me == null
          ? null
          : FloatingActionButton(
              key: const Key('map_center_me'),
              tooltip: l10n.mapCenterOnMe,
              onPressed: _centerOnMe,
              child: const Icon(Icons.my_location),
            ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              backgroundColor: scheme.surfaceContainerHighest,
              initialCenter: _fallbackCenter,
              initialZoom: 6,
              // Todos los puntos a la vista al abrir.
              initialCameraFit: points.isEmpty
                  ? null
                  : CameraFit.coordinates(
                      coordinates: points,
                      // Arriba, el espacio del aviso: que no tape ningún punto.
                      padding: const EdgeInsets.only(
                        left: AppSpacing.xl,
                        right: AppSpacing.xl,
                        bottom: AppSpacing.xl,
                        top: AppSpacing.xl * 3,
                      ),
                      maxZoom: 17,
                    ),
            ),
            children: [
              // Mapas base offline (B3), debajo de los puntos. Una tesela que
              // un paquete no tiene es transparente: los paquetes se apilan.
              for (final basemap in _basemaps)
                TileLayer(
                  key: ValueKey('map-basemap-${basemap.info.id}'),
                  tileProvider: basemap.tiles,
                  minNativeZoom: basemap.info.minZoom,
                  maxNativeZoom: basemap.info.maxZoom,
                  tileBounds: LatLngBounds(
                    LatLng(basemap.info.south, basemap.info.west),
                    LatLng(basemap.info.north, basemap.info.east),
                  ),
                ),
              // Capas de referencia (Fase C), sobre el mapa base y debajo de
              // las visitas; tocar una entidad muestra sus atributos.
              GestureDetector(
                onTap: _onLayerTap,
                child: PolygonLayer<LayerFeature>(
                  hitNotifier: _layerHits,
                  polygons: [
                    for (final f in _features)
                      for (final ring in f.polygons)
                        if (ring.length >= 3)
                          Polygon<LayerFeature>(
                            points: [for (final v in ring) LatLng(v.lat, v.lon)],
                            color: scheme.secondary.withValues(alpha: 0.12),
                            borderColor: scheme.secondary,
                            borderStrokeWidth: AppSizes.buttonProgressStroke,
                            hitValue: f,
                          ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: _onLayerTap,
                child: PolylineLayer<LayerFeature>(
                  hitNotifier: _layerHits,
                  polylines: [
                    for (final f in _features)
                      for (final line in f.lines)
                        if (line.length >= 2)
                          Polyline<LayerFeature>(
                            points: [for (final v in line) LatLng(v.lat, v.lon)],
                            color: scheme.secondary,
                            strokeWidth: AppSizes.buttonProgressStroke,
                            hitValue: f,
                          ),
                  ],
                ),
              ),
              MarkerLayer(
                markers: [
                  for (final f in _features)
                    for (final v in f.points)
                      Marker(
                        point: LatLng(v.lat, v.lon),
                        width: AppSizes.minTouchTarget,
                        height: AppSizes.minTouchTarget,
                        child: _Pin(
                          icon: Icons.place_outlined,
                          color: scheme.secondary,
                          label: f.title,
                          onTap: () => _showFeature(f),
                        ),
                      ),
                ],
              ),
              // Líneas y polígonos de las visitas (Fase C), con el color de
              // su sincronización, debajo de los puntos.
              PolygonLayer(
                polygons: [
                  for (final v in visits)
                    for (final g in v.geometries)
                      if (kindOf(g) == GeometryKind.polygon && verticesOf(g).length >= 3)
                        Polygon(
                          points: [for (final p in verticesOf(g)) LatLng(p.lat, p.lon)],
                          color: _statusColor(v.summary.status, status, scheme).withValues(alpha: 0.2),
                          borderColor: _statusColor(v.summary.status, status, scheme),
                          borderStrokeWidth: AppSizes.signatureStroke,
                        ),
                ],
              ),
              PolylineLayer(
                polylines: [
                  for (final v in visits)
                    for (final g in v.geometries)
                      if (kindOf(g) == GeometryKind.line && verticesOf(g).length >= 2)
                        Polyline(
                          points: [for (final p in verticesOf(g)) LatLng(p.lat, p.lon)],
                          color: _statusColor(v.summary.status, status, scheme),
                          strokeWidth: AppSizes.signatureStroke,
                        ),
                ],
              ),
              MarkerLayer(
                markers: [
                  for (final v in visits)
                    Marker(
                      key: ValueKey('map-visit-${v.summary.id}'),
                      point: LatLng(v.lat, v.lon),
                      width: AppSizes.minTouchTarget,
                      height: AppSizes.minTouchTarget,
                      child: _Pin(
                        icon: Icons.location_on,
                        color: switch (v.summary.status) {
                          VisitSyncStatus.pending => status.warning,
                          VisitSyncStatus.synced => status.success,
                          VisitSyncStatus.rejected => scheme.error,
                        },
                        label: v.summary.templateName ?? l10n.homeVisitUntitled,
                        onTap: () => _showVisit(v.summary),
                      ),
                    ),
                  for (final a in _assignments)
                    Marker(
                      key: ValueKey('map-assignment-${a.id}'),
                      point: LatLng(a.lat!, a.lon!),
                      width: AppSizes.minTouchTarget,
                      height: AppSizes.minTouchTarget,
                      child: _Pin(
                        icon: a.done ? Icons.check_circle : Icons.flag,
                        color: a.done ? status.success : scheme.primary,
                        label: a.title ?? a.templateName ?? l10n.homeVisitUntitled,
                        onTap: () => _showAssignment(a),
                      ),
                    ),
                  if (me != null)
                    Marker(
                      key: const ValueKey('map-me'),
                      point: LatLng(me.lat, me.lon),
                      width: AppSizes.minTouchTarget,
                      height: AppSizes.minTouchTarget,
                      child: Icon(Icons.my_location, color: scheme.tertiary),
                    ),
                ],
              ),
            ],
          ),
          // Sin mapa base todavía (B3): que el agente sepa por qué el fondo
          // está vacío.
          Positioned(
            left: AppSpacing.md,
            right: AppSpacing.md,
            top: AppSpacing.md,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Text(
                  points.isEmpty
                      ? l10n.mapEmpty
                      : _basemaps.isEmpty
                      ? l10n.mapNoBasemap
                      : l10n.mapBasemaps(_basemaps.map((b) => b.info.name).join(', ')),
                  key: const Key('map_hint'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.icon, required this.color, required this.label, required this.onTap});

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: InkResponse(
      onTap: onTap,
      child: Icon(icon, color: color, size: AppSizes.mapPin),
    ),
  );
}
