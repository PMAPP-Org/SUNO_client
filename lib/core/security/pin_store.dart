// `PinStore` — pines TLS aprobados por el usuario (TOFU, Paso 16 tarea 3),
// uno por servidor autohospedado.
//
// **Una clave por `host:puerto`** (`visitacampo.tls_pin.v1.<host>:<port>`),
// nunca una clave fija compartida. Es la regresión directa del hallazgo
// H-10 (doc 07): QField guardaba sus cookies en una clave con un `%1` que
// nunca se interpolaba, así que cada cookie nueva pisaba la anterior. Aquí
// aprobar un segundo servidor no puede borrar el pin del primero; lo prueba
// `test/core/security/pin_store_test.dart` con tres hosts y un "reinicio".
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Un certificado aprobado para un host: la huella de la clave pública que
/// `TrustStore` exige a partir de ahora en ese `host:puerto`.
class HostPin {
  const HostPin({
    required this.host,
    required this.port,
    required this.spkiSha256,
    required this.subject,
    required this.approvedAt,
  });

  factory HostPin.fromJson(Map<String, dynamic> json) => HostPin(
    host: json['host'] as String,
    port: json['port'] as int,
    spkiSha256: json['spki_sha256'] as String,
    subject: json['subject'] as String,
    approvedAt: DateTime.parse(json['approved_at'] as String),
  );

  final String host;
  final int port;
  final String spkiSha256;

  /// Sujeto del certificado aprobado. Si se aprobó una CA privada (no el
  /// certificado del servidor), sus certificados hijos llevan este sujeto
  /// como emisor (ver `TrustStore`).
  final String subject;
  final DateTime approvedAt;

  String get hostKey => PinStore.hostKey(host, port);

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'spki_sha256': spkiSha256,
    'subject': subject,
    'approved_at': approvedAt.toUtc().toIso8601String(),
  };
}

class PinStore {
  const PinStore(this._storage);

  final FlutterSecureStorage _storage;

  static const _prefix = 'visitacampo.tls_pin.v1.';

  /// `host:puerto`, con el host en minúsculas (DNS no distingue mayúsculas).
  static String hostKey(String host, int port) => '${host.toLowerCase()}:$port';

  static String _keyFor(String host, int port) =>
      '$_prefix${hostKey(host, port)}';

  Future<void> save(HostPin pin) => _storage.write(
    key: _keyFor(pin.host, pin.port),
    value: jsonEncode(pin.toJson()),
  );

  Future<void> remove(String host, int port) =>
      _storage.delete(key: _keyFor(host, port));

  /// Todos los pines guardados, por `hostKey`. Una entrada ilegible (nunca
  /// debería haberla) se ignora: sin pin, ese host vuelve a pedir aprobación,
  /// que es el lado seguro.
  Future<Map<String, HostPin>> loadAll() async {
    final all = await _storage.readAll();
    final pins = <String, HostPin>{};
    for (final MapEntry(:key, :value) in all.entries) {
      if (!key.startsWith(_prefix)) continue;
      try {
        final pin = HostPin.fromJson(jsonDecode(value) as Map<String, dynamic>);
        pins[pin.hostKey] = pin;
      } on Object {
        continue;
      }
    }
    return pins;
  }
}
