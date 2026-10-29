// Implementación real de `LocationSource` sobre el paquete `geolocator`.
// Sin test unitario propio (envoltorio delgado de un plugin de plataforma,
// no probable con `flutter test` sin un dispositivo/emulador real) — mismo
// criterio que `SecureTokenStore` (`core/auth/token_store.dart`), que
// tampoco tiene test propio y se prueba a través de un fake en el dominio
// que sí lo consume (aquí, `CaptureScreen` y `GpsSampler`).
import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../../core/location/location_source.dart';

class GeolocatorLocationSource implements LocationSource {
  const GeolocatorLocationSource();

  @override
  Future<LocationStatus> ensureReady() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationStatus.serviceDisabled;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return switch (permission) {
      LocationPermission.denied => LocationStatus.permissionDenied,
      LocationPermission.deniedForever => LocationStatus.permissionDeniedForever,
      _ => LocationStatus.ready,
    };
  }

  @override
  Stream<LocationFix> watch() =>
      Geolocator.getPositionStream(
            // Precisión máxima y sin filtro de distancia: para promediar hacen falta
            // todas las lecturas, también las del agente quieto en el punto.
            locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
          )
          .map(
            (position) => LocationFix(
              lat: position.latitude,
              lon: position.longitude,
              accuracyM: position.accuracy,
              altitudeM: position.altitude,
              isMocked: position.isMocked,
            ),
          )
          // El dominio no conoce las excepciones del plugin.
          .transform(
            StreamTransformer<LocationFix, LocationFix>.fromHandlers(
              handleError: (error, stack, sink) => sink.addError(
                error is LocationServiceDisabledException ? const LocationServiceDisabledError() : error,
                stack,
              ),
            ),
          );

  @override
  Future<void> openSettings(LocationStatus status) async {
    if (status == LocationStatus.serviceDisabled) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
  }
}
