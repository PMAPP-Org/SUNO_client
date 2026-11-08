// Viaje de material (M&E fase 5): vehículo (equipo propio o de terceros), tramo,
// material, volumen y las tres personas del viaje (solicita, despacha, recibe).
// Se valida en el teléfono y queda en cola; sale en el siguiente ciclo de
// sincronización y el servidor fija distancia y tarifa y decide el resto.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/equipment/equipment_manager.dart';
import '../../core/equipment/equipment_models.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import 'equipment_labels.dart';

enum _VehicleKind { own, third }

class TripScreen extends ConsumerStatefulWidget {
  const TripScreen({super.key});

  @override
  ConsumerState<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends ConsumerState<TripScreen> {
  final _volume = TextEditingController();
  final _driver = TextEditingController();
  final _document = TextEditingController();
  final _notes = TextEditingController();
  TransportCatalogInfo? _catalog;
  List<FieldEquipment> _equipment = const [];
  _VehicleKind _kind = _VehicleKind.third;
  String? _equipmentId;
  String? _vehicleId;
  String? _routeId;
  String? _materialId;
  String? _requestedBy;
  String? _dispatchedBy;
  String? _receivedBy;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [_volume, _driver, _document, _notes]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final dependencies = ref.read(appDependenciesProvider);
    final catalog = await dependencies.equipment.transportCatalog();
    final equipment = await dependencies.equipment.list();
    final auth = dependencies.authController.state;
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _equipment = equipment;
      if (catalog.vehicles.isEmpty && equipment.isNotEmpty) _kind = _VehicleKind.own;
      if (catalog.routes.length == 1) _routeId = catalog.routes.first.id;
      if (catalog.materials.length == 1) _materialId = catalog.materials.first.id;
      // Quien registra suele ser quien despacha.
      if (auth is Authenticated && catalog.people.any((p) => p.id == auth.user.id)) _dispatchedBy = auth.user.id;
    });
  }

  Future<void> _submit() async {
    final l10n = context.l10n;
    final manager = ref.read(appDependenciesProvider).equipment;
    setState(() {
      _saving = true;
      _error = null;
    });
    final outcome = await manager.submitTrip(
      equipmentId: _kind == _VehicleKind.own ? _equipmentId : null,
      vehicleId: _kind == _VehicleKind.third ? _vehicleId : null,
      routeId: _routeId ?? '',
      materialId: _materialId ?? '',
      volumeM3: double.tryParse(_volume.text.trim().replaceAll(',', '.')) ?? 0,
      requestedBy: _requestedBy ?? '',
      dispatchedBy: _dispatchedBy ?? '',
      receivedBy: _receivedBy ?? '',
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
        TripProblem.vehicleMissing => l10n.tripVehicleMissing,
        TripProblem.routeMissing => l10n.tripRouteMissing,
        TripProblem.materialMissing => l10n.tripMaterialMissing,
        TripProblem.invalidVolume => l10n.tripInvalidVolume,
        TripProblem.overCapacity => l10n.tripOverCapacity(outcome.detail ?? ''),
        TripProblem.peopleMissing => l10n.tripPeopleMissing,
        TripProblem.sameDispatcherAndReceiver => l10n.tripSameDispatcherReceiver,
      };
    });
  }

  DropdownButtonFormField<String> _people(String key, String label, String? value, void Function(String?) onChanged) {
    return DropdownButtonFormField<String>(
      key: Key(key),
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [for (final person in _catalog!.people) DropdownMenuItem(value: person.id, child: Text(person.name))],
      onChanged: (id) => setState(() => onChanged(id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final catalog = _catalog;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.tripRegister)),
      body: catalog == null
          ? const Center(child: CircularProgressIndicator())
          : AppPageBody(
              children: [
                if (!catalog.canRegisterTrips)
                  Text(l10n.tripNoCatalog, key: const Key('trip_no_catalog'))
                else ...[
                  SegmentedButton<_VehicleKind>(
                    key: const Key('trip_kind'),
                    segments: [
                      ButtonSegment(value: _VehicleKind.third, label: Text(l10n.tripVehicleThird)),
                      ButtonSegment(value: _VehicleKind.own, label: Text(l10n.tripVehicleOwn)),
                    ],
                    selected: {_kind},
                    onSelectionChanged: (selection) => setState(() => _kind = selection.first),
                  ),
                  const AppGap.sm(),
                  if (_kind == _VehicleKind.own)
                    DropdownButtonFormField<String>(
                      key: const Key('trip_equipment'),
                      initialValue: _equipmentId,
                      decoration: InputDecoration(labelText: l10n.tripEquipment),
                      items: [
                        for (final item in _equipment)
                          DropdownMenuItem(value: item.id, child: Text(l10n.equipmentListTitle(item.code, item.name))),
                      ],
                      onChanged: (id) => setState(() => _equipmentId = id),
                    )
                  else
                    DropdownButtonFormField<String>(
                      key: const Key('trip_vehicle'),
                      initialValue: _vehicleId,
                      decoration: InputDecoration(labelText: l10n.tripThirdVehicle),
                      items: [
                        for (final v in catalog.vehicles)
                          DropdownMenuItem(value: v.id, child: Text(l10n.tripThirdVehicleLabel(v.plate, v.contractor))),
                      ],
                      onChanged: (id) => setState(() => _vehicleId = id),
                    ),
                  const AppGap.sm(),
                  DropdownButtonFormField<String>(
                    key: const Key('trip_route'),
                    initialValue: _routeId,
                    decoration: InputDecoration(labelText: l10n.tripRoute),
                    items: [
                      for (final r in catalog.routes)
                        DropdownMenuItem(
                          value: r.id,
                          child: Text(l10n.tripRouteLabel(r.origin, r.destination, formatMeter(r.distanceKm))),
                        ),
                    ],
                    onChanged: (id) => setState(() => _routeId = id),
                  ),
                  const AppGap.sm(),
                  DropdownButtonFormField<String>(
                    key: const Key('trip_material'),
                    initialValue: _materialId,
                    decoration: InputDecoration(labelText: l10n.tripMaterial),
                    items: [for (final m in catalog.materials) DropdownMenuItem(value: m.id, child: Text(m.name))],
                    onChanged: (id) => setState(() => _materialId = id),
                  ),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('trip_volume'),
                    controller: _volume,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: l10n.tripVolume),
                  ),
                  const AppGap.sm(),
                  _people('trip_requested', l10n.tripRequestedBy, _requestedBy, (id) => _requestedBy = id),
                  const AppGap.sm(),
                  _people('trip_dispatched', l10n.tripDispatchedBy, _dispatchedBy, (id) => _dispatchedBy = id),
                  const AppGap.sm(),
                  _people('trip_received', l10n.tripReceivedBy, _receivedBy, (id) => _receivedBy = id),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('trip_driver'),
                    controller: _driver,
                    decoration: InputDecoration(labelText: l10n.tripDriver),
                  ),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('trip_document'),
                    controller: _document,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: l10n.tripDriverDocument),
                  ),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('trip_notes'),
                    controller: _notes,
                    decoration: InputDecoration(labelText: l10n.tripNotes),
                  ),
                  if (_error != null) ...[
                    const AppGap.sm(),
                    Text(
                      _error!,
                      key: const Key('trip_error'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                  const AppGap.lg(),
                  AppButton(
                    key: const Key('trip_submit'),
                    label: l10n.tripSave,
                    isLoading: _saving,
                    onPressed: _saving ? null : _submit,
                  ),
                ],
              ],
            ),
    );
  }
}
