// Capas de referencia (Fase C): GeoJSON de la organización (predios, lotes,
// vías…) para ver sobre el mapa, como las capas de un proyecto QField.
//
// Mismo ciclo que los mapas base (`basemap_manager.dart`): la lista viene de
// `GET /v1/layers`; tras cada sincronización se bajan solas las que faltan,
// con la descarga verificable y reanudable de `core/offline`; las retiradas
// se borran; sin red no se toca nada. El índice local es un JSON pequeño.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../forms/geometry.dart';
import '../offline/verified_download.dart';

@immutable
class LayerInfo {
  const LayerInfo({
    required this.id,
    required this.name,
    required this.sha256,
    required this.size,
    required this.featureCount,
  });

  factory LayerInfo.fromJson(Map<String, dynamic> json) => LayerInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    sha256: json['sha256'] as String,
    size: json['size'] as int,
    featureCount: json['feature_count'] as int,
  );

  final String id;
  final String name;
  final String sha256;
  final int size;
  final int featureCount;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'sha256': sha256,
    'size': size,
    'feature_count': featureCount,
  };
}

@immutable
class LayerEntry {
  const LayerEntry({required this.info, this.localPath});
  final LayerInfo info;
  final String? localPath;
  bool get downloaded => localPath != null;
}

abstract class LayerTransport {
  Future<List<LayerInfo>?> list();
  Future<String?> downloadUrl(String id);
  Future<void> fetch(String url, String path, {int from = 0, void Function(int received, int total)? onProgress});
}

/// Una entidad de la capa, lista para dibujar: puntos, líneas (cada parte) o
/// polígonos (anillo exterior de cada parte; los huecos no se dibujan).
@immutable
class LayerFeature {
  const LayerFeature({
    required this.layerName,
    required this.points,
    required this.lines,
    required this.polygons,
    required this.properties,
  });

  final String layerName;
  final List<Vertex> points;
  final List<List<Vertex>> lines;
  final List<List<Vertex>> polygons;
  final Map<String, Object?> properties;

  /// Un nombre para mostrar: el primer atributo típico, o el de la capa.
  String get title {
    for (final key in const ['nombre', 'name', 'codigo', 'código', 'id']) {
      final value = properties[key];
      if (value != null && '$value'.isNotEmpty) return '$value';
    }
    return layerName;
  }
}

class LayerManager {
  LayerManager({required this.transport, required this.directory});

  final LayerTransport transport;
  final Directory directory;

  File get _index => File(p.join(directory.path, 'index.json'));

  Future<void>? _autoSync;
  final Set<String> _gaveUp = {};

  String _pathFor(LayerInfo info) => p.join(directory.path, '${checkedSha256(info.sha256)}.geojson');

  Future<List<LayerEntry>> downloaded() async => [
    for (final info in _readIndex())
      if (File(_pathFor(info)).existsSync()) LayerEntry(info: info, localPath: _pathFor(info)),
  ];

  Future<({List<LayerEntry> entries, bool online})> refresh() async {
    final local = {for (final e in await downloaded()) e.info.id: e};
    final offered = await transport.list();
    if (offered == null) return (entries: local.values.toList(), online: false);
    final ids = {for (final i in offered) i.id};
    for (final retired in local.values.where((e) => !ids.contains(e.info.id))) {
      await deleteQuietly(retired.localPath!);
    }
    final entries = [
      for (final info in offered)
        LayerEntry(
          info: info,
          localPath: local[info.id]?.info.sha256 == info.sha256 ? local[info.id]!.localPath : null,
        ),
    ];
    await _writeIndex([for (final e in entries) if (e.downloaded) e.info]);
    return (entries: entries, online: true);
  }

  Future<OfflineDownloadResult> download(LayerInfo info) async {
    final result = await downloadVerified(
      url: await transport.downloadUrl(info.id),
      target: File(_pathFor(info)),
      size: info.size,
      sha256: info.sha256,
      fetch: transport.fetch,
    );
    if (result is OfflineDownloaded) {
      await _writeIndex([for (final i in _readIndex()) if (i.id != info.id) i, info]);
    }
    return result;
  }

  /// Baja todas las capas ofrecidas que falten (tras cada sincronización).
  Future<void> syncAll() => _autoSync ??= _syncAll().whenComplete(() => _autoSync = null);

  Future<void> _syncAll() async {
    final result = await refresh();
    if (!result.online) return;
    for (final entry in result.entries) {
      if (entry.downloaded || _gaveUp.contains(entry.info.sha256)) continue;
      switch (await download(entry.info)) {
        case OfflineCorrupted() || OfflineNoSpace():
          _gaveUp.add(entry.info.sha256);
        case OfflineUnavailable():
          return;
        case OfflineDownloaded():
          break;
      }
    }
  }

  /// Entidades de una capa descargada, leídas fuera del hilo de la interfaz.
  Future<List<LayerFeature>> features(LayerEntry entry) async {
    final raw = await File(entry.localPath!).readAsString();
    return compute(_parseFeatures, (name: entry.info.name, raw: raw));
  }

  List<LayerInfo> _readIndex() {
    try {
      if (!_index.existsSync()) return const [];
      final raw = jsonDecode(_index.readAsStringSync()) as List<dynamic>;
      return [for (final item in raw) LayerInfo.fromJson(item as Map<String, dynamic>)];
    } on Object {
      return const [];
    }
  }

  Future<void> _writeIndex(List<LayerInfo> infos) async {
    await directory.create(recursive: true);
    await _index.writeAsString(jsonEncode([for (final i in infos) i.toJson()]));
  }
}

/// GeoJSON → entidades dibujables. Tolerante: una entidad que no tiene la
/// forma esperada se omite (el servidor ya validó la capa al importarla).
List<LayerFeature> _parseFeatures(({String name, String raw}) input) {
  final Object? data;
  try {
    data = jsonDecode(input.raw);
  } on FormatException {
    return const [];
  }
  if (data is! Map || data['features'] is! List) return const [];
  final features = <LayerFeature>[];
  for (final feature in data['features'] as List) {
    if (feature is! Map) continue;
    final geometry = feature['geometry'];
    if (geometry is! Map) continue;
    final points = <Vertex>[];
    final lines = <List<Vertex>>[];
    final polygons = <List<Vertex>>[];
    final coordinates = geometry['coordinates'];
    switch (geometry['type']) {
      case 'Point':
        points.addAll(_positions([coordinates]));
      case 'MultiPoint':
        points.addAll(_positions(coordinates));
      case 'LineString':
        lines.add(_positions(coordinates));
      case 'MultiLineString':
        if (coordinates is List) lines.addAll([for (final part in coordinates) _positions(part)]);
      case 'Polygon':
        if (coordinates is List && coordinates.isNotEmpty) polygons.add(_positions(coordinates.first));
      case 'MultiPolygon':
        if (coordinates is List) {
          polygons.addAll([
            for (final part in coordinates)
              if (part is List && part.isNotEmpty) _positions(part.first),
          ]);
        }
    }
    final properties = feature['properties'];
    features.add(
      LayerFeature(
        layerName: input.name,
        points: points,
        lines: lines,
        polygons: polygons,
        properties: properties is Map ? properties.cast<String, Object?>() : const {},
      ),
    );
  }
  return features;
}

List<Vertex> _positions(Object? list) => [
  if (list is List)
    for (final p in list)
      if (p is List && p.length >= 2 && p[0] is num && p[1] is num) Vertex((p[1] as num).toDouble(), (p[0] as num).toDouble()),
];
