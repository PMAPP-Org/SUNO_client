// Lectura GPS puntual (costos, pieza 4b): cada fila de cantidad guarda dónde estaba el
// agente al digitarla, si hay permiso y señal. A diferencia de `LocationSource`, no pide
// permiso ni mantiene el GPS encendido: es un dato de contexto para la revisión, no la
// ubicación del registro.
import 'location_source.dart';

abstract class SpotLocation {
  /// Una lectura, o `null` sin permiso, con el GPS apagado o sin señal a tiempo.
  Future<LocationFix?> read();
}

/// [fix] si sirve como dato de una fila (`QuantityGps` del contrato): coordenadas
/// finitas y en rango, precisión finita y no negativa, y no simulada (una ubicación de
/// prueba no es evidencia). Si no, `null`: la fila va sin GPS.
LocationFix? usableSpotFix(LocationFix fix) {
  final ok =
      !fix.isMocked &&
      fix.lat.isFinite &&
      fix.lon.isFinite &&
      fix.accuracyM.isFinite &&
      fix.lat.abs() <= 90 &&
      fix.lon.abs() <= 180 &&
      fix.accuracyM >= 0;
  return ok ? fix : null;
}

/// Reutiliza una lectura de hace menos de [maxAge]: varias filas digitadas seguidas no
/// encienden el GPS cada vez. Dos filas que piden a la vez comparten la lectura en curso.
class CachedSpotLocation implements SpotLocation {
  CachedSpotLocation(this._source, {this.maxAge = const Duration(seconds: 30), DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final SpotLocation _source;
  final Duration maxAge;
  final DateTime Function() _now;
  LocationFix? _last;
  DateTime? _at;
  Future<LocationFix?>? _pending;

  @override
  Future<LocationFix?> read() {
    final at = _at;
    if (_last != null && at != null && _now().difference(at) < maxAge) return Future.value(_last);
    return _pending ??= _readSource().whenComplete(() => _pending = null);
  }

  Future<LocationFix?> _readSource() async {
    final fix = await _source.read();
    if (fix != null) {
      _last = fix;
      _at = _now();
    }
    return fix;
  }
}
