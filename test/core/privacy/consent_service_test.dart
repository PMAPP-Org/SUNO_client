// Ley 1581: la autorización del titular, en el teléfono y su envío al servidor.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/privacy/consent.dart';

class FakeConsentTransport implements ConsentTransport {
  final List<Map<String, Object>> calls = [];
  bool result = true;
  Object? error;

  @override
  Future<bool> record({
    required String accessToken,
    required String deviceId,
    required String noticeVersion,
    required Set<PrivacyPurpose> purposes,
    required DateTime acceptedAt,
  }) async {
    calls.add({
      'token': accessToken,
      'device': deviceId,
      'version': noticeVersion,
      'purposes': purposes,
      'accepted_at': acceptedAt,
    });
    if (error != null) throw error!;
    return result;
  }
}

const _all = {
  PrivacyPurpose.account,
  PrivacyPurpose.location,
  PrivacyPurpose.photos,
};

void main() {
  late FakeConsentTransport transport;
  late String token;

  ConsentService service() => ConsentService(
    store: const ConsentStore(FlutterSecureStorage()),
    transport: transport,
    accessTokenProvider: () => token,
    deviceId: 'device-1',
    clock: () => DateTime.utc(2026, 10, 18, 9, 30),
  );

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    transport = FakeConsentTransport();
    token = '';
  });

  test('sin aceptar, el aviso se muestra', () async {
    expect(await service().isAcceptedForCurrentVersion(), isFalse);
  });

  test(
    'aceptar las tres finalidades deja la app usable y persiste tras reiniciar',
    () async {
      await service().accept(_all);
      expect(
        await service().isAcceptedForCurrentVersion(),
        isTrue,
        reason: 'otra instancia, mismo almacén',
      );
    },
  );

  test('no se puede aceptar solo una parte', () async {
    expect(
      () => service().accept({PrivacyPurpose.account}),
      throwsArgumentError,
    );
    expect(await service().isAcceptedForCurrentVersion(), isFalse);
  });

  test('una versión anterior del aviso no vale: se vuelve a pedir', () async {
    await const ConsentStore(FlutterSecureStorage()).write(
      StoredConsent(
        noticeVersion: '2020-01-01',
        purposes: _all,
        acceptedAt: DateTime.utc(2020),
        sent: true,
      ),
    );
    expect(await service().isAcceptedForCurrentVersion(), isFalse);
  });

  test('un registro ilegible se trata como no aceptado', () async {
    FlutterSecureStorage.setMockInitialValues({
      'visitacampo.privacy_consent.v1': '{no-json',
    });
    expect(await service().isAcceptedForCurrentVersion(), isFalse);
  });

  group('envío de la prueba', () {
    test('sin sesión no se envía y queda pendiente', () async {
      await service().accept(_all);
      expect(await service().syncPending(), isFalse);
      expect(transport.calls, isEmpty);
    });

    test('con sesión se envía una vez, con lo aceptado', () async {
      await service().accept(_all);
      token = 'access-1';
      expect(await service().syncPending(), isTrue);
      expect(await service().syncPending(), isTrue, reason: 'ya enviada');
      expect(transport.calls, hasLength(1));
      final call = transport.calls.single;
      expect(call['token'], 'access-1');
      expect(call['device'], 'device-1');
      expect(call['version'], kPrivacyNoticeVersion);
      expect(call['purposes'], _all);
      expect(call['accepted_at'], DateTime.utc(2026, 10, 18, 9, 30));
    });

    test('si el servidor no la guarda, se reintenta la próxima vez', () async {
      await service().accept(_all);
      token = 'access-1';
      transport.result = false;
      expect(await service().syncPending(), isFalse);
      transport.error = StateError('sin red');
      expect(await service().syncPending(), isFalse, reason: 'nunca lanza');
      transport
        ..error = null
        ..result = true;
      expect(await service().syncPending(), isTrue);
      expect(transport.calls, hasLength(3));
    });

    test('sin autorización guardada no hay nada que enviar', () async {
      token = 'access-1';
      expect(await service().syncPending(), isFalse);
      expect(transport.calls, isEmpty);
    });
  });
}
