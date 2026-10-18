// Cuándo se sincroniza (Fase A, trabajo offline).
//
// Antes, las visitas solo se enviaban si el agente pulsaba "Sincronizar": una
// jornada entera podía quedarse en el teléfono aunque hubiera habido cobertura.
// Ahora el ciclo completo —enviar la outbox, subir adjuntos y traer cambios—
// se dispara solo:
// - al abrir la pantalla de inicio (incluida la sesión restaurada sin red),
// - al volver la app al primer plano,
// - cada [interval] mientras la app está abierta,
// - y justo después de guardar una visita.
// El botón "Sincronizar" usa este mismo coordinador con `force: true`
// (reintenta ya lo que estaba en espera).
//
// **Un ciclo a la vez** (single-flight), como el planificador de adjuntos: un
// disparo durante un ciclo deja pedido otro al terminar, en vez de correr dos
// en paralelo o perder la visita que se acaba de guardar.
//
// Sin red no pasa nada malo: la outbox tiene su propio backoff por operación
// y el pull falla rápido; el siguiente disparo lo intenta de nuevo.
//
// **Alcance**: con la app viva. Sincronizar con la app cerrada (WorkManager en
// Android, BGTaskScheduler en iOS) necesita validarse en dispositivo real y
// queda pendiente; lo pendiente persiste y sale en el siguiente ciclo.
import 'dart:async';

import '../attachments/attachment_upload_service.dart';
import 'result.dart';
import 'sync_engine.dart';

/// Resultado de un ciclo completo.
class SyncCycleReport {
  const SyncCycleReport({
    required this.drain,
    required this.attachments,
    required this.notUploaded,
    required this.pullOk,
    required this.finishedAt,
  });

  final DrainReport drain;
  final AttachmentDrainReport attachments;

  /// Adjuntos que siguen sin subir tras el ciclo (en espera o fallidos).
  final int notUploaded;
  final bool pullOk;
  final DateTime finishedAt;

  bool get hasIssues => drain.quarantined > 0 || drain.deferred > 0 || notUploaded > 0 || !pullOk;
}

class SyncCoordinator {
  SyncCoordinator({
    required this.drainOutbox,
    required this.uploadAttachments,
    required this.outstandingAttachments,
    required this.pull,
    required this.isAuthenticated,
    this.interval = const Duration(minutes: 5),
    Timer Function(Duration, void Function(Timer))? periodic,
    DateTime Function()? clock,
  }) : _periodic = periodic ?? Timer.periodic,
       _now = clock ?? DateTime.now;

  final Future<DrainReport> Function() drainOutbox;
  final Future<AttachmentDrainReport> Function({required bool force}) uploadAttachments;
  final Future<int> Function() outstandingAttachments;
  final Future<Result<bool>> Function() pull;

  /// Sin sesión no hay a quién enviar nada: no se intenta.
  final bool Function() isAuthenticated;
  final Duration interval;
  final Timer Function(Duration, void Function(Timer)) _periodic;
  final DateTime Function() _now;

  Timer? _timer;
  Future<SyncCycleReport?>? _running;
  bool _again = false;
  bool _againForced = false;

  final _completed = StreamController<SyncCycleReport>.broadcast();

  /// Un evento por ciclo terminado: la UI refresca la lista y el estado.
  Stream<SyncCycleReport> get completed => _completed.stream;

  SyncCycleReport? lastReport;

  /// Último ciclo sin incidencias (todo enviado, subido y recibido).
  DateTime? lastCleanSyncAt;

  bool get isStarted => _timer != null;

  /// Empieza a sincronizar sola. Idempotente.
  Future<void> start() async {
    if (_timer != null) return;
    _timer = _periodic(interval, (_) => unawaited(syncNow()));
    await syncNow();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Pide un ciclo. Si ya hay uno en curso, se encadena otro al terminar; el
  /// `Future` completa al acabar la cadena con el informe del último ciclo
  /// (`null` sin sesión).
  Future<SyncCycleReport?> syncNow({bool force = false}) {
    if (!isAuthenticated()) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      _againForced = _againForced || force;
      return running;
    }
    return _running = _run(force);
  }

  Future<SyncCycleReport?> _run(bool force) async {
    // Siempre asíncrono: si un paso lanzara de forma síncrona, `_running`
    // quedaría apuntando a un futuro terminado (mismo cuidado que en
    // `AttachmentUploadScheduler`).
    await Future<void>.value();
    try {
      var report = await _cycle(force);
      while (_again) {
        final forced = _againForced;
        _again = false;
        _againForced = false;
        report = await _cycle(forced);
      }
      return report;
    } finally {
      _running = null;
    }
  }

  Future<SyncCycleReport> _cycle(bool force) async {
    DrainReport drain = DrainReport.empty;
    AttachmentDrainReport attachments = AttachmentDrainReport.empty;
    var notUploaded = 0;
    var pullOk = false;
    // Cada paso por separado: que falle uno (p. ej. sin red) no impide los
    // demás ni deja el coordinador bloqueado.
    try {
      drain = await drainOutbox();
    } on Object {
      drain = DrainReport.empty;
    }
    try {
      attachments = await uploadAttachments(force: force);
      notUploaded = await outstandingAttachments();
    } on Object {
      attachments = AttachmentDrainReport.empty;
    }
    try {
      pullOk = (await pull()).isOk;
    } on Object {
      pullOk = false;
    }
    final report = SyncCycleReport(
      drain: drain,
      attachments: attachments,
      notUploaded: notUploaded,
      pullOk: pullOk,
      finishedAt: _now(),
    );
    lastReport = report;
    if (!report.hasIssues) lastCleanSyncAt = report.finishedAt;
    _completed.add(report);
    return report;
  }
}
