// Paso 16 (H-01, RD-01, ADR-009): `TrustStore` contra servidores HTTPS
// reales. Las órdenes de verificación del plan:
// - host con certificado inválido y sin pin → rechazado;
// - pin SPKI correcto (actual o siguiente) → aceptado;
// - pin caducado → fail-open a la validación de CA estándar;
// y además: nada se envía antes de verificar, TOFU, cambio de certificado
// bloqueado, CA privada aprobada y sin texto plano.
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/security/pin_store.dart';
import 'package:visitacampo/core/security/trust_store.dart';

import 'tls_fixtures.dart';

const _timeout = Timeout(Duration(seconds: 60));

Dio _dio(TrustStore trust, String baseUrl) {
  final dio = Dio(BaseOptions(baseUrl: baseUrl));
  dio.httpClientAdapter = trust.adapter();
  return dio;
}

/// El motivo del rechazo que viaja dentro del `DioException`.
Future<Object?> _rejection(Future<Object?> request) async {
  try {
    await request;
  } on DioException catch (e) {
    return e.error;
  }
  fail('la petición tenía que rechazarse');
}

TrustStore _trust({SpkiPinPolicy? pins, DateTime? now, Pem? trustedCa}) =>
    TrustStore(
      pinStore: const PinStore(FlutterSecureStorage()),
      officialPins: pins,
      context: trustedCa == null ? null : trusting(trustedCa),
      now: now == null ? null : () => now,
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('servidor autohospedado (TOFU)', () {
    test(
      'certificado no confiable y sin pin: rechazado, sin enviar nada',
      () async {
        final certs = await CertFactory.create();
        final pem = await certs.selfSigned();
        final server = await TlsServer.start(pem);
        final trust = _trust();

        final error = await _rejection(
          _dio(trust, server.baseUrl).get<Object?>('/v1/server/info'),
        );

        expect(error, isA<UntrustedCertificate>());
        final rejection = error! as UntrustedCertificate;
        expect(rejection.approvable, isTrue);
        expect(rejection.certificate!.commonName, 'localhost');
        expect(
          rejection.certificate!.spkiSha256,
          await certs.spkiPin(pem),
          reason: 'el pin coincide con openssl',
        );
        expect(server.requests, 0);
      },
      timeout: _timeout,
    );

    test(
      'tras aprobarlo, conecta; si el certificado cambia, se bloquea',
      () async {
        final certs = await CertFactory.create();
        final first = await certs.selfSigned();
        final server = await TlsServer.start(first);
        final trust = _trust();
        final dio = _dio(trust, server.baseUrl);

        final rejection =
            (await _rejection(dio.get<Object?>('/')))! as UntrustedCertificate;
        await trust.approve('localhost', server.port, rejection.certificate!);
        expect((await dio.get<Object?>('/')).statusCode, 200);
        expect(server.requests, 1);

        // Mismo host y puerto, otra clave: hay que volver a aprobar.
        final port = server.port;
        await server.close();
        final replaced = await TlsServer.start(
          await certs.selfSigned(),
          port: port,
        );
        final changed = await _rejection(
          _dio(trust, replaced.baseUrl).get<Object?>('/'),
        );
        expect(changed, isA<CertificateChanged>());
        expect(
          (changed! as CertificateChanged).previous.spkiSha256,
          rejection.certificate!.spkiSha256,
        );
        expect(replaced.requests, 0);
      },
      timeout: _timeout,
    );

    test(
      'un host aprobado que pasa a un certificado de CA "pública" también se bloquea',
      () async {
        final certs = await CertFactory.create();
        final ca = await certs.ca();
        final server = await TlsServer.start(await certs.selfSigned());
        final trust = _trust(trustedCa: ca);
        final rejection =
            (await _rejection(_dio(trust, server.baseUrl).get<Object?>('/')))!
                as UntrustedCertificate;
        await trust.approve('localhost', server.port, rejection.certificate!);

        final port = server.port;
        await server.close();
        final publicCert = await TlsServer.start(
          await certs.signedBy(ca),
          port: port,
        );
        final changed = await _rejection(
          _dio(trust, publicCert.baseUrl).get<Object?>('/'),
        );
        expect(changed, isA<CertificateChanged>());
        expect(publicCert.requests, 0);
      },
      timeout: _timeout,
    );

    test(
      'aprobar una CA privada deja pasar a sus certificados de servidor',
      () async {
        final certs = await CertFactory.create();
        final ca = await certs.ca(cn: 'CA privada del cliente');
        final server = await TlsServer.start(
          await certs.signedBy(ca, withChain: true),
        );
        final trust = _trust();

        final rejection =
            (await _rejection(_dio(trust, server.baseUrl).get<Object?>('/')))!
                as UntrustedCertificate;
        await trust.approve('localhost', server.port, rejection.certificate!);
        expect(
          (await _dio(trust, server.baseUrl).get<Object?>('/')).statusCode,
          200,
        );

        // Otro certificado de la misma CA (renovación) sigue valiendo.
        final port = server.port;
        await server.close();
        final renewed = await TlsServer.start(
          await certs.signedBy(ca, withChain: true),
          port: port,
        );
        expect(
          (await _dio(trust, renewed.baseUrl).get<Object?>('/')).statusCode,
          200,
        );
      },
      timeout: _timeout,
    );

    test(
      'un pin aprobado vale para su host:puerto, no para otro puerto',
      () async {
        final certs = await CertFactory.create();
        final pem = await certs.selfSigned();
        final a = await TlsServer.start(pem);
        final b = await TlsServer.start(pem);
        final trust = _trust();
        final rejection =
            (await _rejection(_dio(trust, a.baseUrl).get<Object?>('/')))!
                as UntrustedCertificate;
        await trust.approve('localhost', a.port, rejection.certificate!);

        expect(
          await _rejection(_dio(trust, b.baseUrl).get<Object?>('/')),
          isA<UntrustedCertificate>(),
        );
        expect(b.requests, 0);
      },
      timeout: _timeout,
    );
  });

  group('servidor oficial (pinning SPKI)', () {
    test('pin actual o siguiente: aceptado', () async {
      final certs = await CertFactory.create();
      final ca = await certs.ca();
      final leaf = await certs.signedBy(ca);
      final server = await TlsServer.start(leaf);
      final pin = await certs.spkiPin(leaf);

      for (final pins in [
        {pin, 'b3RybyBwaW4='},
        {'b3RybyBwaW4=', pin},
      ]) {
        final policy = SpkiPinPolicy(
          host: 'localhost',
          pins: pins,
          expiresAt: DateTime.utc(2100),
        );
        final response = await _dio(
          _trust(pins: policy, trustedCa: ca),
          server.baseUrl,
        ).get<Object?>('/');
        expect(response.statusCode, 200);
      }
    }, timeout: _timeout);

    test(
      'clave fuera de los pines: rechazado ANTES de enviar la petición',
      () async {
        final certs = await CertFactory.create();
        final ca = await certs.ca();
        final server = await TlsServer.start(await certs.signedBy(ca));
        final policy = SpkiPinPolicy(
          host: 'localhost',
          pins: {'cGluIGFjdHVhbA==', 'cGluIHNpZ3VpZW50ZQ=='},
          expiresAt: DateTime.utc(2100),
        );

        final dio = _dio(_trust(pins: policy, trustedCa: ca), server.baseUrl);
        final error = await _rejection(
          dio.post<Object?>('/v1/auth/login', data: {'password': 'secreta'}),
        );

        expect(error, isA<PinMismatch>());
        expect((error! as PinMismatch).approvable, isFalse);
        expect(
          server.requests,
          0,
          reason:
              'la contraseña no puede salir hacia un servidor con otra clave',
        );
      },
      timeout: _timeout,
    );

    test(
      'pines caducados: fail-open a la validación de CA estándar',
      () async {
        final certs = await CertFactory.create();
        final ca = await certs.ca();
        final server = await TlsServer.start(await certs.signedBy(ca));
        final policy = SpkiPinPolicy(
          host: 'localhost',
          pins: {'cGluIGFjdHVhbA==', 'cGluIHNpZ3VpZW50ZQ=='},
          expiresAt: DateTime.utc(2026),
        );

        final dio = _dio(
          _trust(pins: policy, trustedCa: ca, now: DateTime.utc(2026, 6)),
          server.baseUrl,
        );
        expect((await dio.get<Object?>('/')).statusCode, 200);
      },
      timeout: _timeout,
    );

    test(
      'caducados o no, un certificado no confiable nunca se acepta ni se ofrece aprobar',
      () async {
        final certs = await CertFactory.create();
        final pem = await certs.selfSigned();
        final server = await TlsServer.start(pem);
        final policy = SpkiPinPolicy(
          host: 'localhost',
          pins: {await certs.spkiPin(pem), 'eA=='},
          expiresAt: DateTime.utc(2026),
        );
        final trust = _trust(pins: policy, now: DateTime.utc(2026, 6));

        final error = await _rejection(
          _dio(trust, server.baseUrl).get<Object?>('/'),
        );
        expect(error, isA<PinMismatch>());
        expect(
          () => trust.approve(
            'localhost',
            server.port,
            (error! as PinMismatch).certificate!,
          ),
          throwsStateError,
        );
      },
      timeout: _timeout,
    );
  });

  test('sin texto plano: http:// se rechaza sin conectar', () async {
    final error = await _rejection(
      _dio(_trust(), 'http://localhost:9').get<Object?>('/'),
    );
    expect(error, isA<CleartextRefused>());
  });

  group('SpkiPinPolicy.parse', () {
    test('sin pines no hay servidor oficial', () {
      expect(
        SpkiPinPolicy.parse(
          apiBaseUrl: 'https://x',
          rawPins: '',
          rawExpiry: '',
        ),
        isNull,
      );
    });

    test('un solo pin o sin caducidad: el build no arranca', () {
      expect(
        () => SpkiPinPolicy.parse(
          apiBaseUrl: 'https://x',
          rawPins: 'a',
          rawExpiry: '2030-01-01',
        ),
        throwsArgumentError,
      );
      expect(
        () => SpkiPinPolicy.parse(
          apiBaseUrl: 'https://x',
          rawPins: 'a,b',
          rawExpiry: '',
        ),
        throwsArgumentError,
      );
    });

    test('lee host, pines y caducidad', () {
      final policy = SpkiPinPolicy.parse(
        apiBaseUrl: 'https://API.Ejemplo.co',
        rawPins: ' a , b ',
        rawExpiry: '2030-01-01',
      )!;
      expect(policy.host, 'api.ejemplo.co');
      expect(policy.pins, {'a', 'b'});
      expect(policy.isActiveAt(DateTime.utc(2029)), isTrue);
      expect(policy.isActiveAt(DateTime.utc(2030, 2)), isFalse);
    });
  });
}
