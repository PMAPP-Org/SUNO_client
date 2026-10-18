// Trazar una línea o un polígono en el mapa (Fase C), como en QField.
//
// Dos formas de marcar vértices, combinables:
// - **tocar el mapa** donde va el vértice (sobre el mapa base offline);
// - **"Agregar mi posición"**: el vértice es la posición GPS actual, para
//   recorrer un lindero o una cerca caminando.
// Se ve en vivo cuántos vértices hay y la longitud o el área; "Deshacer"
// quita el último. Devuelve el GeoJSON (WGS84) o `null` si se cancela.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/forms/geometry.dart';
import '../../core/location/location_source.dart';
import '../../core/providers.dart';
import '../../data/map/mbtiles_tile_provider.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_tokens.dart';

const _fallbackCenter = LatLng(4.6097, -74.0817);

class GeometryCaptureScreen extends ConsumerStatefulWidget {
  const GeometryCaptureScreen({super.key, required this.kind, required this.title, this.initial = const []});

  final GeometryKind kind;
  final String title;
  final List<Vertex> initial;

  @override
  ConsumerState<GeometryCaptureScreen> createState() => _GeometryCaptureScreenState();
}

class _GeometryCaptureScreenState extends ConsumerState<GeometryCaptureScreen> {
  late final List<Vertex> _vertices = [...widget.initial];
  final _controller = MapController();
  LocationFix? _me;
  StreamSubscription<LocationFix>? _position;
  List<MbtilesTileProvider> _basemaps = const [];
  ({int minZoom, int maxZoom})? _basemapZooms;

  @override
  void initState() {
    super.initState();
    unawaited(_follow());
    unawaited(_loadBasemaps());
  }

  @override
  void dispose() {
    unawaited(_position?.cancel());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _follow() async {
    final source = ref.read(appDependenciesProvider).locationSource;
    if (await source.ensureReady() != LocationStatus.ready || !mounted) return;
    _position = source.watch().listen((fix) {
      if (mounted) setState(() => _me = fix);
    });
  }

  Future<void> _loadBasemaps() async {
    final downloaded = await ref.read(appDependenciesProvider).basemaps.downloaded();
    final opened = <MbtilesTileProvider>[];
    var minZoom = 24;
    var maxZoom = 0;
    for (final entry in downloaded) {
      try {
        opened.add(MbtilesTileProvider(entry.localPath!));
        minZoom = entry.info.minZoom < minZoom ? entry.info.minZoom : minZoom;
        maxZoom = entry.info.maxZoom > maxZoom ? entry.info.maxZoom : maxZoom;
      } on Object {
        // Un paquete que no abre no impide trazar.
      }
    }
    if (!mounted) {
      for (final p in opened) {
        unawaited(p.dispose());
      }
      return;
    }
    setState(() {
      _basemaps = opened;
      _basemapZooms = opened.isEmpty ? null : (minZoom: minZoom, maxZoom: maxZoom);
    });
  }

  void _add(Vertex vertex) => setState(() => _vertices.add(vertex));

  void _addMyPosition() {
    final me = _me;
    if (me != null) _add(Vertex(me.lat, me.lon));
  }

  bool get _canSave => _vertices.toSet().length >= widget.kind.minVertices;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final points = [for (final v in _vertices) LatLng(v.lat, v.lon)];
    final me = _me;
    final zooms = _basemapZooms;
    final value = formatMeasure(widget.kind, measure(widget.kind, _vertices));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          TextButton(
            key: const Key('geometry_save'),
            onPressed: _canSave ? () => Navigator.of(context).pop(toGeoJson(widget.kind, _vertices)) : null,
            child: Text(l10n.geometrySave),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _controller,
              options: MapOptions(
                backgroundColor: scheme.surfaceContainerHighest,
                initialCenter: points.isNotEmpty
                    ? points.last
                    : me != null
                    ? LatLng(me.lat, me.lon)
                    : _fallbackCenter,
                initialZoom: points.isNotEmpty ? 17 : 6,
                // Sin zoom por doble toque: al marcar vértices seguidos, dos
                // toques rápidos se tomaban como zoom y no como dos vértices.
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.doubleTapZoom,
                ),
                onTap: (_, point) => _add(Vertex(point.latitude, point.longitude)),
              ),
              children: [
                for (final tiles in _basemaps)
                  TileLayer(tileProvider: tiles, minNativeZoom: zooms!.minZoom, maxNativeZoom: zooms.maxZoom),
                if (widget.kind == GeometryKind.polygon && points.length >= 3)
                  PolygonLayer(
                    polygons: [
                      Polygon(
                        points: points,
                        color: scheme.primary.withValues(alpha: 0.25),
                        borderColor: scheme.primary,
                        borderStrokeWidth: AppSizes.signatureStroke,
                      ),
                    ],
                  )
                else if (points.length >= 2)
                  PolylineLayer(
                    polylines: [Polyline(points: points, color: scheme.primary, strokeWidth: AppSizes.signatureStroke)],
                  ),
                MarkerLayer(
                  markers: [
                    for (final (i, p) in points.indexed)
                      Marker(
                        key: ValueKey('geometry-vertex-$i'),
                        point: p,
                        width: AppSizes.mapPin / 2,
                        height: AppSizes.mapPin / 2,
                        child: Icon(Icons.circle, color: scheme.primary, size: AppSizes.mapPin / 2),
                      ),
                    if (me != null)
                      Marker(
                        point: LatLng(me.lat, me.lon),
                        width: AppSizes.minTouchTarget,
                        height: AppSizes.minTouchTarget,
                        child: Icon(Icons.my_location, color: scheme.tertiary),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.kind == GeometryKind.line
                        ? l10n.geometryLineSummary(_vertices.length, value)
                        : l10n.geometryPolygonSummary(_vertices.length, value),
                    key: const Key('geometry_summary'),
                    textAlign: TextAlign.center,
                  ),
                  Text(l10n.geometryHint, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          key: const Key('geometry_add_position'),
                          icon: const Icon(Icons.my_location),
                          label: Text(
                            me == null ? l10n.geometryWaitingGps : l10n.geometryAddPosition(me.accuracyM.round()),
                          ),
                          onPressed: me == null ? null : _addMyPosition,
                        ),
                      ),
                      IconButton(
                        key: const Key('geometry_undo'),
                        tooltip: l10n.geometryUndo,
                        icon: const Icon(Icons.undo),
                        onPressed: _vertices.isEmpty ? null : () => setState(_vertices.removeLast),
                      ),
                      IconButton(
                        key: const Key('geometry_clear'),
                        tooltip: l10n.geometryClear,
                        icon: const Icon(Icons.delete_sweep_outlined),
                        onPressed: _vertices.isEmpty ? null : () => setState(_vertices.clear),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
