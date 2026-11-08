// Textos de dominio de la pantalla de equipos: estado y medidores. Los valores
// del servidor (`status`, `unit`) se traducen aquí, no en cada widget.
import '../../core/equipment/equipment_models.dart';
import '../../l10n/l10n.dart';

String equipmentStatusLabel(AppLocalizations l10n, String status) => switch (status) {
  'available' => l10n.equipmentStatusAvailable,
  'assigned' => l10n.equipmentStatusAssigned,
  'maintenance' => l10n.equipmentStatusMaintenance,
  'out_of_service' => l10n.equipmentStatusOutOfService,
  'retired' => l10n.equipmentStatusRetired,
  // Un estado nuevo del servidor no rompe la pantalla: se muestra tal cual.
  _ => status,
};

String meterUnitLabel(AppLocalizations l10n, MeterUnit unit) => switch (unit) {
  MeterUnit.hours => l10n.equipmentMeterHours,
  MeterUnit.kilometers => l10n.equipmentMeterKilometers,
};

/// Número de medidor sin ceros sobrantes: 339 → "339", 345.5 → "345.5".
String formatMeter(double value) => value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

String inspectionStatusLabel(AppLocalizations l10n, InspectionStatus status) => switch (status) {
  InspectionStatus.submitted => l10n.equipmentInspectionSubmitted,
  InspectionStatus.approved => l10n.equipmentInspectionApproved,
  InspectionStatus.rejected => l10n.equipmentInspectionRejected,
  InspectionStatus.correctionRequested => l10n.equipmentInspectionCorrection,
};

String meterUnitShort(AppLocalizations l10n, MeterUnit unit) => switch (unit) {
  MeterUnit.hours => l10n.equipmentMeterShortHours,
  MeterUnit.kilometers => l10n.equipmentMeterShortKilometers,
};

String planStateLabel(AppLocalizations l10n, PlanState state) => switch (state) {
  PlanState.ok => l10n.equipmentPlanOk,
  PlanState.dueSoon => l10n.equipmentPlanDueSoon,
  PlanState.overdue => l10n.equipmentPlanOverdue,
  PlanState.unknown => l10n.equipmentPlanUnknown,
};

/// "Faltan 30 h" / "Vencido hace 150 km" / "Faltan 12 días", según el plan.
String planRemainingLabel(AppLocalizations l10n, MaintenancePlanInfo plan) {
  final remaining = plan.remaining;
  if (remaining == null) return planStateLabel(l10n, plan.state);
  final past = remaining < 0;
  final amount = remaining.abs();
  if (plan.byMeter) {
    final unit = plan.meterUnit == null ? '' : meterUnitShort(l10n, plan.meterUnit!);
    return past
        ? l10n.equipmentPlanPastDue(formatMeter(amount), unit)
        : l10n.equipmentPlanRemaining(formatMeter(amount), unit);
  }
  return past ? l10n.equipmentPlanPastDueDays(amount.round()) : l10n.equipmentPlanRemainingDays(amount.round());
}

String workOrderKindLabel(AppLocalizations l10n, String kind) => switch (kind) {
  'preventive' => l10n.equipmentOrderPreventive,
  'corrective' => l10n.equipmentOrderCorrective,
  'overhaul' => l10n.equipmentOrderOverhaul,
  _ => kind,
};

String workOrderStatusLabel(AppLocalizations l10n, String status) => switch (status) {
  'draft' => l10n.equipmentOrderDraft,
  'approved' => l10n.equipmentOrderApproved,
  'in_execution' => l10n.equipmentOrderInExecution,
  _ => status,
};
