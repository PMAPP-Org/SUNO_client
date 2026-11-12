// Avance de campo (costos, etapa 1): en la captura, "Tarea del cronograma"
// (opcional, búsqueda por EDT o nombre) y "% avance acumulado" con el último
// validado como referencia. Un % menor se acepta pero se avisa: la supervisión
// lo verá marcado. Todo local: las tareas vienen de la BD del teléfono. En una tarea
// medida por cantidades, la sección de cantidades (costos, pieza 4b) en lugar del %.
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
    this.tasksLoaded = true,
    this.quantities,
    this.locked = false,
  });

  final List<ScheduleTaskItem> tasks;

  /// La tarea elegida; puede no estar en [tasks] al editar un registro cuya
  /// tarea ya no está en la lista del agente.
  final String? selectedId;
  final TextEditingController controller;
  final ValueChanged<String?> onSelected;
  final String? errorText;

  /// Mientras las tareas se leen de la BD no se puede decir que la elegida
  /// "ya no está en tu lista".
  final bool tasksLoaded;

  /// Costos, pieza 4b: la captura de cantidades, en lugar del %, cuando la tarea elegida
  /// se mide por cantidades.
  final Widget? quantities;

  /// La tarea no se puede cambiar (registro ya validado).
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final selected = tasks.where((t) => t.id == selectedId).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.captureTaskSection, style: theme.textTheme.titleSmall),
        Semantics(
          label: l10n.captureTaskLabel,
          button: true,
          child: ListTile(
            key: const Key('capture_task_picker'),
            enabled: !locked,
            contentPadding: EdgeInsets.zero,
            title: Text(
              selectedId == null
                  ? l10n.captureTaskNone
                  : selected?.label ?? (tasksLoaded ? l10n.captureTaskUnavailable : ''),
            ),
            subtitle: selected == null ? null : Text(selected.projectName),
            trailing: const Icon(Icons.arrow_drop_down),
            onTap: locked
                ? null
                : () async {
                    final pick = await showTaskPicker(context, tasks, selectedId: selectedId);
                    if (pick != null) onSelected(pick.task?.id);
                  },
          ),
        ),
        if (selectedId != null)
          quantities ??
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

Future<TaskPick?> showTaskPicker(BuildContext context, List<ScheduleTaskItem> tasks, {String? selectedId}) =>
    showModalBottomSheet<TaskPick>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _TaskPickerSheet(tasks: tasks, selectedId: selectedId),
    );

class _TaskPickerSheet extends StatefulWidget {
  const _TaskPickerSheet({required this.tasks, required this.selectedId});

  final List<ScheduleTaskItem> tasks;
  final String? selectedId;

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
                    ? Center(
                        child: Text(
                          widget.tasks.isEmpty && _query.trim().isEmpty
                              ? l10n.taskPickerNoneAssigned
                              : l10n.taskPickerEmpty,
                        ),
                      )
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final task = visible[index];
                          final pct = task.lastValidatedPct;
                          return ListTile(
                            key: ValueKey('task_picker_item-${task.id}'),
                            selected: task.id == widget.selectedId,
                            trailing: task.id == widget.selectedId ? const Icon(Icons.check) : null,
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
