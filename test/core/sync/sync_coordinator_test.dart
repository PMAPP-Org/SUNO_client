// Fase A: la sincronización se dispara sola, un ciclo a la vez, y un paso que
// falla (sin red) no bloquea los demás ni el siguiente ciclo.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/attachments/attachment_upload_service.dart';
import 'package:visitacampo/core/sync/result.dart';
import 'package:visitacampo/core/sync/sync_coordinator.dart';
import 'package:visitacampo/core/sync/sync_engine.dart';

class _Steps {
  final calls = <String>[];
  bool authenticated = true;
  bool pullFails = false;
  bool drainThrows = false;
  int outstanding = 0;
  final forces = <bool>[];
  Completer<void>? drainGate;

  Future<DrainReport> drain() async {
    calls.add('drain');
    await drainGate?.future;
    if (drainThrows) throw StateError('sin red');
    return const DrainReport(sent: 1, applied: 1, conflicted: 0, quarantined: 0, deferred: 0);
  }

  Future<AttachmentDrainReport> upload({required bool force}) async {
    calls.add('upload');
    forces.add(force);
    return const AttachmentDrainReport(uploaded: 1, failed: 0);
  }

  Future<int> outstandingCount() async => outstanding;

  Future<Result<bool>> pull() async {
    calls.add('pull');
    return pullFails ? Result.err(const SyncError.network('sin cobertura')) : Result.ok(false);
  }
}

void main() {
  late _Steps steps;
  late List<void Function(Timer)> ticks;

  SyncCoordinator coordinator() => SyncCoordinator(
    drainOutbox: steps.drain,
    uploadAttachments: steps.upload,
    outstandingAttachments: steps.outstandingCount,
    pull: steps.pull,
    isAuthenticated: () => steps.authenticated,
    periodic: (_, callback) {
      ticks.add(callback);
      return Timer(const Duration(days: 1), () {});
    },
    clock: () => DateTime.utc(2026, 10, 18, 9),
  );

  setUp(() {
    steps = _Steps();
    ticks = [];
  });

  test('un ciclo envía la outbox, sube adjuntos y trae cambios, en ese orden', () async {
    final report = await coordinator().syncNow();
    expect(steps.calls, ['drain', 'upload', 'pull']);
    expect(report!.hasIssues, isFalse);
  });

  test('start sincroniza ya y programa el periódico; stop lo cancela', () async {
    final c = coordinator();
    await c.start();
    expect(steps.calls, ['drain', 'upload', 'pull']);
    expect(ticks, hasLength(1));
    expect(c.isStarted, isTrue);

    await c.start();
    expect(ticks, hasLength(1), reason: 'start es idempotente');

    ticks.single(Timer(Duration.zero, () {}));
    await pumpEventQueue();
    expect(steps.calls, hasLength(6), reason: 'el tick periódico corre otro ciclo');

    c.stop();
    expect(c.isStarted, isFalse);
  });

  test('sin sesión no se intenta nada', () async {
    steps.authenticated = false;
    expect(await coordinator().syncNow(), isNull);
    expect(steps.calls, isEmpty);
  });

  test('un disparo durante un ciclo encadena uno más, nunca dos en paralelo', () async {
    final c = coordinator();
    steps.drainGate = Completer<void>();
    final first = c.syncNow();
    await pumpEventQueue();
    // Se guarda una visita mientras sincroniza: no se pierde ni se duplica.
    final second = c.syncNow(force: true);
    final third = c.syncNow();
    expect(steps.calls, ['drain'], reason: 'el segundo espera al primero');

    steps.drainGate!.complete();
    await Future.wait([first, second, third]);
    expect(steps.calls, ['drain', 'upload', 'pull', 'drain', 'upload', 'pull']);
    expect(steps.forces, [false, true], reason: 'el force pedido se conserva');
  });

  test('si un paso falla, los demás corren y el siguiente ciclo también', () async {
    final c = coordinator();
    steps
      ..drainThrows = true
      ..pullFails = true;
    final report = await c.syncNow();
    expect(steps.calls, ['drain', 'upload', 'pull']);
    expect(report!.hasIssues, isTrue);
    expect(c.lastCleanSyncAt, isNull);

    steps
      ..drainThrows = false
      ..pullFails = false;
    expect((await c.syncNow())!.hasIssues, isFalse);
    expect(c.lastCleanSyncAt, DateTime.utc(2026, 10, 18, 9));
  });

  test('adjuntos sin subir cuentan como pendiente', () async {
    steps.outstanding = 2;
    final report = await coordinator().syncNow();
    expect(report!.notUploaded, 2);
    expect(report.hasIssues, isTrue);
  });

  test('cada ciclo terminado se anuncia para refrescar la pantalla', () async {
    final c = coordinator();
    final events = <SyncCycleReport>[];
    final sub = c.completed.listen(events.add);
    addTearDown(sub.cancel);
    await c.syncNow();
    await pumpEventQueue();
    expect(events, hasLength(1));
    expect(c.lastReport, same(events.single));
  });
}
