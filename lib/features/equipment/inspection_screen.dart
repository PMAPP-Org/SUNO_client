// Preoperacional de un equipo (M&E fase 2): lectura inicial del medidor, una
// respuesta por cada ítem de la lista de chequeo y la descripción de cada
// novedad. Se valida en el teléfono y queda en cola; sale en el siguiente
// ciclo de sincronización y el servidor lo valida de nuevo (todo o nada).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/equipment/equipment_manager.dart';
import '../../core/equipment/equipment_models.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import 'equipment_labels.dart';

class InspectionScreen extends ConsumerStatefulWidget {
  const InspectionScreen({super.key, required this.equipment});

  final FieldEquipment equipment;

  @override
  ConsumerState<InspectionScreen> createState() => _InspectionScreenState();
}

class _InspectionScreenState extends ConsumerState<InspectionScreen> {
  final _meter = TextEditingController();
  final _notes = TextEditingController();
  late final Map<String, bool?> _ok = {for (final item in widget.equipment.checklist) item.id: null};
  late final Map<String, TextEditingController> _faultNotes = {
    for (final item in widget.equipment.checklist) item.id: TextEditingController(),
  };
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _meter.dispose();
    _notes.dispose();
    for (final controller in _faultNotes.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    final manager = ref.read(appDependenciesProvider).equipment;
    final needsMeter = widget.equipment.needsMeterForInspection;
    final meter = needsMeter ? double.tryParse(_meter.text.trim().replaceAll(',', '.')) : null;
    setState(() {
      _saving = true;
      _error = null;
    });
    final outcome = await manager.submitInspection(
      equipmentId: widget.equipment.id,
      meterValue: meter,
      notes: _notes.text,
      answers: [
        for (final item in widget.equipment.checklist)
          if (_ok[item.id] != null)
            InspectionAnswer(itemId: item.id, ok: _ok[item.id]!, note: _faultNotes[item.id]!.text),
      ],
    );
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _error = switch (outcome.problem!) {
        InspectionProblem.incomplete => l10n.equipmentPreoperationalIncomplete(outcome.detail ?? ''),
        InspectionProblem.faultWithoutNote => l10n.equipmentPreoperationalFaultNeedsNote(outcome.detail ?? ''),
        InspectionProblem.meterRequired || InspectionProblem.invalidMeter => l10n.equipmentPreoperationalMeterRequired,
        InspectionProblem.meterBackwards => l10n.equipmentPreoperationalMeterBackwards(
          formatMeter(double.tryParse(outcome.detail ?? '') ?? 0),
        ),
        InspectionProblem.noChecklist => l10n.equipmentPreoperationalNoChecklist,
        InspectionProblem.equipmentNotFound => l10n.equipmentReadingUnavailable,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final equipment = widget.equipment;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.equipmentPreoperational)),
      body: AppPageBody(
        children: [
          Text(l10n.equipmentListTitle(equipment.code, equipment.name), style: theme.textTheme.titleLarge),
          const AppGap.sm(),
          if (equipment.needsMeterForInspection) ...[
            TextField(
              key: const Key('inspection_meter'),
              controller: _meter,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: l10n.equipmentPreoperationalMeter(meterUnitLabel(l10n, equipment.meterUnits.first)),
              ),
            ),
            const AppGap.sm(),
          ],
          for (final item in equipment.checklist) ...[
            Text(
              item.critical ? '${item.label} · ${l10n.equipmentPreoperationalCritical}' : item.label,
              style: theme.textTheme.titleSmall,
            ),
            SegmentedButton<bool>(
              key: ValueKey('inspection-item-${item.id}'),
              emptySelectionAllowed: true,
              segments: [
                ButtonSegment(value: true, label: Text(l10n.equipmentPreoperationalItemOk)),
                ButtonSegment(value: false, label: Text(l10n.equipmentPreoperationalItemFault)),
              ],
              selected: {if (_ok[item.id] != null) _ok[item.id]!},
              onSelectionChanged: (selection) => setState(() => _ok[item.id] = selection.isEmpty ? null : selection.first),
            ),
            if (_ok[item.id] == false)
              TextField(
                key: ValueKey('inspection-note-${item.id}'),
                controller: _faultNotes[item.id],
                decoration: InputDecoration(labelText: l10n.equipmentPreoperationalFaultNote),
              ),
            const AppGap.sm(),
          ],
          TextField(
            key: const Key('inspection_notes'),
            controller: _notes,
            decoration: InputDecoration(labelText: l10n.equipmentPreoperationalNotes),
          ),
          if (_error != null) ...[
            const AppGap.sm(),
            Text(
              _error!,
              key: const Key('inspection_error'),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
            ),
          ],
          const AppGap.lg(),
          AppButton(
            key: const Key('inspection_submit'),
            label: l10n.equipmentPreoperationalSubmit,
            isLoading: _saving,
            onPressed: _saving ? null : _submit,
          ),
        ],
      ),
    );
  }
}
