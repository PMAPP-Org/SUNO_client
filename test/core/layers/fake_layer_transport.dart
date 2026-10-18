// Dobles para los tests de capas de referencia (Fase C).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:visitacampo/core/layers/layer_manager.dart';

class FakeLayerTransport implements LayerTransport {
  List<LayerInfo>? offered = [];
  final Map<String, List<int>> contents = {};
  int fetches = 0;

  @override
  Future<List<LayerInfo>?> list() async => offered;

  @override
  Future<String?> downloadUrl(String id) async => contents.containsKey(id) ? 'https://store.example/$id' : null;

  @override
  Future<void> fetch(
    String url,
    String path, {
    int from = 0,
    void Function(int received, int total)? onProgress,
  }) async {
    fetches++;
    final bytes = contents[url.split('/').last]!;
    await File(path).writeAsBytes(bytes.sublist(from), mode: from > 0 ? FileMode.append : FileMode.write);
  }
}

LayerInfo layerInfo(String id, List<int> bytes, {String? sha, int features = 2}) => LayerInfo(
  id: id,
  name: 'Capa $id',
  sha256: sha ?? sha256.convert(bytes).toString(),
  size: bytes.length,
  featureCount: features,
);

List<int> geoJsonBytes() => utf8.encode(
  jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'properties': {'codigo': 'P-001', 'area_ha': 1.2},
        'geometry': {
          'type': 'MultiPolygon',
          'coordinates': [
            [
              [
                [-74.08, 4.6],
                [-74.07, 4.6],
                [-74.07, 4.61],
                [-74.08, 4.6],
              ],
            ],
          ],
        },
      },
      {
        'type': 'Feature',
        'properties': {'nombre': 'Vía principal'},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            [-74.08, 4.6],
            [-74.07, 4.61],
          ],
        },
      },
      {
        'type': 'Feature',
        'properties': null,
        'geometry': {
          'type': 'Point',
          'coordinates': [-74.075, 4.605],
        },
      },
    ],
  }),
);
