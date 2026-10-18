// En qué sistema ve el agente las coordenadas (Fase C). Se guarda en el
// almacenamiento seguro, como los ajustes del GPS; un código guardado que no
// está entre los ofrecidos vuelve a WGS84.
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'coordinate_system.dart';

class CoordinateSettings {
  CoordinateSettings(this._storage);

  final FlutterSecureStorage _storage;

  static const _entry = 'visitacampo.coordinate_system.v1';

  /// El sistema elegido; las pantallas se redibujan al cambiarlo.
  final ValueNotifier<CoordinateSystem> current = ValueNotifier(CoordinateSystem.wgs84);

  Future<void> load() async {
    try {
      final code = await _storage.read(key: _entry);
      current.value = (code == null ? null : CoordinateSystem.byCode(code)) ?? CoordinateSystem.wgs84;
    } on Object {
      current.value = CoordinateSystem.wgs84;
    }
  }

  Future<void> update(CoordinateSystem crs) async {
    current.value = crs;
    await _storage.write(key: _entry, value: crs.code);
  }
}
