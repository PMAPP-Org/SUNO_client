// Lectura GPS puntual (costos, pieza 4b): cada fila de cantidad guarda dónde estaba el
// agente al digitarla, si hay permiso y señal. A diferencia de `LocationSource`, no pide
// permiso ni mantiene el GPS encendido: es un dato de contexto para la revisión, no la
// ubicación del registro.
import 'location_source.dart';

abstract class SpotLocation {
  /// Una lectura, o `null` sin permiso, con el GPS apagado o sin señal a tiempo.
  Future<LocationFix?> read();
}

/// Reutiliza una lectura de hace menos de [maxAge]: varias filas digitadas seguidas no
/// encienden el GPS cada vez.
class CachedSpotLocation implements SpotLocation {
  CachedSpotLocation(this._source, {this.maxAge = const Duration(seconds: 30), DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final SpotLocation _source;
  final Duration maxAge;
  final DateTime Function() _now;
  LocationFix? _last;
  DateTime? _at;

  @override
  Future<LocationFix?> read() async {
    final at = _at;
    if (_last != null && at != null && _now().difference(at) < maxAge) return _last;
    final fix = await _source.read();
    if (fix != null) {
      _last = fix;
      _at = _now();
    }
    return fix;
  }
}
