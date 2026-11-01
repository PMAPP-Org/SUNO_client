import 'package:visitacampo/core/schedule/schedule_task_sync.dart';

class FakeScheduleTaskTransport implements ScheduleTaskTransport {
  /// `null` = sin red.
  final List<ScheduleTaskPage?> responses = [];
  final List<String?> versions = [];

  @override
  Future<ScheduleTaskPage?> fetch({String? version}) async {
    versions.add(version);
    if (responses.isEmpty) {
      throw StateError('FakeScheduleTaskTransport.fetch() sin respuesta programada.');
    }
    return responses.removeAt(0);
  }
}
