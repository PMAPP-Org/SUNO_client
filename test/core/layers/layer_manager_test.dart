// Capas de referencia (Fase C): se bajan solas y verificadas, las retiradas
// se borran, y el GeoJSON se convierte en entidades dibujables.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/layers/layer_manager.dart';

import 'fake_layer_transport.dart';

void main() {
  late Directory dir;
  late FakeLayerTransport transport;
  late LayerManager manager;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('layers-test');
    transport = FakeLayerTransport();
    manager = LayerManager(transport: transport, directory: dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('se baja sola, verificada, y se lee como entidades dibujables', () async {
    final bytes = geoJsonBytes();
    transport
      ..offered = [layerInfo('predios', bytes)]
      ..contents['predios'] = bytes;

    await manager.syncAll();
    final entry = (await manager.downloaded()).single;
    final features = await manager.features(entry);

    expect(features, hasLength(3));
    expect(features[0].polygons.single, hasLength(4), reason: 'MultiPolygon → anillo exterior de cada parte');
    expect(features[0].title, 'P-001');
    expect(features[1].lines.single, hasLength(2));
    expect(features[1].title, 'Vía principal');
    expect(features[2].points.single.lon, -74.075);
    expect(features[2].title, 'Capa predios', reason: 'sin atributos, el nombre de la capa');
  });

  test('una capa alterada no se activa ni se reintenta en bucle', () async {
    final bytes = geoJsonBytes();
    transport
      ..offered = [layerInfo('predios', bytes, sha: 'a' * 64)]
      ..contents['predios'] = bytes;
    await manager.syncAll();
    await manager.syncAll();
    expect(await manager.downloaded(), isEmpty);
    expect(transport.fetches, 1);
  });

  test('la retirada en el servidor sale del teléfono; sin red no se toca', () async {
    final bytes = geoJsonBytes();
    transport
      ..offered = [layerInfo('predios', bytes)]
      ..contents['predios'] = bytes;
    await manager.syncAll();

    transport.offered = null;
    await manager.syncAll();
    expect(await manager.downloaded(), hasLength(1), reason: 'sin red, sigue');

    transport.offered = [];
    await manager.syncAll();
    expect(await manager.downloaded(), isEmpty);
  });
}
