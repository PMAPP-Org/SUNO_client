// Fase A, trabajo offline: volver a entrar sin red con una sesión guardada y
// vigente; con la sesión caducada o revocada, login.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/auth/auth_models.dart';
import 'package:visitacampo/core/auth/auth_result.dart';
import 'package:visitacampo/core/auth/auth_state.dart';
import 'package:visitacampo/core/auth/session_store.dart';

import 'fake_auth_transport.dart';
import 'fake_token_store.dart';

class MemorySessionStore implements SessionStore {
  final Map<String, StoredSession> sessions = {};

  @override
  Future<void> save(String deviceId, StoredSession session) async =>
      sessions[deviceId] = session;

  @override
  Future<StoredSession?> read(String deviceId) async => sessions[deviceId];

  @override
  Future<void> clear(String deviceId) async => sessions.remove(deviceId);
}

const _user = UserProfile(
  id: 'u1',
  username: 'agente1',
  orgId: 'org1',
  roles: ['agent'],
);
const _device = DeviceInfo(
  deviceId: 'device-1',
  platform: 'android',
  appVersion: '1.0.0',
);

TokenPair _pair({
  String access = 'access-1',
  String refresh = 'refresh-1',
  int refreshTtl = 3600,
}) => TokenPair(
  accessToken: access,
  tokenType: 'Bearer',
  expiresIn: 900,
  refreshToken: refresh,
  refreshExpiresIn: refreshTtl,
  serverTime: DateTime.utc(2026, 10, 18),
);

void main() {
  late FakeAuthTransport transport;
  late FakeTokenStore tokens;
  late MemorySessionStore sessions;
  late DateTime now;

  AuthController controller() => AuthController(
    transport: transport,
    tokenStore: tokens,
    deviceId: 'device-1',
    sessionStore: sessions,
    clock: () => now,
  );

  setUp(() {
    transport = FakeAuthTransport();
    tokens = FakeTokenStore();
    sessions = MemorySessionStore();
    now = DateTime.utc(2026, 10, 18, 8);
  });

  Future<void> logIn({int refreshTtl = 3600}) async {
    transport.loginResponses.add(
      AuthResult.ok(
        LoginResponse(
          tokens: _pair(refreshTtl: refreshTtl),
          user: _user,
        ),
      ),
    );
    await controller().login(
      username: 'agente1',
      password: 'x',
      deviceInfo: _device,
    );
  }

  test(
    'tras el login, una app reiniciada entra sin red con el mismo usuario',
    () async {
      await logIn();
      final restarted = controller();

      expect(await restarted.restoreSession(), isTrue);
      expect((restarted.state as Authenticated).user, _user);
      expect(
        restarted.accessToken,
        isNull,
        reason: 'el access token nunca se persiste',
      );
      expect(
        transport.refreshCallCount,
        0,
        reason: 'restaurar no necesita red',
      );
    },
  );

  test('sin sesión guardada no se entra', () async {
    expect(await controller().restoreSession(), isFalse);
  });

  test('con el refresh caducado se pide login y se borra todo', () async {
    await logIn(refreshTtl: 60);
    now = now.add(const Duration(minutes: 2));

    expect(await controller().restoreSession(), isFalse);
    expect(tokens.isEmpty, isTrue);
    expect(sessions.sessions, isEmpty);
  });

  test(
    'sin red, el refresh falla pero la sesión sigue (se trabaja offline)',
    () async {
      await logIn();
      final restarted = controller();
      await restarted.restoreSession();
      transport.refreshResponses.add(
        const AuthResult.err(AuthError.network('sin cobertura')),
      );

      expect(await restarted.refreshOnce(), isFalse);
      expect(restarted.state, isA<Authenticated>());
      expect(
        await controller().restoreSession(),
        isTrue,
        reason: 'otro reinicio sigue entrando',
      );
    },
  );

  test(
    'si el servidor revocó la sesión (401), se borra y hay que entrar con contraseña',
    () async {
      await logIn();
      final restarted = controller();
      await restarted.restoreSession();
      transport.refreshResponses.add(
        const AuthResult.err(AuthError.unauthorized()),
      );

      await restarted.refreshOnce();
      expect(restarted.state, isA<Disconnected>());
      expect(await controller().restoreSession(), isFalse);
    },
  );

  test(
    'cada refresh alarga la sesión guardada con la caducidad nueva',
    () async {
      await logIn(refreshTtl: 60);
      final restarted = controller();
      await restarted.restoreSession();
      transport.refreshResponses.add(
        AuthResult.ok(_pair(access: 'a2', refresh: 'r2', refreshTtl: 7200)),
      );
      await restarted.refreshOnce();

      now = now.add(const Duration(minutes: 30));
      expect(await controller().restoreSession(), isTrue);
    },
  );

  test('cerrar sesión borra la sesión guardada', () async {
    await logIn();
    await controller().logout();
    expect(await controller().restoreSession(), isFalse);
  });

  group('SecureSessionStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('guarda y lee la sesión por dispositivo', () async {
      const store = SecureSessionStore(FlutterSecureStorage());
      await store.save(
        'device-1',
        StoredSession(user: _user, refreshExpiresAt: DateTime.utc(2027)),
      );
      final read = await store.read('device-1');
      expect(read!.user, _user);
      expect(read.refreshExpiresAt, DateTime.utc(2027));
      expect(await store.read('otro'), isNull);
    });

    test('un registro ilegible es "sin sesión"', () async {
      FlutterSecureStorage.setMockInitialValues({
        'visitacampo.session.v1.device-1': '{roto',
      });
      expect(
        await const SecureSessionStore(FlutterSecureStorage()).read('device-1'),
        isNull,
      );
    });
  });
}
