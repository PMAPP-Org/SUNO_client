// Estado de sincronización visible al agente (Paso 22, tarea 6).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/data/local/record_status_repository.dart';
import 'package:suno/features/home/record_status_list.dart';

import '../../support/test_app.dart';

RecordSummary summary(String id, RecordSyncStatus status, {int attachments = 0, int pending = 0}) => RecordSummary(
  id: id,
  templateName: 'Inspección $id',
  capturedAt: DateTime.utc(2026, 10, 17, 15, 30),
  status: status,
  attachments: attachments,
  pendingUploads: pending,
);

void main() {
  testWidgets('cada registro muestra su estado y los adjuntos por subir', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: RecordStatusList(
            records: [
              summary('a', RecordSyncStatus.pending, attachments: 10, pending: 10),
              summary('b', RecordSyncStatus.synced, attachments: 2, pending: 1),
              summary('c', RecordSyncStatus.rejected),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Pendiente'), findsOneWidget);
    expect(find.text('Sincronizado'), findsOneWidget);
    expect(find.text('Rechazado'), findsOneWidget);
    expect(find.textContaining('10 adjuntos · 10 por subir'), findsOneWidget);
    expect(find.textContaining('2 adjuntos · 1 por subir'), findsOneWidget, reason: 'sincronizada con fotos pendientes');
  });

  testWidgets('sin registros lo dice', (tester) async {
    await tester.pumpWidget(testApp(const Scaffold(body: RecordStatusList(records: []))));
    expect(find.byKey(const Key('home_no_records')), findsOneWidget);
  });
}
