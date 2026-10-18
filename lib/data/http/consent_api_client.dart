// `ConsentApiClient` — `POST /v1/consents` (Ley 1581). Ver `core/privacy/consent.dart`.
import 'package:dio/dio.dart';

import '../../core/privacy/consent.dart';

class ConsentApiClient implements ConsentTransport {
  const ConsentApiClient(this._dio);

  final Dio _dio;

  @override
  Future<bool> record({
    required String accessToken,
    required String deviceId,
    required String noticeVersion,
    required Set<PrivacyPurpose> purposes,
    required DateTime acceptedAt,
  }) async {
    try {
      final response = await _dio.post<void>(
        '/v1/consents',
        data: {
          'device_id': deviceId,
          'notice_version': noticeVersion,
          'purposes': [
            for (final p in PrivacyPurpose.values)
              if (purposes.contains(p)) p.name,
          ],
          'accepted_at': acceptedAt.toUtc().toIso8601String(),
        },
        options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
      );
      return response.statusCode == 201;
    } on DioException {
      // Sin red, sesión caducada o rechazo: queda pendiente y se reintenta.
      return false;
    }
  }
}
