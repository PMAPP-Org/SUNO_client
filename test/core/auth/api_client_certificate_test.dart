// Paso 16: el motivo de rechazo de `TrustStore` llega al login como
// `AuthError.certificate` (con el certificado, para el diálogo TOFU), y una
// URL `http://` como `AuthError.cleartext`.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/auth/auth_models.dart';
import 'package:visitacampo/core/auth/auth_result.dart';
import 'package:visitacampo/core/security/certificate_info.dart';
import 'package:visitacampo/core/security/trust_store.dart';
import 'package:visitacampo/data/http/api_client.dart';

import 'fake_http_client_adapter.dart';

const _deviceInfo = DeviceInfo(
  deviceId: 'device-1',
  platform: 'android',
  appVersion: '1.0.0',
);

final _certificate = CertificateInfo(
  spkiSha256: 'pin',
  sha256Fingerprint: 'AB:CD',
  subject: '/CN=campo.example',
  issuer: '/CN=campo.example',
  subjectAltNames: const ['campo.example'],
  notBefore: DateTime.utc(2026),
  notAfter: DateTime.utc(2027),
);

AuthApiClient _failingWith(Object cause) {
  final dio = Dio(BaseOptions(baseUrl: 'https://campo.example'))
    ..httpClientAdapter = FakeHttpClientAdapter((_) => throw cause);
  return AuthApiClient(dio);
}

void main() {
  test(
    'certificado no confiable → AuthError.certificate con el certificado',
    () async {
      final rejection = UntrustedCertificate(
        'campo.example',
        443,
        _certificate,
      );
      final result = await _failingWith(
        rejection,
      ).login(username: 'agente1', password: 'secret', deviceInfo: _deviceInfo);

      final error = (result as AuthErr<LoginResponse>).error;
      expect(error, isA<AuthCertificateError>());
      expect((error as AuthCertificateError).rejection, same(rejection));
    },
  );

  test(
    'pin incorrecto del servidor oficial → AuthError.certificate no aprobable',
    () async {
      final result = await _failingWith(
        PinMismatch('api.example', 443, _certificate),
      ).refresh(refreshToken: 'r', deviceId: 'device-1');

      final error =
          (result as AuthErr<TokenPair>).error as AuthCertificateError;
      expect(error.rejection.approvable, isFalse);
    },
  );

  test('http:// → AuthError.cleartext', () async {
    final result = await _failingWith(
      CleartextRefused(Uri.parse('http://campo.example')),
    ).login(username: 'agente1', password: 'secret', deviceInfo: _deviceInfo);

    expect((result as AuthErr<LoginResponse>).error, isA<AuthCleartextError>());
  });
}
