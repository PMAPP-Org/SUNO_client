// Pantalla posterior al login: "Nueva visita", "Sincronizar" y las visitas
// recientes con su estado.
//
// - "Sincronizar" hace, en orden, `drainOutbox()` (push de datos), un
//   drenaje de la cola de adjuntos y `pull()`.
// - Los adjuntos además se suben solos (Paso 18): el planificador arranca con
//   esta pantalla (la sesión ya existe), vuelve a drenar cuando la app pasa a
//   primer plano y cada minuto, y la lista se refresca tras cada drenaje.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/attachments/attachment_upload_scheduler.dart';
import '../../core/auth/auth_state.dart';
import '../../core/providers.dart';
import '../../core/sync/result.dart';
import '../../data/local/visit_status_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import '../auth/login_screen.dart';
import '../capture/capture_screen.dart';
import '../review/review_screen.dart';
import 'visit_status_list.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isSyncing = false;

  /// Visitas recientes con su estado (Paso 22). `null` mientras se cargan.
  List<VisitSummary>? _visits;

  late final AppLifecycleListener _lifecycle;
  StreamSubscription<void>? _drained;
  StreamSubscription<AuthState>? _session;

  /// Se guarda aquí porque `ref` ya no se puede usar dentro de `dispose()`:
  /// sin esta referencia el temporizador periódico sobreviviría a la pantalla
  /// (y a cerrar sesión).
  late final AttachmentUploadScheduler _scheduler;

  @override
  void initState() {
    super.initState();
    _loadVisits();
    _scheduler = ref.read(appDependenciesProvider).uploadScheduler;
    _drained = _scheduler.drained.listen((_) => _loadVisits());
    // Al volver de segundo plano: puede haber red de nuevo.
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_scheduler.nudge()));
    unawaited(_scheduler.start());
    // Reintento de la prueba de autorización (Ley 1581) si quedó pendiente.
    unawaited(ref.read(appDependenciesProvider).consent.syncPending());
    // Paso 16, tarea 7: sesión revocada en el servidor (p. ej. reuso del
    // refresh detectado) → login limpio. La outbox no se toca: lo capturado
    // se envía tras volver a entrar.
    final auth = ref.read(appDependenciesProvider).authController;
    _session = auth.changes.listen((state) {
      if (state is Disconnected) unawaited(_backToLogin());
    });
    // La sesión restaurada sin red se valida en segundo plano al arrancar: si
    // el servidor ya la revocó antes de abrir esta pantalla, el aviso no llegó
    // por `changes`.
    if (auth.state is Disconnected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_backToLogin()));
    }
  }

  Future<void> _backToLogin() async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.sessionEnded)),
    );
    await Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_session?.cancel());
    unawaited(_drained?.cancel());
    _scheduler.stop();
    super.dispose();
  }

  /// Visitas en cuarentena (Paso 23): el aviso "N para revisar".
  int _toReview = 0;

  Future<void> _loadVisits() async {
    final dependencies = ref.read(appDependenciesProvider);
    final authState = dependencies.authController.state;
    final orgId = authState is Authenticated ? authState.user.orgId : null;
    final visits = orgId == null
        ? const <VisitSummary>[]
        : await dependencies.visitStatus.recentVisits(orgId: orgId);
    final toReview = orgId == null ? 0 : await dependencies.quarantine.count(orgId: orgId);
    if (mounted) {
      setState(() {
        _visits = visits;
        _toReview = toReview;
      });
    }
  }

  Future<void> _openReview() async {
    final authState = ref.read(appDependenciesProvider).authController.state;
    if (authState is! Authenticated) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => ReviewScreen(orgId: authState.user.orgId)));
    await _loadVisits();
  }

  Future<void> _sync() async {
    final dependencies = ref.read(appDependenciesProvider);
    setState(() => _isSyncing = true);

    try {
      final drainReport = await dependencies.syncEngine.drainOutbox();
      // Por el planificador, no directo al servicio: si ya hay un drenaje en
      // curso (periódico, tras capturar) se espera a él en vez de correr dos.
      // `force`: el agente lo pidió, se intenta ya aunque haya backoff.
      final attachmentReport = await dependencies.uploadScheduler.nudge(force: true);
      // Lo que queda sin subir tras el intento, no solo lo que falló en esta
      // pasada: una foto en espera de reintento también es "no subida aún".
      final notUploaded = await dependencies.attachmentUploadService.outstanding();
      final pullResult = await dependencies.syncEngine.pull();

      if (!mounted) return;

      // Hallazgo Crítico/Importante de la revisión final: antes de este fix
      // el SnackBar siempre decía "completa" pase lo que pase -- descartaba
      // `quarantined`/`deferred` de `drainReport`, `failed` de
      // `attachmentReport` y el `Result` de `pull()`. Un operador del demo no
      // tenía forma de distinguir "todo sincronizó" de "el servidor rechazó
      // la visita" o "no se pudo subir la foto" con solo mirar la pantalla.
      final hasIssues =
          drainReport.quarantined > 0 ||
          drainReport.deferred > 0 ||
          notUploaded > 0 ||
          !pullResult.isOk;

      final l10n = context.l10n;
      final message = hasIssues
          ? [
              l10n.syncIncomplete(
                drainReport.applied,
                drainReport.quarantined,
                drainReport.deferred,
                attachmentReport.uploaded,
                notUploaded,
              ),
              if (!pullResult.isOk) l10n.syncPullFailed,
            ].join(' ')
          : l10n.syncComplete(drainReport.applied, attachmentReport.uploaded);

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      // Defensa en profundidad: pase lo que pase arriba, el botón nunca debe
      // quedar deshabilitado permanentemente (hallazgo de revisión Tarea 7).
      if (mounted) setState(() => _isSyncing = false);
      await _loadVisits();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dependencies = ref.watch(appDependenciesProvider);
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: AppPageBody(
        children: [
          Text(l10n.homeSessionStarted(dependencies.deviceId), textAlign: TextAlign.center),
          const AppGap.lg(),
          AppButton(
            key: const Key('home_new_visit_button'),
            label: l10n.homeNewVisit,
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CaptureScreen()),
              );
              // UI optimista: la visita recién guardada aparece ya, sin red.
              await _loadVisits();
            },
          ),
          const AppGap.sm(),
          AppButton(
            key: const Key('home_sync_button'),
            label: l10n.homeSync,
            loadingLabel: l10n.homeSyncing,
            isLoading: _isSyncing,
            onPressed: _sync,
          ),
          if (_toReview > 0) ...[
            const AppGap.sm(),
            // Badge de cuarentena (Paso 23): que el agente no las pierda de vista.
            FilledButton.tonalIcon(
              key: const Key('home_review_button'),
              icon: const Icon(Icons.report_problem_outlined),
              label: Text(l10n.homeReviewPending(_toReview)),
              onPressed: _openReview,
            ),
          ],
          const AppGap.lg(),
          Text(l10n.homeRecentVisits, style: Theme.of(context).textTheme.titleMedium),
          if (_visits == null)
            const Center(child: CircularProgressIndicator())
          else
            VisitStatusList(visits: _visits!),
        ],
      ),
    );
  }
}
