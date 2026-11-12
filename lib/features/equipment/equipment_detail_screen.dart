// Ficha de un equipo en campo (Maquinaria y equipos, fase 1): datos, última
// lectura de cada medidor, alertas de vigencia, documentos y campos
// adicionales, todo desde la caché del teléfono. Desde aquí se registra una
// lectura de medidor, que queda en cola y sale en el siguiente ciclo.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/equipment/equipment_manager.dart';
import '../../core/equipment/equipment_models.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import 'equipment_labels.dart';
import 'fuel_fill_screen.dart';
import 'inspection_screen.dart';
import 'usage_screen.dart';

class EquipmentDetailScreen extends ConsumerStatefulWidget {
  const EquipmentDetailScreen({super.key, required this.equipmentId});

  final String equipmentId;

  @override
  ConsumerState<EquipmentDetailScreen> createState() => _EquipmentDetailScreenState();
}

class _EquipmentDetailScreenState extends ConsumerState<EquipmentDetailScreen> {
  FieldEquipment? _equipment;
  List<PendingMeterReading> _pending = const [];
  List<PendingInspection> _pendingInspections = const [];
  List<PendingFuelFill> _pendingFuel = const [];
  List<PendingUsageReport> _pendingUsage = const [];
  bool _loaded = false;
  bool _downloadingSheet = false;

  EquipmentManager get _manager => ref.read(appDependenciesProvider).equipment;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final equipment = await _manager.byId(widget.equipmentId);
    final pending = await _manager.pendingFor(widget.equipmentId);
    final pendingInspections = await _manager.pendingInspectionsFor(widget.equipmentId);
    final pendingFuel = await _manager.pendingFuelFillsFor(widget.equipmentId);
    final pendingUsage = await _manager.pendingUsageFor(widget.equipmentId);
    if (!mounted) return;
    setState(() {
      _equipment = equipment;
      _pending = pending;
      _pendingInspections = pendingInspections;
      _pendingFuel = pendingFuel;
      _pendingUsage = pendingUsage;
      _loaded = true;
    });
  }

  Future<void> _recordReading(FieldEquipment equipment) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReadingSheet(equipment: equipment, manager: _manager),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.equipmentReadingQueued)));
      await _load();
    }
  }

  Future<void> _shareLifeSheet(FieldEquipment equipment, Rect? origin) async {
    final l10n = context.l10n;
    setState(() => _downloadingSheet = true);
    try {
      final bytes = await _manager.lifeSheet(equipment.id);
      if (!mounted) return;
      if (bytes == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.equipmentLifeSheetFailed)));
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile.fromData(bytes, mimeType: 'application/pdf')],
          fileNameOverrides: ['hoja-de-vida-${equipment.code}.pdf'],
          sharePositionOrigin: origin,
        ),
      );
    } finally {
      if (mounted) setState(() => _downloadingSheet = false);
    }
  }

  Future<void> _registerUsage(FieldEquipment equipment) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => UsageScreen(equipment: equipment)),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.usageQueued)));
      await _load();
    }
  }

  Future<void> _registerFuel(FieldEquipment equipment) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => FuelFillScreen(equipment: equipment)),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.equipmentFuelQueued)));
      await _load();
    }
  }

  Future<void> _startInspection(FieldEquipment equipment) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => InspectionScreen(equipment: equipment)),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.equipmentPreoperationalQueued)));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final equipment = _equipment;
    if (!_loaded) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    if (equipment == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.equipmentTitle)),
        body: AppPageBody(children: [Text(l10n.equipmentScanNotFound)]),
      );
    }
    final theme = Theme.of(context);
    final colors = context.statusColors;
    final localizations = MaterialLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(equipment.code)),
      body: AppPageBody(
        children: [
          Text(equipment.name, style: theme.textTheme.headlineSmall),
          const AppGap.sm(),
          Text(
            '${equipment.typeName} · ${equipmentStatusLabel(l10n, equipment.status)}',
            key: const Key('equipment_summary'),
            style: theme.textTheme.bodyMedium,
          ),
          const AppGap.sm(),
          if (equipment.checklist.isEmpty)
            Text(l10n.equipmentPreoperationalNoChecklist, key: const Key('equipment_no_checklist'))
          else
            AppButton(
              key: const Key('equipment_start_inspection'),
              label: l10n.equipmentPreoperationalStart,
              icon: Icons.fact_check_outlined,
              onPressed: () => _startInspection(equipment),
            ),
          const AppGap.sm(),
          AppButton(
            key: const Key('equipment_register_usage'),
            label: l10n.usageRegister,
            icon: Icons.timer_outlined,
            onPressed: () => _registerUsage(equipment),
          ),
          const AppGap.sm(),
          AppButton(
            key: const Key('equipment_register_fuel'),
            label: l10n.equipmentFuelRegister,
            icon: Icons.local_gas_station_outlined,
            secondary: true,
            onPressed: () => _registerFuel(equipment),
          ),
          const AppGap.sm(),
          Builder(
            builder: (buttonContext) => AppButton(
              key: const Key('equipment_life_sheet'),
              label: l10n.equipmentLifeSheet,
              icon: Icons.description_outlined,
              secondary: true,
              isLoading: _downloadingSheet,
              onPressed: _downloadingSheet
                  ? null
                  : () {
                      final box = buttonContext.findRenderObject() as RenderBox?;
                      final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
                      _shareLifeSheet(equipment, origin);
                    },
            ),
          ),
          const AppGap.lg(),
          _Section(l10n.equipmentSectionAlerts),
          if (equipment.alerts.isEmpty)
            Text(l10n.equipmentNoAlerts)
          else
            for (final alert in equipment.alerts)
              ListTile(
                key: ValueKey('alert-${alert.name}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  alert.expired ? Icons.error_outline : Icons.warning_amber_outlined,
                  color: alert.expired ? theme.colorScheme.error : colors.warning,
                ),
                title: Text(
                  alert.expired
                      ? l10n.equipmentAlertExpired(alert.name, alert.expiresOn)
                      : l10n.equipmentAlertDue(alert.name, alert.expiresOn, alert.daysLeft),
                ),
              ),
          const AppGap.lg(),
          _Section(l10n.equipmentSectionMeters),
          if (equipment.meterUnits.isEmpty)
            Text(l10n.equipmentNoReadings)
          else
            for (final unit in equipment.meterUnits)
              ListTile(
                key: ValueKey('meter-${unit.name}'),
                contentPadding: EdgeInsets.zero,
                title: Text(meterUnitLabel(l10n, unit)),
                subtitle: Text(
                  equipment.meter(unit) == null
                      ? l10n.equipmentNoReadings
                      : l10n.equipmentMeterReadAt(equipment.meter(unit)!.readAt.toLocal()),
                ),
                trailing: Text(
                  equipment.meter(unit) == null ? '—' : formatMeter(equipment.meter(unit)!.value),
                  style: theme.textTheme.titleMedium,
                ),
              ),
          if (equipment.meterUnits.isNotEmpty) ...[
            const AppGap.sm(),
            AppButton(
              key: const Key('equipment_record_reading'),
              label: l10n.equipmentRecordReading,
              icon: Icons.speed_outlined,
              onPressed: () => _recordReading(equipment),
            ),
          ],
          if (_pending.isNotEmpty) ...[
            const AppGap.lg(),
            _Section(l10n.equipmentPendingReadings),
            for (final reading in _pending)
              ListTile(
                key: ValueKey('pending-${reading.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  reading.rejected ? Icons.error_outline : Icons.schedule,
                  color: reading.rejected ? theme.colorScheme.error : colors.warning,
                ),
                title: Text(l10n.equipmentReadingLine(meterUnitLabel(l10n, reading.unit), formatMeter(reading.value))),
                subtitle: Text(
                  [
                    localizations.formatShortDate(reading.readAt.toLocal()),
                    if (reading.rejected) l10n.equipmentReadingRejected else l10n.equipmentReadingPending,
                    if (reading.rejected && reading.lastError != null) reading.lastError!,
                  ].join(' · '),
                ),
                trailing: reading.rejected
                    ? TextButton(
                        onPressed: () async {
                          await _manager.dismissRejected(reading.id);
                          await _load();
                        },
                        child: Text(l10n.equipmentReadingDismiss),
                      )
                    : null,
              ),
          ],
          const AppGap.lg(),
          _Section(l10n.equipmentSectionMaintenance),
          if (equipment.maintenancePlans.isEmpty)
            Text(l10n.equipmentNoPlans, key: const Key('equipment_no_plans'))
          else
            for (final plan in equipment.maintenancePlans)
              ListTile(
                key: ValueKey('plan-${plan.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  switch (plan.state) {
                    PlanState.ok => Icons.check_circle_outline,
                    PlanState.dueSoon => Icons.warning_amber_outlined,
                    PlanState.overdue => Icons.error_outline,
                    PlanState.unknown => Icons.help_outline,
                  },
                  color: switch (plan.state) {
                    PlanState.ok => colors.success,
                    PlanState.dueSoon => colors.warning,
                    PlanState.overdue => theme.colorScheme.error,
                    PlanState.unknown => null,
                  },
                ),
                title: Text(plan.name),
                subtitle: Text(
                  [
                    planRemainingLabel(l10n, plan),
                    if (plan.hasOpenOrder) l10n.equipmentPlanWithOrder,
                  ].join(' · '),
                ),
              ),
          if (equipment.openWorkOrders.isNotEmpty) ...[
            const AppGap.sm(),
            _Section(l10n.equipmentSectionOrders),
            for (final order in equipment.openWorkOrders)
              ListTile(
                key: ValueKey('order-${order.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.build_outlined),
                title: Text(l10n.equipmentOrderLine(order.code, workOrderKindLabel(l10n, order.kind))),
                subtitle: Text([workOrderStatusLabel(l10n, order.status), order.description].join(' · ')),
              ),
          ],
          if (_pendingUsage.isNotEmpty || equipment.recentUsage.isNotEmpty) ...[
            const AppGap.lg(),
            _Section(l10n.usageMine),
            for (final pending in _pendingUsage)
              ListTile(
                key: ValueKey('pending-usage-${pending.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  pending.rejected ? Icons.error_outline : Icons.schedule,
                  color: pending.rejected ? theme.colorScheme.error : colors.warning,
                ),
                title: Text(pending.activity),
                subtitle: Text(
                  [
                    l10n.usageLine(
                      localizations.formatShortDate(pending.usageDate),
                      _clock(pending.startMinutes),
                      _clock(pending.endMinutes),
                    ),
                    if (pending.rejected) l10n.equipmentReadingRejected else l10n.equipmentReadingPending,
                    if (pending.rejected && pending.lastError != null) pending.lastError!,
                  ].join(' · '),
                ),
                trailing: pending.rejected
                    ? TextButton(
                        onPressed: () async {
                          await _manager.dismissRejectedUsage(pending.id);
                          await _load();
                        },
                        child: Text(l10n.equipmentReadingDismiss),
                      )
                    : null,
              ),
            for (final usage in equipment.recentUsage)
              ListTile(
                key: ValueKey('usage-${usage.id}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timer_outlined),
                title: Text(usage.activity),
                subtitle: Text(
                  [
                    l10n.usageLine(
                      localizations.formatShortDate(usage.usageDate),
                      _clock(usage.startMinutes),
                      _clock(usage.endMinutes),
                    ),
                    usage.projectName,
                    if (usage.hours != null) l10n.usageHours(formatMeter(usage.hours!)),
                  ].join(' · '),
                ),
              ),
          ],
          if (_pendingFuel.isNotEmpty) ...[
            const AppGap.lg(),
            _Section(l10n.equipmentFuelPending),
            for (final fill in _pendingFuel)
              ListTile(
                key: ValueKey('pending-fuel-${fill.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  fill.rejected ? Icons.error_outline : Icons.schedule,
                  color: fill.rejected ? theme.colorScheme.error : colors.warning,
                ),
                title: Text(l10n.equipmentFuelPendingLine(fill.voucherNumber, formatMeter(fill.gallons))),
                subtitle: Text(
                  [
                    localizations.formatShortDate(fill.filledAt.toLocal()),
                    if (fill.rejected) l10n.equipmentReadingRejected else l10n.equipmentReadingPending,
                    if (fill.rejected && fill.lastError != null) fill.lastError!,
                  ].join(' · '),
                ),
                trailing: fill.rejected
                    ? TextButton(
                        onPressed: () async {
                          await _manager.dismissRejectedFuelFill(fill.id);
                          await _load();
                        },
                        child: Text(l10n.equipmentReadingDismiss),
                      )
                    : null,
              ),
          ],
          if (_pendingInspections.isNotEmpty || equipment.recentInspections.isNotEmpty) ...[
            const AppGap.lg(),
            _Section(l10n.equipmentInspectionsTitle),
            for (final pending in _pendingInspections)
              ListTile(
                key: ValueKey('pending-inspection-${pending.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  pending.rejected ? Icons.error_outline : Icons.schedule,
                  color: pending.rejected ? theme.colorScheme.error : colors.warning,
                ),
                title: Text(pending.rejected ? l10n.equipmentInspectionNotSent : l10n.equipmentInspectionSending),
                subtitle: Text(
                  [
                    localizations.formatShortDate(pending.capturedAt.toLocal()),
                    if (pending.hasFaults) l10n.equipmentInspectionWithFaults,
                    if (pending.rejected && pending.lastError != null) pending.lastError!,
                  ].join(' · '),
                ),
                trailing: pending.rejected
                    ? TextButton(
                        onPressed: () async {
                          await _manager.dismissRejectedInspection(pending.id);
                          await _load();
                        },
                        child: Text(l10n.equipmentReadingDismiss),
                      )
                    : null,
              ),
            for (final summary in equipment.recentInspections)
              ListTile(
                key: ValueKey('inspection-${summary.id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  switch (summary.status) {
                    InspectionStatus.approved => Icons.check_circle_outline,
                    InspectionStatus.submitted => Icons.hourglass_empty,
                    _ => Icons.report_problem_outlined,
                  },
                  color: switch (summary.status) {
                    InspectionStatus.approved => colors.success,
                    InspectionStatus.submitted => null,
                    _ => theme.colorScheme.error,
                  },
                ),
                title: Text(inspectionStatusLabel(l10n, summary.status)),
                subtitle: Text(
                  [
                    localizations.formatShortDate(summary.capturedAt.toLocal()),
                    if (summary.hasFaults) l10n.equipmentInspectionWithFaults,
                    if (summary.reviewComment.isNotEmpty) summary.reviewComment,
                  ].join(' · '),
                ),
              ),
          ],
          const AppGap.lg(),
          _Section(l10n.equipmentSectionDetails),
          _Detail(l10n.equipmentFieldPlate, equipment.licensePlate),
          _Detail(l10n.equipmentFieldSerial, equipment.serialNumber),
          _Detail(l10n.equipmentFieldMake, equipment.manufacturer),
          _Detail(l10n.equipmentFieldModel, equipment.model),
          _Detail(l10n.equipmentFieldDepartment, equipment.departmentLabel ?? ''),
          const AppGap.lg(),
          _Section(l10n.equipmentSectionDocuments),
          if (equipment.documents.isEmpty)
            Text(l10n.equipmentNoDocuments)
          else
            for (final document in equipment.documents)
              ListTile(
                key: ValueKey('document-${document.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text(document.name),
                subtitle: Text(
                  document.expiresOn == null
                      ? l10n.equipmentDocumentNoExpiry
                      : l10n.equipmentDocumentExpires(document.expiresOn!),
                ),
              ),
          if (equipment.fields.isNotEmpty) ...[
            const AppGap.lg(),
            _Section(l10n.equipmentSectionFields),
            for (final field in equipment.fields) _Detail(field.name, _fieldText(field)),
          ],
        ],
      ),
    );
  }

  String _clock(int minutes) => MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60), alwaysUse24HourFormat: true);

  String _fieldText(EquipmentFieldInfo field) {
    final value = field.value;
    if (value == null) return '';
    if (field.type == 'date' && value is String) {
      final date = DateTime.tryParse(value);
      if (date != null) return MaterialLocalizations.of(context).formatShortDate(date);
    }
    return value is num ? formatMeter(value.toDouble()) : value.toString();
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
    child: Text(title, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _Detail extends StatelessWidget {
  const _Detail(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label, style: Theme.of(context).textTheme.labelMedium),
      subtitle: Text(value, style: Theme.of(context).textTheme.bodyLarge),
    );
  }
}

class _ReadingSheet extends StatefulWidget {
  const _ReadingSheet({required this.equipment, required this.manager});

  final FieldEquipment equipment;
  final EquipmentManager manager;

  @override
  State<_ReadingSheet> createState() => _ReadingSheetState();
}

class _ReadingSheetState extends State<_ReadingSheet> {
  late MeterUnit _unit = widget.equipment.meterUnits.first;
  final _value = TextEditingController();
  final _notes = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _value.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    final parsed = double.tryParse(_value.text.trim().replaceAll(',', '.'));
    if (parsed == null) {
      setState(() => _error = l10n.equipmentReadingInvalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final outcome = await widget.manager.recordReading(
      equipmentId: widget.equipment.id,
      unit: _unit,
      value: parsed,
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
        ReadingProblem.backwards => l10n.equipmentReadingBackwards(formatMeter(outcome.baseline ?? 0)),
        ReadingProblem.invalidValue => l10n.equipmentReadingInvalid,
        ReadingProblem.equipmentNotFound || ReadingProblem.unitNotConfigured => l10n.equipmentReadingUnavailable,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.equipmentRecordReading, style: Theme.of(context).textTheme.titleLarge),
            const AppGap.sm(),
            if (widget.equipment.meterUnits.length > 1)
              DropdownButtonFormField<MeterUnit>(
                key: const Key('reading_unit'),
                initialValue: _unit,
                decoration: InputDecoration(labelText: l10n.equipmentReadingMeter),
                items: [
                  for (final unit in widget.equipment.meterUnits)
                    DropdownMenuItem(value: unit, child: Text(meterUnitLabel(l10n, unit))),
                ],
                onChanged: (unit) => setState(() => _unit = unit ?? _unit),
              )
            else
              Text(meterUnitLabel(l10n, _unit), style: Theme.of(context).textTheme.titleMedium),
            const AppGap.sm(),
            TextField(
              key: const Key('reading_value'),
              controller: _value,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: l10n.equipmentReadingValue, errorText: _error),
            ),
            const AppGap.sm(),
            TextField(
              key: const Key('reading_notes'),
              controller: _notes,
              decoration: InputDecoration(labelText: l10n.equipmentReadingNotes),
            ),
            const AppGap.lg(),
            AppButton(
              key: const Key('reading_save'),
              label: l10n.equipmentReadingSave,
              isLoading: _saving,
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}
