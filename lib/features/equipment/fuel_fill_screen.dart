// Tanqueo de un equipo (M&E fase 4): origen (estación o tanque propio), vale,
// galones, lectura del medidor, frente de obra y conductor. Se valida en el
// teléfono y queda en cola; sale en el siguiente ciclo de sincronización y el
// servidor decide (vale repetido, stock del tanque, medidor que retrocede).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/equipment/equipment_manager.dart';
import '../../core/equipment/equipment_models.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import 'equipment_labels.dart';

class FuelFillScreen extends ConsumerStatefulWidget {
  const FuelFillScreen({super.key, required this.equipment});

  final FieldEquipment equipment;

  @override
  ConsumerState<FuelFillScreen> createState() => _FuelFillScreenState();
}

class _FuelFillScreenState extends ConsumerState<FuelFillScreen> {
  final _voucher = TextEditingController();
  final _gallons = TextEditingController();
  final _meter = TextEditingController();
  final _front = TextEditingController();
  final _driver = TextEditingController();
  final _document = TextEditingController();
  final _notes = TextEditingController();
  FuelCatalogInfo? _catalog;
  FuelSource _source = FuelSource.station;
  String? _stationId;
  String? _storeId;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    for (final controller in [_voucher, _gallons, _meter, _front, _driver, _document, _notes]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    final catalog = await ref.read(appDependenciesProvider).equipment.fuelCatalog();
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      // Con una sola opción, ya viene elegida.
      if (catalog.stations.length == 1) _stationId = catalog.stations.first.id;
      if (catalog.stores.length == 1) _storeId = catalog.stores.first.id;
      if (catalog.stations.isEmpty && catalog.stores.isNotEmpty) _source = FuelSource.store;
    });
  }

  double? _number(TextEditingController controller) => double.tryParse(controller.text.trim().replaceAll(',', '.'));

  Future<void> _submit() async {
    final l10n = context.l10n;
    final manager = ref.read(appDependenciesProvider).equipment;
    setState(() {
      _saving = true;
      _error = null;
    });
    final outcome = await manager.submitFuelFill(
      equipmentId: widget.equipment.id,
      source: _source,
      stationId: _stationId,
      storeId: _storeId,
      voucherNumber: _voucher.text,
      gallons: _number(_gallons) ?? 0,
      meterValue: widget.equipment.needsMeterForInspection ? _number(_meter) : null,
      workFront: _front.text,
      driverName: _driver.text,
      driverDocument: _document.text,
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
        FuelProblem.sourceMissing => l10n.equipmentFuelSourceMissing,
        FuelProblem.voucherRequired => l10n.equipmentFuelVoucherRequired,
        FuelProblem.invalidGallons => l10n.equipmentFuelInvalidGallons,
        FuelProblem.meterRequired || FuelProblem.invalidMeter => l10n.equipmentFuelMeterRequired,
        FuelProblem.meterBackwards => l10n.equipmentFuelMeterBackwards(
          formatMeter(double.tryParse(outcome.detail ?? '') ?? 0),
        ),
        FuelProblem.equipmentNotFound => l10n.equipmentReadingUnavailable,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final equipment = widget.equipment;
    final catalog = _catalog;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.equipmentFuelRegister)),
      body: catalog == null
          ? const Center(child: CircularProgressIndicator())
          : AppPageBody(
              children: [
                Text(l10n.equipmentListTitle(equipment.code, equipment.name), style: theme.textTheme.titleLarge),
                const AppGap.sm(),
                if (catalog.isEmpty)
                  Text(l10n.equipmentFuelNoCatalog, key: const Key('fuel_no_catalog'))
                else ...[
                  SegmentedButton<FuelSource>(
                    key: const Key('fuel_source'),
                    segments: [
                      if (catalog.stations.isNotEmpty)
                        ButtonSegment(value: FuelSource.station, label: Text(l10n.equipmentFuelSourceStation)),
                      if (catalog.stores.isNotEmpty)
                        ButtonSegment(value: FuelSource.store, label: Text(l10n.equipmentFuelSourceStore)),
                    ],
                    selected: {_source},
                    onSelectionChanged: (selection) => setState(() => _source = selection.first),
                  ),
                  const AppGap.sm(),
                  if (_source == FuelSource.station)
                    DropdownButtonFormField<String>(
                      key: const Key('fuel_station'),
                      initialValue: _stationId,
                      decoration: InputDecoration(labelText: l10n.equipmentFuelStation),
                      items: [
                        for (final station in catalog.stations)
                          DropdownMenuItem(value: station.id, child: Text(l10n.equipmentFuelStationLabel(station.supplier, station.name))),
                      ],
                      onChanged: (id) => setState(() => _stationId = id),
                    )
                  else
                    DropdownButtonFormField<String>(
                      key: const Key('fuel_store'),
                      initialValue: _storeId,
                      decoration: InputDecoration(labelText: l10n.equipmentFuelStore),
                      items: [
                        for (final store in catalog.stores) DropdownMenuItem(value: store.id, child: Text(store.name)),
                      ],
                      onChanged: (id) => setState(() => _storeId = id),
                    ),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('fuel_voucher'),
                    controller: _voucher,
                    decoration: InputDecoration(labelText: l10n.equipmentFuelVoucher),
                  ),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('fuel_gallons'),
                    controller: _gallons,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: l10n.equipmentFuelGallons),
                  ),
                  if (equipment.needsMeterForInspection) ...[
                    const AppGap.sm(),
                    TextField(
                      key: const Key('fuel_meter'),
                      controller: _meter,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: l10n.equipmentFuelMeter(meterUnitLabel(l10n, equipment.meterUnits.first)),
                      ),
                    ),
                  ],
                  const AppGap.sm(),
                  TextField(
                    key: const Key('fuel_front'),
                    controller: _front,
                    decoration: InputDecoration(labelText: l10n.equipmentFuelFront),
                  ),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('fuel_driver'),
                    controller: _driver,
                    decoration: InputDecoration(labelText: l10n.equipmentFuelDriver),
                  ),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('fuel_document'),
                    controller: _document,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l10n.equipmentFuelDriverDocument),
                  ),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('fuel_notes'),
                    controller: _notes,
                    decoration: InputDecoration(labelText: l10n.equipmentFuelNotes),
                  ),
                  if (_error != null) ...[
                    const AppGap.sm(),
                    Text(
                      _error!,
                      key: const Key('fuel_error'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                  const AppGap.lg(),
                  AppButton(
                    key: const Key('fuel_submit'),
                    label: l10n.equipmentFuelSave,
                    isLoading: _saving,
                    onPressed: _saving ? null : _submit,
                  ),
                ],
              ],
            ),
    );
  }
}
