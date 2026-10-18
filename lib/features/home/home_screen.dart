// Pantalla posterior al login: "Nueva visita", "Sincronizar" y las visitas
// recientes con su estado.
//
// - La sincronización es automática (Fase A, `SyncCoordinator`): arranca con
//   esta pantalla, al volver a primer plano, cada 5 minutos y tras guardar
//   una visita. "Sincronizar" fuerza un ciclo ya y muestra su resultado.
// - Los adjuntos además se suben solos (Paso 18): el planificador arranca con
//   esta pantalla, vuelve a drenar cuando la app pasa a primer plano y cada
//   minuto. La lista se refresca tras cada drenaje y cada ciclo.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/attachments/attachment_upload_scheduler.dart';
import '../../core/auth/auth_state.dart';
import '../../core/basemaps/basemap_manager.dart';
import '../../core/providers.dart';
import '../../core/sync/sync_coordinator.dart';
import '../../data/local/assignment_repository.dart';
import '../../data/local/visit_status_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_icons.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_brand.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import '../auth/login_screen.dart';
import '../capture/capture_screen.dart';
import '../assignments/assignments_screen.dart';
import '../map/map_screen.dart';
import '../review/review_screen.dart';
import '../settings/settings_screen.dart';
import '../visits/visit_detail_screen.dart';
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
  late final SyncCoordinator _coordinator;
  StreamSubscription<SyncCycleReport>? _cycles;

  @override
  void initState() {
    super.initState();
    _loadVisits();
    final dependencies = ref.read(appDependenciesProvider);
    _scheduler = dependencies.uploadScheduler;
    _coordinator = dependencies.syncCoordinator;
    _drained = _scheduler.drained.listen((_) => _loadVisits());
    _cycles = _coordinator.completed.listen((report) {
      unawaited(_loadVisits());
      // Fase B: con red, el mapa base de la organización llega solo (también
      // tras el primer login). Aparte del ciclo: un paquete de cientos de MB
      // no retrasa el envío de las visitas.
      if (report.pullOk) {
        unawaited(dependencies.basemaps.syncAll());
        // Fase C: las capas de referencia llegan igual, solas.
        unawaited(dependencies.layers.syncAll());
      }
    });
    // Al volver de segundo plano: puede haber red de nuevo. El ciclo incluye
    // los adjuntos (mismo planificador, sin drenajes en paralelo).
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_coordinator.syncNow()),
    );
    unawaited(_scheduler.start());
    unawaited(_coordinator.start());
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
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_backToLogin()),
      );
    }
  }

  Future<void> _backToLogin() async {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.sessionEnded)));
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
    unawaited(_cycles?.cancel());
    _scheduler.stop();
    _coordinator.stop();
    super.dispose();
  }

  /// Visitas en cuarentena (Paso 23): el aviso "N para revisar".
  int _toReview = 0;

  /// Asignaciones del agente (Fase B): `null` si no tiene ninguna; si no,
  /// cuántas quedan pendientes.
  int? _pendingAssignments;

  /// Búsqueda y paginado de la lista (Fase A): de [_pageSize] en
  /// [_pageSize], con "Ver más".
  static const _pageSize = 50;
  int _limit = _pageSize;
  String _query = '';

  Future<void> _loadVisits() async {
    final dependencies = ref.read(appDependenciesProvider);
    final authState = dependencies.authController.state;
    final orgId = authState is Authenticated ? authState.user.orgId : null;
    final query = _query;
    final visits = orgId == null
        ? const <VisitSummary>[]
        : await dependencies.visitStatus.recentVisits(
            orgId: orgId,
            limit: _limit,
            query: query,
          );
    final toReview = orgId == null
        ? 0
        : await dependencies.quarantine.count(orgId: orgId);
    final assignments = authState is Authenticated
        ? await dependencies.assignments.forUser(
            orgId: authState.user.orgId,
            userId: authState.user.id,
          )
        : const <AssignmentItem>[];
    // Una búsqueda más nueva ya está en camino: este resultado está viejo.
    if (mounted && query == _query) {
      setState(() {
        _visits = visits;
        _toReview = toReview;
        _pendingAssignments = assignments.isEmpty ? null : assignments.where((a) => !a.done).length;
      });
    }
  }

  Future<void> _openAssignments() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AssignmentsScreen()));
    await _loadVisits();
  }

  void _search(String query) {
    _query = query;
    _limit = _pageSize;
    unawaited(_loadVisits());
  }

  void _loadMore() {
    _limit += _pageSize;
    unawaited(_loadVisits());
  }

  Future<void> _openVisit(VisitSummary visit) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VisitDetailScreen(visitId: visit.id),
      ),
    );
    await _loadVisits();
  }

  Future<void> _openReview() async {
    final authState = ref.read(appDependenciesProvider).authController.state;
    if (authState is! Authenticated) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReviewScreen(orgId: authState.user.orgId),
      ),
    );
    await _loadVisits();
  }

  Future<void> _sync() async {
    final dependencies = ref.read(appDependenciesProvider);
    setState(() => _isSyncing = true);

    try {
      // Por el coordinador, no directo al motor: si ya hay un ciclo en curso
      // (automático, tras capturar) se encadena uno más en vez de correr dos.
      // `force`: el agente lo pidió, los adjuntos se intentan ya aunque haya
      // backoff.
      final report = await dependencies.syncCoordinator.syncNow(force: true);

      if (!mounted || report == null) return;

      // Hallazgo Crítico/Importante de la revisión final: el SnackBar no puede
      // decir "completa" si hubo rechazos, reintentos, adjuntos sin subir o
      // el pull falló (`SyncCycleReport.hasIssues`).
      final drainReport = report.drain;
      final l10n = context.l10n;
      final message = report.hasIssues
          ? [
              l10n.syncIncomplete(
                drainReport.applied,
                drainReport.quarantined,
                drainReport.deferred,
                report.attachments.uploaded,
                report.notUploaded,
              ),
              if (!report.pullOk) l10n.syncPullFailed,
            ].join(' ')
          : l10n.syncComplete(drainReport.applied, report.attachments.uploaded);

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } finally {
      // Defensa en profundidad: pase lo que pase arriba, el botón nunca debe
      // quedar deshabilitado permanentemente (hallazgo de revisión Tarea 7).
      if (mounted) setState(() => _isSyncing = false);
      await _loadVisits();
    }
  }

  /// Estado de la sincronización automática: que el agente sepa, sin pulsar
  /// nada, si lo capturado ya salió del teléfono.
  List<Widget> _syncStatus(AppLocalizations l10n) {
    final last = _coordinator.lastReport;
    final cleanAt = _coordinator.lastCleanSyncAt;
    return [
      if (last != null && last.hasIssues) ...[
        const AppGap.sm(),
        Text(
          l10n.homeSyncPending,
          key: const Key('home_sync_pending'),
          textAlign: TextAlign.center,
        ),
      ],
      if (cleanAt != null) ...[
        const AppGap.sm(),
        Text(
          l10n.homeLastSync(cleanAt.toLocal()),
          key: const Key('home_last_sync'),
          textAlign: TextAlign.center,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: const AppBrand(),
        actions: [
          IconButton(
            key: const Key('home_map'),
            tooltip: l10n.mapTitle,
            icon: const Icon(Icons.map_outlined),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MapScreen()));
              await _loadVisits();
            },
          ),
          IconButton(
            key: const Key('home_settings'),
            tooltip: l10n.settingsTitle,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: AppPageBody(
        children: [
          Text(
            l10n.brandDescriptor,
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const AppGap.sm(),
          Text(
            l10n.homeHeading,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const AppGap.sm(),
          Text(l10n.homeIntro, style: Theme.of(context).textTheme.bodyMedium),
          const AppGap.lg(),
          AppButton(
            key: const Key('home_new_visit_button'),
            label: l10n.homeNewVisit,
            icon: AppIcons.visit,
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
            icon: AppIcons.sync,
            secondary: true,
            loadingLabel: l10n.homeSyncing,
            isLoading: _isSyncing,
            onPressed: _sync,
          ),
          ..._syncStatus(l10n),
          ValueListenableBuilder<BasemapProgress?>(
            valueListenable: ref.read(appDependenciesProvider).basemaps.progress,
            builder: (context, progress, _) => progress == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.sm),
                    child: Column(
                      key: const Key('home_basemap_progress'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          progress.fraction == null
                              ? l10n.homeBasemapDownloading(progress.name)
                              : l10n.homeBasemapDownloadingPercent(
                                  progress.name,
                                  (progress.fraction! * 100).round(),
                                ),
                        ),
                        LinearProgressIndicator(value: progress.fraction),
                      ],
                    ),
                  ),
          ),
          if (_pendingAssignments case final pending?) ...[
            const AppGap.sm(),
            OutlinedButton.icon(
              key: const Key('home_assignments_button'),
              icon: const Icon(Icons.assignment_outlined),
              label: Text(l10n.homeAssignments(pending)),
              onPressed: _openAssignments,
            ),
          ],
          if (_toReview > 0) ...[
            const AppGap.sm(),
            // Badge de cuarentena (Paso 23): que el agente no las pierda de vista.
            FilledButton.tonalIcon(
              key: const Key('home_review_button'),
              icon: const Icon(AppIcons.review),
              label: Text(l10n.homeReviewPending(_toReview)),
              onPressed: _openReview,
            ),
          ],
          const AppGap.lg(),
          Text(
            l10n.homeOfflineNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const Divider(),
          Text(
            l10n.homeRecentVisits,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const AppGap.sm(),
          TextField(
            key: const Key('home_search'),
            decoration: InputDecoration(
              hintText: l10n.homeSearchHint,
              prefixIcon: const Icon(Icons.search),
            ),
            textInputAction: TextInputAction.search,
            onChanged: _search,
          ),
          if (_visits == null)
            const Center(child: CircularProgressIndicator())
          else ...[
            VisitStatusList(
              visits: _visits!,
              onOpen: _openVisit,
              emptyText: _query.trim().isEmpty ? null : l10n.homeNoResults,
            ),
            // Página llena: puede haber más.
            if (_visits!.length >= _limit)
              TextButton(
                key: const Key('home_load_more'),
                onPressed: _loadMore,
                child: Text(l10n.homeLoadMore),
              ),
          ],
        ],
      ),
    );
  }
}
