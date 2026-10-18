// Teselas de un MBTiles (Fase B): la fila TMS se convierte a XYZ, y una
// tesela que el paquete no tiene es `null` (se dibuja transparente).
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:visitacampo/data/map/mbtiles_tile_provider.dart';

void main() {
  late Directory dir;
  late String path;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mbtiles-test');
    path = '${dir.path}/mapa.mbtiles';
    final db = sqlite3.open(path)
      ..execute('CREATE TABLE metadata (name TEXT, value TEXT)')
      ..execute('CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)');
    // z=2, x=1, y XYZ=0 (fila norte) ⇒ fila TMS = 2^2 - 1 - 0 = 3.
    db.execute('INSERT INTO tiles VALUES (2, 1, 3, ?)', [
      Uint8List.fromList([1, 2, 3]),
    ]);
    db.close();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('lee la tesela XYZ convirtiendo la fila TMS', () async {
    final provider = MbtilesTileProvider(path);
    addTearDown(provider.dispose);
    expect(provider.tile(2, 1, 0), [1, 2, 3]);
    expect(provider.tile(2, 1, 3), isNull, reason: 'esa es la fila sur, que no está');
    expect(provider.tile(5, 0, 0), isNull);
  });

  test('se abre solo lectura: no puede modificar el paquete', () async {
    final provider = MbtilesTileProvider(path);
    addTearDown(provider.dispose);
    final readOnly = sqlite3.open(path, mode: OpenMode.readOnly);
    addTearDown(readOnly.close);
    expect(() => readOnly.execute('DELETE FROM tiles'), throwsA(isA<SqliteException>()));
  });
}
