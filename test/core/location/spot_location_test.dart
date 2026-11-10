// Lectura GPS puntual de las filas de cantidad (costos, pieza 4b): se reutiliza 30 s
// para no encender el GPS en cada fila.
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/location/location_source.dart';
import 'package:suno/core/location/spot_location.dart';

class _CountingSpot implements SpotLocation {
  _CountingSpot(this.fix);
  final LocationFix? fix;
  var reads = 0;

  @override
  Future<LocationFix?> read() async {
    reads++;
    return fix;
  }
}

void main() {
  test('reutiliza una lectura reciente y vuelve a leer al caducar', () async {
    var now = DateTime.utc(2026, 11, 9, 10);
    final source = _CountingSpot(const LocationFix(lat: 4.6, lon: -74.08, accuracyM: 7));
    final spot = CachedSpotLocation(source, clock: () => now);
    expect((await spot.read())?.accuracyM, 7);
    now = now.add(const Duration(seconds: 29));
    await spot.read();
    expect(source.reads, 1);
    now = now.add(const Duration(seconds: 2));
    await spot.read();
    expect(source.reads, 2);
  });

  test('sin lectura no guarda nada: la siguiente fila vuelve a intentar', () async {
    final source = _CountingSpot(null);
    final spot = CachedSpotLocation(source);
    expect(await spot.read(), isNull);
    expect(await spot.read(), isNull);
    expect(source.reads, 2);
  });

  test('dos filas a la vez comparten la misma lectura en curso', () async {
    final source = _CountingSpot(const LocationFix(lat: 4.6, lon: -74.08, accuracyM: 7));
    final spot = CachedSpotLocation(source);
    final results = await Future.wait([spot.read(), spot.read()]);
    expect(source.reads, 1);
    expect([for (final fix in results) fix?.accuracyM], [7, 7]);
  });

  test('una lectura simulada, no finita, fuera de rango o con precisión negativa no vale', () {
    const good = LocationFix(lat: 4.6, lon: -74.08, accuracyM: 7);
    expect(usableSpotFix(good), same(good));
    for (final bad in [
      const LocationFix(lat: 4.6, lon: -74.08, accuracyM: 7, isMocked: true),
      const LocationFix(lat: double.nan, lon: -74.08, accuracyM: 7),
      const LocationFix(lat: 4.6, lon: double.infinity, accuracyM: 7),
      const LocationFix(lat: 4.6, lon: -74.08, accuracyM: -1),
      const LocationFix(lat: 4.6, lon: -74.08, accuracyM: double.nan),
      const LocationFix(lat: 91, lon: -74.08, accuracyM: 7),
    ]) {
      expect(usableSpotFix(bad), isNull, reason: '${bad.lat} ${bad.lon} ${bad.accuracyM} ${bad.isMocked}');
    }
  });
}
