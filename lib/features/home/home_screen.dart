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
import '../capture/capture_screen.dart';
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
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    unawaited(_drained?.cancel());
    _scheduler.stop();
    super.dispose();
  }

  Future<void> _loadVisits() async {
    final dependencies = ref.read(appDependenciesProvider);
    final authState = dependencies.authController.state;
    final visits = authState is Authenticated
        ? await dependencies.visitStatus.recentVisits(orgId: authState.user.orgId)
        : const <VisitSummary>[];
    if (mounted) setState(() => _visits = visits);
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
