// Teselas de un MBTiles en el teléfono, para `flutter_map` (Fase B).
//
// Un MBTiles es una base SQLite; se abre **solo lectura** con el mismo
// `sqlite3` de la app (no `flutter_map_mbtiles`, que exige una versión de
// `sqlite3` incompatible con la de SQLCipher). MBTiles numera las filas en
// esquema TMS (la 0 es la del sur) y los mapas web en XYZ (la 0 es la del
// norte): `fila_tms = 2^z - 1 - y`.
//
// Una tesela que el paquete no tiene se dibuja transparente: fuera de su zona
// o de sus niveles de zoom se ve el fondo (u otro paquete debajo).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:sqlite3/sqlite3.dart';

/// PNG transparente de 1×1.
final _empty = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=',
);

class MbtilesTileProvider extends TileProvider {
  MbtilesTileProvider(String path) : _db = sqlite3.open(path, mode: OpenMode.readOnly) {
    _query = _db.prepare('SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?');
  }

  final Database _db;
  late final PreparedStatement _query;

  /// Los bytes de la tesela XYZ, o `null` si el paquete no la tiene.
  Uint8List? tile(int z, int x, int y) {
    final tmsRow = (1 << z) - 1 - y;
    final rows = _query.select([z, x, tmsRow]);
    if (rows.isEmpty) return null;
    final data = rows.first.columnAt(0);
    return data is Uint8List ? data : null;
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(tile(coordinates.z, coordinates.x, coordinates.y) ?? _empty);

  @override
  Future<void> dispose() async {
    _query.close();
    _db.close();
    super.dispose();
  }
}
