// Cuándo se drena la cola de adjuntos (Paso 18).
//
// La subida no depende de que el agente pulse "Sincronizar": se dispara sola
// - al empezar la sesión (recuperando primero las subidas que la app dejó a
//   medias al morir),
// - al volver la app al primer plano,
// - cada [interval] mientras la app está abierta,
// - y al guardar una visita o terminar un push ([nudge]).
//
// **Un solo drenaje a la vez** (single-flight): un disparo que llega durante
// un drenaje no lanza otro en paralelo, sino que deja pedido uno más al
// terminar, para no perder la foto que se acaba de capturar.
//
// **Alcance**: mientras la app vive (primer plano o recién minimizada). La
// subida con la app cerrada o suspendida mucho tiempo necesita un mecanismo
// del sistema (WorkManager en Android, BGTaskScheduler en iOS) y su
// validación en dispositivo real; queda pendiente (ver el seguimiento del
// Paso 18). Lo que hay aquí no se pierde con eso: la cola persiste y se
// retoma en el siguiente arranque.
import 'dart:async';

import 'attachment_upload_service.dart';

class AttachmentUploadScheduler {
  AttachmentUploadScheduler({
    required this.service,
    required this.isAuthenticated,
    this.interval = const Duration(minutes: 1),
    Timer Function(Duration, void Function(Timer))? periodic,
  }) : _periodic = periodic ?? Timer.periodic;

  final AttachmentUploadService service;

  /// Sin sesión no hay a quién pedirle el presign: no se intenta.
  final bool Function() isAuthenticated;
  final Duration interval;
  final Timer Function(Duration, void Function(Timer)) _periodic;

  Timer? _timer;
  Future<AttachmentDrainReport>? _running;
  bool _again = false;
  bool _againForced = false;
  final _drained = StreamController<AttachmentDrainReport>.broadcast();

  /// Último resultado, para quien quiera mostrarlo.
  AttachmentDrainReport lastReport = AttachmentDrainReport.empty;

  /// Un evento por drenaje terminado: la UI refresca el estado de las visitas.
  Stream<AttachmentDrainReport> get drained => _drained.stream;

  bool get isStarted => _timer != null;

  /// Empieza a drenar sola. Idempotente.
  Future<void> start() async {
    if (_timer != null) return;
    _timer = _periodic(interval, (_) => unawaited(nudge()));
    await service.recoverInterrupted();
    await nudge();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Pide un drenaje. Si ya hay uno en curso, se encadena otro al terminar; el
  /// `Future` devuelto completa al acabar la cadena, con el informe del último
  /// drenaje. (Para saber cuánto queda sin subir:
  /// `AttachmentUploadService.outstanding`.)
  ///
  /// [force] (botón "Sincronizar"): ignora el backoff y reintenta las
  /// fallidas (`AttachmentUploadService.drainPending`).
  Future<AttachmentDrainReport> nudge({bool force = false}) {
    if (!isAuthenticated()) return Future.value(AttachmentDrainReport.empty);
    final running = _running;
    if (running != null) {
      _again = true;
      _againForced = _againForced || force;
      return running;
    }
    return _running = _drain(force);
  }

  Future<AttachmentDrainReport> _drain(bool force) async {
    // Arranca siempre en asíncrono. Si `drainPending` lanzara de forma
    // síncrona, el `finally` (`_running = null`) correría *antes* de que
    // `nudge` asignara `_running`, que quedaría apuntando para siempre a un
    // futuro terminado: ningún disparo posterior volvería a drenar.
    await Future<void>.value();
    try {
      var report = await service.drainPending(force: force);
      while (_again) {
        final forced = _againForced;
        _again = false;
        _againForced = false;
        report = await service.drainPending(force: forced);
      }
      lastReport = report;
      _drained.add(report);
      return report;
    } on Object catch (error, stack) {
      // Un drenaje que falla (p. ej. la BD local) no puede convertirse en un
      // error asíncrono no controlado desde el temporizador: se informa y el
      // siguiente disparo lo vuelve a intentar. Nada se pierde: la cola está
      // en la BD, no en memoria.
      _again = false;
      _againForced = false;
      onError?.call(error, stack);
      return AttachmentDrainReport.empty;
    } finally {
      _running = null;
    }
  }

  /// Dónde se informa un drenaje fallido (por defecto, a ningún sitio; la app
  /// lo puede enviar a su log).
  void Function(Object error, StackTrace stack)? onError;
}
