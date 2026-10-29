// `LocationSource` — la mitad de GPS que `CaptureScreen` necesita (Tarea 6
// del plan de despliegue del demo). Interfaz + implementación real
// separadas, mismo patrón que `AuthTransport`/`SyncTransport`: los tests de
// `CaptureScreen` usan un fake, sin permisos de plataforma reales.
//
// Fase A (GPS fiable): ya no es una lectura única. La fuente entrega un flujo
// de lecturas y `GpsSampler` (`gps_sampler.dart`) decide cuándo hay una
// posición buena: precisión objetivo, promedio de varias lecturas y un tiempo
// máximo, como el "promediado de posición" de QField.
class LocationFix {
  const LocationFix({
    required this.lat,
    required this.lon,
    required this.accuracyM,
    this.altitudeM,
    this.isMocked = false,
  });

  final double lat;
  final double lon;
  final double accuracyM;
  final double? altitudeM;

  /// Posición simulada (Android: "ubicación de prueba" activada). Se avisa
  /// al agente: una visita con ubicación falsa no es evidencia.
  final bool isMocked;
}

/// Por qué no hay lecturas, para decirle al agente qué hacer.
enum LocationStatus {
  ready,

  /// El GPS del sistema está apagado.
  serviceDisabled,

  /// El agente negó el permiso; se puede volver a pedir.
  permissionDenied,

  /// Negado para siempre: solo se cambia en los ajustes del sistema.
  permissionDeniedForever,
}

/// El servicio de ubicación se apagó con una suscripción de [LocationSource.watch]
/// abierta. Se distingue de una pérdida de señal: esperar no lo arregla.
class LocationServiceDisabledError implements Exception {
  const LocationServiceDisabledError();
}

abstract class LocationSource {
  /// Comprueba el servicio y pide el permiso si hace falta.
  ///
  /// Sin permiso o con el servicio apagado, `CaptureScreen` debe seguir
  /// permitiendo guardar la visita sin ubicación (`Visit.lat`/`lon` son
  /// opcionales en el contrato, `core/models/visit.py`).
  Future<LocationStatus> ensureReady();

  /// Lecturas de alta precisión mientras haya suscriptor. Cancelar la
  /// suscripción apaga el GPS.
  Stream<LocationFix> watch();

  /// Abre los ajustes del sistema que corresponden a [status] (ubicación o
  /// permisos de la app).
  Future<void> openSettings(LocationStatus status);
}
