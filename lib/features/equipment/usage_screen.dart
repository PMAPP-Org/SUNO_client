// Registro de uso de un equipo (M&E): el operador reporta su jornada con el
// equipo que tiene asignado: proyecto, fecha, hora de inicio y fin, actividad,
// frente de obra y lecturas del medidor. Se valida en el teléfono (incluido el
// cruce con otros usos del equipo) y queda en cola; sale en el siguiente ciclo
// de sincronización y el servidor decide el resto y calcula horas y costo.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/equipment/equipment_manager.dart';
import '../../core/equipment/equipment_models.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import 'equipment_labels.dart';

class UsageScreen extends ConsumerStatefulWidget {
  /// [initialDate] permite abrir el formulario en otro día (por defecto, hoy).
  const UsageScreen({super.key, required this.equipment, this.initialDate});

  final FieldEquipment equipment;
  final DateTime? initialDate;

  @override
  ConsumerState<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends ConsumerState<UsageScreen> {
  final _activity = TextEditingController();
  final _location = TextEditingController();
  final _startMeter = TextEditingController();
  final _endMeter = TextEditingController();
  final _notes = TextEditingController();
  late DateTime _date;
  late int _start;
  late int _end;
  String? _projectId;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final initial = widget.initialDate ?? now;
    _date = DateTime(initial.year, initial.month, initial.day);
    _applyDefaultTimes(now);
    if (widget.equipment.usageProjects.length == 1) _projectId = widget.equipment.usageProjects.first.id;
    // La lectura inicial suele ser la última conocida.
    final unit = widget.equipment.needsMeterForInspection ? widget.equipment.meterUnits.first : null;
    final last = unit == null ? null : widget.equipment.meter(unit)?.value;
    if (last != null) _startMeter.text = formatMeter(last);
  }

  /// Hoy: hasta ahora y cuatro horas atrás; otro día: la jornada de 8:00 a 12:00.
  void _applyDefaultTimes(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    if (_date == today) {
      _end = (now.hour * 60 + now.minute) ~/ 5 * 5;
      _start = _end >= 240 ? _end - 240 : 0;
    } else {
      _start = 8 * 60;
      _end = 12 * 60;
    }
  }

  @override
  void dispose() {
    for (final controller in [_activity, _location, _startMeter, _endMeter, _notes]) {
      controller.dispose();
    }
    super.dispose();
  }

  String _time(int minutes) => MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60), alwaysUse24HourFormat: true);

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now.subtract(const Duration(days: 60)),
      lastDate: now,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _date = DateTime(picked.year, picked.month, picked.day);
      _applyDefaultTimes(now);
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final current = start ? _start : _end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final minutes = picked.hour * 60 + picked.minute;
      if (start) {
        _start = minutes;
      } else {
        _end = minutes;
      }
    });
  }

  double? _number(TextEditingController controller) => double.tryParse(controller.text.trim().replaceAll(',', '.'));

  Future<void> _submit() async {
    final l10n = context.l10n;
    final manager = ref.read(appDependenciesProvider).equipment;
    final needsMeter = widget.equipment.needsMeterForInspection;
    setState(() {
      _saving = true;
      _error = null;
    });
    final outcome = await manager.submitUsageReport(
      equipmentId: widget.equipment.id,
      projectId: _projectId ?? '',
      usageDate: _date,
      startMinutes: _start,
      endMinutes: _end,
      activity: _activity.text,
      location: _location.text,
      startMeter: needsMeter ? _number(_startMeter) : null,
      endMeter: needsMeter ? _number(_endMeter) : null,
      notes: _notes.text,
    );
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _error = switch (outcome.problem!) {
        UsageProblem.projectMissing => l10n.usageProjectMissing,
        UsageProblem.activityRequired => l10n.usageActivityRequired,
        UsageProblem.invalidTimes => l10n.usageInvalidTimes,
        UsageProblem.futureTime => l10n.usageFutureTime,
        UsageProblem.meterRequired => l10n.usageMeterRequired,
        UsageProblem.invalidMeter => l10n.usageInvalidMeter,
        UsageProblem.meterBackwards => l10n.usageMeterBackwards(
          formatMeter(double.tryParse(outcome.detail ?? '') ?? 0),
        ),
        UsageProblem.overlap => l10n.usageOverlap(outcome.detail ?? ''),
        UsageProblem.equipmentNotFound => l10n.equipmentReadingUnavailable,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final equipment = widget.equipment;
    final localizations = MaterialLocalizations.of(context);
    final meter = equipment.needsMeterForInspection ? meterUnitLabel(l10n, equipment.meterUnits.first) : '';
    return Scaffold(
      appBar: AppBar(title: Text(l10n.usageRegister)),
      body: AppPageBody(
        children: [
          Text(l10n.equipmentListTitle(equipment.code, equipment.name), style: theme.textTheme.titleLarge),
          const AppGap.sm(),
          if (equipment.usageProjects.isEmpty)
            Text(l10n.usageNoProject, key: const Key('usage_no_project'))
          else ...[
            DropdownButtonFormField<String>(
              key: const Key('usage_project'),
              initialValue: _projectId,
              decoration: InputDecoration(labelText: l10n.usageProject),
              items: [for (final p in equipment.usageProjects) DropdownMenuItem(value: p.id, child: Text(p.name))],
              onChanged: (id) => setState(() => _projectId = id),
            ),
            const AppGap.sm(),
            AppButton(
              key: const Key('usage_date'),
              label: l10n.usagePickerLabel(l10n.usageDate, localizations.formatShortDate(_date)),
              icon: Icons.calendar_today_outlined,
              secondary: true,
              onPressed: _pickDate,
            ),
            const AppGap.sm(),
            AppButton(
              key: const Key('usage_start'),
              label: l10n.usagePickerLabel(l10n.usageStart, _time(_start)),
              icon: Icons.schedule,
              secondary: true,
              onPressed: () => _pickTime(start: true),
            ),
            const AppGap.sm(),
            AppButton(
              key: const Key('usage_end'),
              label: l10n.usagePickerLabel(l10n.usageEnd, _time(_end)),
              icon: Icons.schedule,
              secondary: true,
              onPressed: () => _pickTime(start: false),
            ),
            const AppGap.sm(),
            TextField(
              key: const Key('usage_activity'),
              controller: _activity,
              decoration: InputDecoration(labelText: l10n.usageActivity),
            ),
            const AppGap.sm(),
            TextField(
              key: const Key('usage_location'),
              controller: _location,
              decoration: InputDecoration(labelText: l10n.usageLocation),
            ),
            if (equipment.needsMeterForInspection) ...[
              const AppGap.sm(),
              TextField(
                key: const Key('usage_start_meter'),
                controller: _startMeter,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: l10n.usageStartMeter(meter)),
              ),
              const AppGap.sm(),
              TextField(
                key: const Key('usage_end_meter'),
                controller: _endMeter,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: l10n.usageEndMeter(meter)),
              ),
            ],
            const AppGap.sm(),
            TextField(
              key: const Key('usage_notes'),
              controller: _notes,
              decoration: InputDecoration(labelText: l10n.usageNotes),
            ),
            if (_error != null) ...[
              const AppGap.sm(),
              Text(
                _error!,
                key: const Key('usage_error'),
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const AppGap.lg(),
            AppButton(
              key: const Key('usage_submit'),
              label: l10n.usageSave,
              isLoading: _saving,
              onPressed: _saving ? null : _submit,
            ),
          ],
        ],
      ),
    );
  }
}
