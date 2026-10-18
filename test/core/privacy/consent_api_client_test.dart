// `ConsentApiClient`: el cuerpo de `POST /v1/consents` es el del contrato
// (`components.schemas.ConsentRequest`), con el token de la sesión.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/privacy/consent.dart';
import 'package:visitacampo/data/http/consent_api_client.dart';

import '../auth/fake_http_client_adapter.dart';

void main() {
  Future<({bool ok, List<RequestOptions> requests})> call(int status) async {
    final adapter = FakeHttpClientAdapter(
      (_) async => jsonResponseBody({
        'id': 'x',
        'recorded_at': '2026-10-18T09:30:00.000Z',
      }, status),
    );
    final dio = Dio(BaseOptions(baseUrl: 'https://campo.example'))
      ..httpClientAdapter = adapter;
    final ok = await ConsentApiClient(dio).record(
      accessToken: 'access-1',
      deviceId: 'device-1',
      noticeVersion: '2026-10-18',
      purposes: {
        PrivacyPurpose.photos,
        PrivacyPurpose.account,
        PrivacyPurpose.location,
      },
      acceptedAt: DateTime.utc(2026, 10, 18, 9, 30),
    );
    return (ok: ok, requests: adapter.requests);
  }

  test('envía el cuerpo del contrato y el token', () async {
    final result = await call(201);
    expect(result.ok, isTrue);
    final request = result.requests.single;
    expect(request.path, '/v1/consents');
    expect(request.method, 'POST');
    expect(request.headers['Authorization'], 'Bearer access-1');
    expect(request.data, {
      'device_id': 'device-1',
      'notice_version': '2026-10-18',
      'purposes': ['account', 'location', 'photos'],
      'accepted_at': '2026-10-18T09:30:00.000Z',
    });
  });

  test('cualquier otra respuesta deja la prueba pendiente', () async {
    for (final status in [401, 404, 422, 500]) {
      expect((await call(status)).ok, isFalse, reason: 'HTTP $status');
    }
  });
}
