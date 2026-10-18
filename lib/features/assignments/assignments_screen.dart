// "Mis asignaciones" (Fase B): el trabajo planificado del agente, primero lo
// pendiente. Tocar una pendiente abre la captura con su plantilla y su punto;
// tocar una hecha abre la visita que la cumplió.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/providers.dart';
import '../../data/local/assignment_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/app_page_body.dart';
import '../capture/capture_screen.dart';
import '../visits/visit_detail_screen.dart';

class AssignmentsScreen extends ConsumerStatefulWidget {
  const AssignmentsScreen({super.key});

  @override
  ConsumerState<AssignmentsScreen> createState() => _AssignmentsScreenState();
}

class _AssignmentsScreenState extends ConsumerState<AssignmentsScreen> {
  List<AssignmentItem>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dependencies = ref.read(appDependenciesProvider);
    final auth = dependencies.authController.state;
    if (auth is! Authenticated) return;
    final items = await dependencies.assignments.forUser(orgId: auth.user.orgId, userId: auth.user.id);
    if (mounted) setState(() => _items = items);
  }

  Future<void> _open(AssignmentItem item) async {
    final visitId = item.visitId;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => visitId != null ? VisitDetailScreen(visitId: visitId) : CaptureScreen(assignmentId: item.id),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _items;
    final localizations = MaterialLocalizations.of(context);
    final colors = context.statusColors;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.assignmentsTitle)),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : AppPageBody(
              children: [
                if (items.isEmpty) Text(l10n.assignmentsEmpty, key: const Key('assignments_empty')),
                for (final item in items)
                  ListTile(
                    key: ValueKey('assignment-${item.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      item.done ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: item.done ? colors.success : null,
                    ),
                    title: Text(item.title ?? item.templateName ?? l10n.homeVisitUntitled),
                    subtitle: Text(
                      [
                        if (item.title != null && item.templateName != null) item.templateName!,
                        if (item.scheduledFor != null) localizations.formatShortDate(item.scheduledFor!.toLocal()),
                        if (item.hasPoint) l10n.assignmentHasPoint,
                        item.done ? l10n.assignmentDone : l10n.assignmentPending,
                      ].join(' · '),
                    ),
                    onTap: () => _open(item),
                  ),
              ],
            ),
    );
  }
}
