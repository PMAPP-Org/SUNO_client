// Avance de campo (costos, etapa 1): en la captura, "Tarea del cronograma"
// (opcional, búsqueda por EDT o nombre) y "% avance acumulado" con el último
// validado como referencia. Un % menor se acepta pero se avisa: la supervisión
// lo verá marcado. Todo local: las tareas vienen de la BD del teléfono.
import 'package:flutter/material.dart';

import '../../core/schedule/progress_input.dart';
import '../../data/local/schedule_task_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_tokens.dart';

class TaskProgressSection extends StatelessWidget {
  const TaskProgressSection({
    super.key,
    required this.tasks,
    required this.selectedId,
    required this.controller,
    required this.onSelected,
    this.errorText,
  });

  final List<ScheduleTaskItem> tasks;

  /// La tarea elegida; puede no estar en [tasks] al editar una visita cuya
  /// tarea ya no está en la lista del agente.
  final String? selectedId;
  final TextEditingController controller;
  final ValueChanged<String?> onSelected;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final selected = tasks.where((t) => t.id == selectedId).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.captureTaskSection, style: theme.textTheme.titleSmall),
        ListTile(
          key: const Key('capture_task_picker'),
          contentPadding: EdgeInsets.zero,
          title: Text(
            selectedId == null ? l10n.captureTaskNone : selected?.label ?? l10n.captureTaskUnavailable,
          ),
          subtitle: selected == null ? null : Text(selected.projectName),
          trailing: const Icon(Icons.arrow_drop_down),
          onTap: () async {
            final pick = await showTaskPicker(context, tasks);
            if (pick != null) onSelected(pick.task?.id);
          },
        ),
        if (selectedId != null)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final reference = selected?.lastValidatedPct;
              final pct = parseProgressPct(value.text);
              final below = reference != null && pct != null && pct < reference;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('capture_progress_field'),
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: l10n.captureProgressLabel,
                      suffixText: l10n.captureProgressSuffix,
                      errorText: errorText,
                      helperText: reference == null
                          ? l10n.captureProgressNoReference
                          : l10n.captureProgressReference(formatProgressPct(reference)),
                    ),
                  ),
                  if (below)
                    Text(
                      l10n.captureProgressBelowValidated(formatProgressPct(reference)),
                      key: const Key('capture_progress_below'),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }
}

/// Lo elegido en el selector: `task` nula = "Sin tarea". El `Future` da
/// `null` si se cerró sin elegir.
typedef TaskPick = ({ScheduleTaskItem? task});

Future<TaskPick?> showTaskPicker(BuildContext context, List<ScheduleTaskItem> tasks) =>
    showModalBottomSheet<TaskPick>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TaskPickerSheet(tasks: tasks),
    );

class _TaskPickerSheet extends StatefulWidget {
  const _TaskPickerSheet({required this.tasks});

  final List<ScheduleTaskItem> tasks;

  @override
  State<_TaskPickerSheet> createState() => _TaskPickerSheetState();
}

class _TaskPickerSheetState extends State<_TaskPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final visible = searchScheduleTasks(widget.tasks, _query);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.8,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: TextField(
                  key: const Key('task_picker_search'),
                  autofocus: true,
                  decoration: InputDecoration(labelText: l10n.taskPickerSearch, prefixIcon: const Icon(Icons.search)),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              ListTile(
                key: const Key('task_picker_none'),
                title: Text(l10n.taskPickerNone),
                onTap: () => Navigator.of(context).pop<TaskPick>((task: null)),
              ),
              const Divider(),
              Expanded(
                child: visible.isEmpty
                    ? Center(child: Text(l10n.taskPickerEmpty))
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final task = visible[index];
                          final pct = task.lastValidatedPct;
                          return ListTile(
                            key: ValueKey('task_picker_item-${task.id}'),
                            title: Text(task.label),
                            subtitle: Text(
                              pct == null
                                  ? task.projectName
                                  : l10n.taskPickerSubtitle(task.projectName, formatProgressPct(pct)),
                            ),
                            onTap: () => Navigator.of(context).pop<TaskPick>((task: task)),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
