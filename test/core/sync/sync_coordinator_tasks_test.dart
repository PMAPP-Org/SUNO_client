// Costos, etapa 1: cada ciclo refresca las tareas del cronograma tras el pull;
// si falla (sin red), el ciclo termina igual.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/attachments/attachment_upload_service.dart';
import 'package:visitacampo/core/sync/result.dart';
import 'package:visitacampo/core/sync/sync_coordinator.dart';
import 'package:visitacampo/core/sync/sync_engine.dart';

SyncCoordinator _coordinator(List<String> calls, Future<bool> Function() refreshTasks) => SyncCoordinator(
  drainOutbox: () async {
    calls.add('drain');
    return DrainReport.empty;
  },
  uploadAttachments: ({required force}) async {
    calls.add('upload');
    return AttachmentDrainReport.empty;
  },
  outstandingAttachments: () async => 0,
  pull: () async {
    calls.add('pull');
    return Result.ok(true);
  },
  isAuthenticated: () => true,
  refreshTasks: refreshTasks,
  periodic: (_, _) => Timer(const Duration(days: 1), () {}),
);

void main() {
  test('tras el pull refresca las tareas del cronograma', () async {
    final calls = <String>[];
    await _coordinator(calls, () async {
      calls.add('tasks');
      return true;
    }).syncNow();
    expect(calls, ['drain', 'upload', 'pull', 'tasks']);
  });

  test('si falla, el ciclo termina sin incidencias nuevas', () async {
    final report = await _coordinator(<String>[], () async => throw StateError('sin red')).syncNow();
    expect(report!.hasIssues, isFalse);
  });
}
