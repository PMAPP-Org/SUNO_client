// `TrustStore` — módulo auditado de confianza TLS (Paso 16, ADR-009, RD-01).
//
// **Único lugar del cliente donde se decide sobre certificados.** El lint
// `tool/lint_no_tls_bypass.sh` falla si los hooks de aceptación de
// certificados aparecen en cualquier otro archivo. Cualquier cambio aquí
// exige la misma revisión que este paso (cierra el hallazgo CRITICAL H-01:
// QField aceptaba certificados inválidos sin preguntar).
//
// Cómo decide, por conexión y **antes de enviar un solo byte** de la
// petición (la verificación va en el `connectionFactory` de `HttpClient`, no
// en `validateCertificate` de dio, que comprueba tras enviar el cuerpo: con
// un pin incorrecto, la contraseña del login ya habría salido):
//
// 1. Solo HTTPS. `http://` se rechaza siempre (`CleartextRefused`).
// 2. Siempre conexión directa: sin proxy, porque el túnel de un proxy
//    saltaría esta verificación.
// 3. Certificado que **no** valida contra las CA del sistema:
//    - servidor oficial (con pines SPKI): rechazado, nunca TOFU;
//    - host con pin aprobado por el usuario: aceptado solo si la clave
//      pública coincide con la aprobada; si no, `CertificateChanged`;
//    - host sin pin: rechazado con `UntrustedCertificate`, que lleva el
//      certificado para que la UI muestre el diálogo de confianza (TOFU).
// 4. Certificado que **sí** valida contra las CA:
//    - servidor oficial con pines vigentes: la clave del servidor tiene que
//      ser uno de los dos pines (actual y siguiente); si no, `PinMismatch`.
//      Con los pines caducados, se acepta con la validación de CA estándar
//      (fail-open de ADR-009: un pin vencido no puede dejar la app inservible);
//    - host con pin aprobado: la clave tiene que ser la aprobada, aunque el
//      nuevo certificado sea de una CA pública: un cambio de certificado se
//      bloquea hasta que el usuario lo vuelva a aprobar.
//
// Lo que se fija es la huella SHA-256 de la clave pública (SPKI), ver
// `certificate_info.dart`. Si el usuario aprueba una CA privada (el
// certificado que falla la validación es la raíz, no el del servidor), el
// pin es esa CA: sus certificados hijos pasan mientras la cadena llegue a
// ella, y el emisor de cada uno tiene que ser el sujeto aprobado.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'certificate_info.dart';
import 'pin_store.dart';

/// Pines SPKI del servidor oficial (tarea 2): el actual y el siguiente, con
/// una fecha a partir de la cual dejan de exigirse.
class SpkiPinPolicy {
  SpkiPinPolicy({
    required String host,
    required Set<String> pins,
    required this.expiresAt,
  }) : host = host.toLowerCase(),
       pins = Set.unmodifiable(pins) {
    if (pins.length < 2) {
      throw ArgumentError(
        'Pinning SPKI exige al menos dos pines (actual y siguiente).',
      );
    }
  }

  /// Lee la política del build: `--dart-define=VISITACAMPO_SPKI_PINS=pin1,pin2`
  /// y `--dart-define=VISITACAMPO_SPKI_PINS_EXPIRE=2027-06-30`. Sin pines, el
  /// servidor no es "oficial" y se trata como autohospedado (TOFU). Con pines
  /// pero mal configurados, la app no arranca: un build de producción sin
  /// pinning no puede pasar desapercibido.
  static SpkiPinPolicy? fromEnvironment(String apiBaseUrl) {
    const rawPins = String.fromEnvironment('VISITACAMPO_SPKI_PINS');
    const rawExpiry = String.fromEnvironment('VISITACAMPO_SPKI_PINS_EXPIRE');
    return parse(
      apiBaseUrl: apiBaseUrl,
      rawPins: rawPins,
      rawExpiry: rawExpiry,
    );
  }

  static SpkiPinPolicy? parse({
    required String apiBaseUrl,
    required String rawPins,
    required String rawExpiry,
  }) {
    final pins = rawPins
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toSet();
    if (pins.isEmpty) return null;
    final expiresAt = DateTime.tryParse(rawExpiry);
    if (expiresAt == null) {
      throw ArgumentError(
        'VISITACAMPO_SPKI_PINS_EXPIRE falta o no es una fecha ISO-8601.',
      );
    }
    return SpkiPinPolicy(
      host: Uri.parse(apiBaseUrl).host,
      pins: pins,
      expiresAt: expiresAt.toUtc(),
    );
  }

  final String host;
  final Set<String> pins;
  final DateTime expiresAt;

  bool appliesTo(String host) => host.toLowerCase() == this.host;

  bool isActiveAt(DateTime now) => now.isBefore(expiresAt);
}

/// Por qué se cortó una conexión. Viaja como `DioException.error`.
sealed class CertificateRejection implements Exception {
  const CertificateRejection(this.host, this.port, this.certificate);

  final String host;
  final int port;

  /// `null` si el certificado no se pudo leer.
  final CertificateInfo? certificate;

  /// Si el usuario puede aprobar este certificado (diálogo TOFU).
  bool get approvable;

  @override
  String toString() => '$runtimeType($host:$port)';
}

/// Certificado no confiable y sin pin: candidato a TOFU.
final class UntrustedCertificate extends CertificateRejection {
  const UntrustedCertificate(super.host, super.port, super.certificate);

  @override
  bool get approvable => certificate != null;
}

/// El host tenía un certificado aprobado y ahora presenta otro.
final class CertificateChanged extends CertificateRejection {
  const CertificateChanged(
    super.host,
    super.port,
    super.certificate, {
    required this.previous,
  });

  final HostPin previous;

  @override
  bool get approvable => certificate != null;
}

/// Servidor oficial: certificado no confiable o clave fuera de los pines.
/// Nunca se puede aprobar desde la app.
final class PinMismatch extends CertificateRejection {
  const PinMismatch(super.host, super.port, super.certificate);

  @override
  bool get approvable => false;
}

/// Petición `http://`: el cliente solo habla TLS.
final class CleartextRefused implements Exception {
  const CleartextRefused(this.uri);

  final Uri uri;

  @override
  String toString() => 'CleartextRefused($uri)';
}

class TrustStore {
  TrustStore({
    required this._pinStore,
    SpkiPinPolicy? officialPins,
    this._context,
    DateTime Function()? now,
  }) : _official = officialPins,
       _now = now ?? DateTime.now;

  final PinStore _pinStore;
  final SpkiPinPolicy? _official;

  /// CA de confianza. `null`: las del sistema. Los tests pasan una CA propia.
  final SecurityContext? _context;
  final DateTime Function() _now;

  /// Pines en memoria: las decisiones de TLS son síncronas y no pueden
  /// esperar al almacenamiento seguro. `load()` los trae al arrancar.
  Map<String, HostPin> _pins = const {};

  Map<String, HostPin> get approvedPins => Map.unmodifiable(_pins);

  Future<void> load() async {
    _pins = await _pinStore.loadAll();
  }

  /// El usuario aprobó [certificate] para `host:port` (diálogo TOFU). Sustituye
  /// cualquier aprobación anterior de ese host, y solo de ese host.
  Future<HostPin> approve(
    String host,
    int port,
    CertificateInfo certificate,
  ) async {
    if (_official != null && _official.appliesTo(host)) {
      throw StateError(
        'El servidor oficial usa pinning: sus certificados no se aprueban a mano.',
      );
    }
    final pin = HostPin(
      host: host.toLowerCase(),
      port: port,
      spkiSha256: certificate.spkiSha256,
      subject: certificate.subject,
      approvedAt: _now().toUtc(),
    );
    await _pinStore.save(pin);
    _pins = {..._pins, pin.hostKey: pin};
    return pin;
  }

  Future<void> forget(String host, int port) async {
    await _pinStore.remove(host, port);
    _pins = Map.of(_pins)..remove(PinStore.hostKey(host, port));
  }

  /// Adaptador de dio con esta política. Uno por `Dio`.
  HttpClientAdapter adapter() =>
      IOHttpClientAdapter(createHttpClient: createHttpClient);

  HttpClient createHttpClient() {
    final client = HttpClient(context: _context)..connectionFactory = _connect;
    client.findProxy = (_) => 'DIRECT';
    return client;
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort,
  ) async {
    if (uri.scheme != 'https') throw CleartextRefused(uri);
    final host = uri.host;
    final port = uri.port;

    CertificateRejection? rejection;
    var acceptedByPin = false;
    final task = await SecureSocket.startConnect(
      host,
      port,
      context: _context,
      onBadCertificate: (certificate) {
        // Puede llamarse más de una vez en un handshake (un error por nivel
        // de la cadena): un rechazo no lo deshace una llamada posterior.
        if (rejection != null) return false;
        final decision = _decideUntrusted(certificate, host, port);
        rejection = decision.rejection;
        acceptedByPin = decision.rejection == null;
        return acceptedByPin;
      },
    );

    final checked = task.socket.then<Socket>(
      (socket) {
        final problem = _checkPeer(
          socket.peerCertificate,
          host,
          port,
          acceptedByPin: acceptedByPin,
        );
        if (problem != null) {
          socket.destroy();
          throw problem;
        }
        return socket;
      },
      onError: (Object error, StackTrace stack) {
        // El handshake falló porque aquí se rechazó el certificado: se
        // propaga el motivo (con el certificado) en vez del error genérico.
        final reason = rejection;
        if (reason != null) throw reason;
        Error.throwWithStackTrace(error, stack);
      },
    );
    return ConnectionTask.fromSocket(checked, task.cancel);
  }

  /// El certificado no valida contra las CA de confianza.
  ({CertificateRejection? rejection}) _decideUntrusted(
    X509Certificate certificate,
    String host,
    int port,
  ) {
    final info = _info(certificate);
    final official = _official;
    if (official != null && official.appliesTo(host)) {
      return (rejection: PinMismatch(host, port, info));
    }
    final pin = _pins[PinStore.hostKey(host, port)];
    if (pin == null) return (rejection: UntrustedCertificate(host, port, info));
    if (info != null && info.spkiSha256 == pin.spkiSha256) {
      return (rejection: null);
    }
    return (rejection: CertificateChanged(host, port, info, previous: pin));
  }

  /// Certificado del servidor, ya con el handshake hecho y antes de enviar.
  CertificateRejection? _checkPeer(
    X509Certificate? peer,
    String host,
    int port, {
    required bool acceptedByPin,
  }) {
    final info = peer == null ? null : _info(peer);
    final official = _official;
    if (official != null && official.appliesTo(host)) {
      if (!official.isActiveAt(_now())) return null; // fail-open a la CA
      if (info != null && official.pins.contains(info.spkiSha256)) return null;
      return PinMismatch(host, port, info);
    }

    final pin = _pins[PinStore.hostKey(host, port)];
    if (pin == null) return null; // CA del sistema, sin pin propio
    if (info == null) {
      return CertificateChanged(host, port, info, previous: pin);
    }
    if (info.spkiSha256 == pin.spkiSha256) return null;
    // Aprobada una CA privada: el servidor presenta un hijo suyo, y la
    // cadena ya se aceptó contra el pin en `_decideUntrusted`.
    if (acceptedByPin && info.issuer == pin.subject) return null;
    return CertificateChanged(host, port, info, previous: pin);
  }

  static CertificateInfo? _info(X509Certificate certificate) {
    try {
      return CertificateInfo.fromDer(
        certificate.der,
        subject: certificate.subject,
        issuer: certificate.issuer,
        notBefore: certificate.startValidity,
        notAfter: certificate.endValidity,
      );
    } on FormatException {
      return null;
    }
  }
}
