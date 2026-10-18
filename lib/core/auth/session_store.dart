// `SessionStore` — lo que hace falta para **volver a entrar sin red** (Fase A,
// trabajo offline): el perfil del usuario y hasta cuándo vale su refresh token.
//
// En campo, el teléfono mata la app o el agente la cierra sin cobertura. Sin
// esto, al abrirla de nuevo solo quedaba el login, que necesita red: el agente
// no podía seguir capturando. Con esto, si hay un refresh token **vigente**, la
// app entra directamente; el access token (en memoria, 15 min) se pide cuando
// vuelve la red, y si el servidor dice que la sesión ya no vale (`401`), la app
// vuelve al login sin tocar la outbox (`AuthController._doRefresh`).
//
// No es una forma de saltarse la autenticación: la credencial es el mismo
// refresh token que ya vivía en el almacenamiento seguro, con su caducidad
// (`refresh_expires_in` del contrato). Caducada, hay que entrar con contraseña.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_models.dart';

class StoredSession {
  const StoredSession({required this.user, required this.refreshExpiresAt});

  factory StoredSession.fromJson(Map<String, dynamic> json) => StoredSession(
    user: UserProfile.fromJson(json['user'] as Map<String, dynamic>),
    refreshExpiresAt: DateTime.parse(json['refresh_expires_at'] as String),
  );

  final UserProfile user;
  final DateTime refreshExpiresAt;

  Map<String, dynamic> toJson() => {
    'user': user.toJson(),
    'refresh_expires_at': refreshExpiresAt.toUtc().toIso8601String(),
  };
}

abstract class SessionStore {
  Future<void> save(String deviceId, StoredSession session);

  /// `null` si no hay sesión guardada o es ilegible.
  Future<StoredSession?> read(String deviceId);

  Future<void> clear(String deviceId);
}

class SecureSessionStore implements SessionStore {
  const SecureSessionStore(this._storage);

  final FlutterSecureStorage _storage;

  static const _prefix = 'visitacampo.session.v1.';

  @override
  Future<void> save(String deviceId, StoredSession session) => _storage.write(
    key: '$_prefix$deviceId',
    value: jsonEncode(session.toJson()),
  );

  @override
  Future<StoredSession?> read(String deviceId) async {
    final raw = await _storage.read(key: '$_prefix$deviceId');
    if (raw == null) return null;
    try {
      return StoredSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      // Ilegible: sin sesión, se pide el login (el lado seguro).
      return null;
    }
  }

  @override
  Future<void> clear(String deviceId) =>
      _storage.delete(key: '$_prefix$deviceId');
}
