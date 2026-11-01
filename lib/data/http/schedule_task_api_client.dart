// `ScheduleTaskApiClient` — implementación Dio de `ScheduleTaskTransport`
// (costos, etapa 1). Como `LayerApiClient`: bearer por request y `null` sin red
// o ante una respuesta que no se entiende (la lista local se conserva).
import 'package:dio/dio.dart';

import '../../core/schedule/schedule_task_sync.dart';

class ScheduleTaskApiClient implements ScheduleTaskTransport {
  ScheduleTaskApiClient({required this.dio, required this.accessTokenProvider});

  final Dio dio;
  final String Function() accessTokenProvider;

  @override
  Future<ScheduleTaskPage?> fetch({String? version}) async {
    try {
      final response = await dio.get<Map<String, dynamic>>(
        '/v1/projects/tasks',
        queryParameters: {'version': ?version},
        options: Options(headers: {'Authorization': 'Bearer ${accessTokenProvider()}'}),
      );
      final data = response.data;
      return data == null ? null : ScheduleTaskPage.fromJson(data);
    } on DioException {
      return null;
    } on TypeError {
      return null;
    }
  }
}
