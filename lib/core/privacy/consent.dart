// Autorización del titular para el tratamiento de sus datos (Ley 1581 de
// 2012, art. 9: previa, expresa e informada, y con prueba).
//
// - **Previa**: el aviso de privacidad se muestra al primer arranque, antes del
//   login, y por tanto antes de capturar ubicación o fotos (`main.dart`).
// - **Expresa**: cada finalidad se acepta con su propia casilla; sin las tres no
//   se puede usar la app, porque las tres son el servicio (una visita de campo
//   es ubicación + fotos + la cuenta de quien la hace).
// - **Informada**: el texto del aviso (`lib/l10n/app_es.arb`, `privacy*`),
//   identificado por [kPrivacyNoticeVersion]. Cambiar el texto obliga a subir la
//   versión, y la app vuelve a pedir la autorización.
// - **Prueba**: tras el login se envía al servidor (`POST /v1/consents`), que la
//   guarda con usuario, dispositivo y fecha. Si no hay red, queda pendiente aquí
//   y se reintenta en la siguiente ocasión; aceptar nunca depende de la red.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Versión del aviso que muestra esta build. **Subirla cuando cambie el texto.**
const String kPrivacyNoticeVersion = '2026-10-18';

/// Finalidades del aviso. El nombre es el valor del contrato
/// (`components.schemas.PrivacyPurpose`).
enum PrivacyPurpose { account, location, photos }

class StoredConsent {
  const StoredConsent({
    required this.noticeVersion,
    required this.purposes,
    required this.acceptedAt,
    required this.sent,
  });

  factory StoredConsent.fromJson(Map<String, dynamic> json) => StoredConsent(
    noticeVersion: json['notice_version'] as String,
    purposes: {
      for (final name in json['purposes'] as List<dynamic>)
        PrivacyPurpose.values.byName(name as String),
    },
    acceptedAt: DateTime.parse(json['accepted_at'] as String),
    sent: json['sent'] as bool,
  );

  final String noticeVersion;
  final Set<PrivacyPurpose> purposes;
  final DateTime acceptedAt;

  /// Si el servidor ya tiene la prueba.
  final bool sent;

  StoredConsent markSent() => StoredConsent(
    noticeVersion: noticeVersion,
    purposes: purposes,
    acceptedAt: acceptedAt,
    sent: true,
  );

  Map<String, dynamic> toJson() => {
    'notice_version': noticeVersion,
    'purposes': [
      for (final p in PrivacyPurpose.values)
        if (purposes.contains(p)) p.name,
    ],
    'accepted_at': acceptedAt.toUtc().toIso8601String(),
    'sent': sent,
  };
}

/// Dónde vive la autorización en el teléfono. No es un secreto, pero va en el
/// mismo almacenamiento endurecido que el resto del estado de la cuenta.
class ConsentStore {
  const ConsentStore(this._storage);

  final FlutterSecureStorage _storage;

  static const _entry = 'visitacampo.privacy_consent.v1';

  Future<StoredConsent?> read() async {
    final raw = await _storage.read(key: _entry);
    if (raw == null) return null;
    try {
      return StoredConsent.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      // Ilegible: se trata como "no aceptado" y se vuelve a mostrar el aviso,
      // que es el lado seguro.
      return null;
    }
  }

  Future<void> write(StoredConsent consent) =>
      _storage.write(key: _entry, value: jsonEncode(consent.toJson()));
}

/// Envío de la prueba al servidor. `true` solo si el servidor la guardó.
abstract class ConsentTransport {
  Future<bool> record({
    required String accessToken,
    required String deviceId,
    required String noticeVersion,
    required Set<PrivacyPurpose> purposes,
    required DateTime acceptedAt,
  });
}

class ConsentService {
  ConsentService({
    required this._store,
    required this._transport,
    required String Function() accessTokenProvider,
    required this.deviceId,
    DateTime Function()? clock,
  }) : _accessToken = accessTokenProvider,
       _now = clock ?? DateTime.now;

  final ConsentStore _store;
  final ConsentTransport _transport;
  final String Function() _accessToken;
  final String deviceId;
  final DateTime Function() _now;

  /// Si el titular aceptó **este** aviso, con todas sus finalidades.
  Future<bool> isAcceptedForCurrentVersion() async {
    final stored = await _store.read();
    return stored != null &&
        stored.noticeVersion == kPrivacyNoticeVersion &&
        stored.purposes.containsAll(PrivacyPurpose.values);
  }

  /// El titular aceptó en el aviso. Exige todas las finalidades.
  Future<void> accept(Set<PrivacyPurpose> purposes) async {
    if (!purposes.containsAll(PrivacyPurpose.values)) {
      throw ArgumentError(
        'La app necesita las tres finalidades para funcionar.',
      );
    }
    await _store.write(
      StoredConsent(
        noticeVersion: kPrivacyNoticeVersion,
        purposes: purposes,
        acceptedAt: _now().toUtc(),
        sent: false,
      ),
    );
  }

  /// Envía la prueba si está pendiente y hay sesión. Nunca lanza: si falla, se
  /// reintenta la próxima vez (tras el login o al abrir la pantalla de inicio).
  Future<bool> syncPending() async {
    try {
      final stored = await _store.read();
      if (stored == null || stored.sent) return stored?.sent ?? false;
      final token = _accessToken();
      if (token.isEmpty) return false;
      final ok = await _transport.record(
        accessToken: token,
        deviceId: deviceId,
        noticeVersion: stored.noticeVersion,
        purposes: stored.purposes,
        acceptedAt: stored.acceptedAt,
      );
      if (ok) await _store.write(stored.markSent());
      return ok;
    } on Object {
      return false;
    }
  }
}
