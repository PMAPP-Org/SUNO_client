// Implementación real de `SpotLocation` sobre `geolocator` (costos, pieza 4b). Sin test
// propio por la misma razón que `GeolocatorLocationSource`: es un envoltorio delgado de
// un plugin de plataforma; se prueba con dobles a través de quien lo usa.
import 'package:geolocator/geolocator.dart';

import '../../core/location/location_source.dart';
import '../../core/location/spot_location.dart';

class GeolocatorSpotLocation implements SpotLocation {
  const GeolocatorSpotLocation({this.timeLimit = const Duration(seconds: 8)});

  /// Cuánto se espera una posición antes de seguir sin ella.
  final Duration timeLimit;

  @override
  Future<LocationFix?> read() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      // Sin pedir permiso: si no lo dio en la captura del registro, la fila va sin GPS.
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(accuracy: LocationAccuracy.high, timeLimit: timeLimit),
      );
      // Simulada, no finita o con precisión negativa: la fila va sin GPS.
      return usableSpotFix(
        LocationFix(
          lat: position.latitude,
          lon: position.longitude,
          accuracyM: position.accuracy,
          altitudeM: position.altitude,
          isMocked: position.isMocked,
        ),
      );
    } on Exception {
      // Tiempo agotado, servicio apagado a mitad, permiso revocado: la fila va sin GPS.
      return null;
    }
  }
}
