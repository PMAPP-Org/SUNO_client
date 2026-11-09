// "Equipos" (Maquinaria y equipos, fase 1): los equipos que el agente puede ver,
// desde la caché del teléfono (sin red), con búsqueda por código, nombre o
// placa y lectura de su QR. Al abrir intenta actualizar la lista; si no hay
// red se queda con la última descarga.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/equipment/equipment_models.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_theme.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import '../capture/qr_capture_screen.dart';
import '../../core/equipment/equipment_manager.dart';
import 'equipment_detail_screen.dart';
import 'equipment_labels.dart';
import 'trip_screen.dart';

class EquipmentScreen extends ConsumerStatefulWidget {
  const EquipmentScreen({super.key});

  @override
  ConsumerState<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends ConsumerState<EquipmentScreen> {
  List<FieldEquipment>? _items;
  List<PendingTrip> _pendingTrips = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    final manager = ref.read(appDependenciesProvider).equipment;
    final cached = await manager.list();
    final trips = await manager.pendingTrips();
    if (mounted) {
      setState(() {
        _items = cached;
        _pendingTrips = trips;
      });
    }
    if (!refresh) return;
    final ok = await manager.refresh();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.equipmentRefreshFailed)));
      return;
    }
    final fresh = await manager.list();
    if (mounted) setState(() => _items = fresh);
  }

  Future<void> _open(FieldEquipment equipment) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => EquipmentDetailScreen(equipmentId: equipment.id)),
    );
    await _load();
  }

  Future<void> _registerTrip() async {
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => const TripScreen()));
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.tripQueued)));
      await _load();
    }
  }

  Future<void> _scan() async {
    final scan = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const QrCaptureScreen()));
    if (scan == null || !mounted) return;
    final found = await ref.read(appDependenciesProvider).equipment.findByScan(scan);
    if (!mounted) return;
    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.equipmentScanNotFound)));
      return;
    }
    await _open(found);
  }

  bool _matches(FieldEquipment item) {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return item.code.toLowerCase().contains(needle) ||
        item.name.toLowerCase().contains(needle) ||
        item.licensePlate.toLowerCase().contains(needle);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final items = _items;
    final colors = context.statusColors;
    final visible = items?.where(_matches).toList() ?? const <FieldEquipment>[];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.equipmentTitle)),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : AppPageBody(
              children: [
                AppButton(
                  key: const Key('equipment_scan_button'),
                  label: l10n.equipmentScan,
                  icon: Icons.qr_code_scanner,
                  onPressed: _scan,
                ),
                const AppGap.sm(),
                AppButton(
                  key: const Key('equipment_register_trip'),
                  label: l10n.tripRegister,
                  icon: Icons.local_shipping_outlined,
                  secondary: true,
                  onPressed: _registerTrip,
                ),
                if (_pendingTrips.isNotEmpty) ...[
                  const AppGap.sm(),
                  Text(l10n.tripPending, style: Theme.of(context).textTheme.titleSmall),
                  for (final trip in _pendingTrips)
                    ListTile(
                      key: ValueKey('pending-trip-${trip.id}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        trip.rejected ? Icons.error_outline : Icons.schedule,
                        color: trip.rejected ? Theme.of(context).colorScheme.error : colors.warning,
                      ),
                      title: Text(l10n.tripPendingLine(trip.vehicleLabel, formatMeter(trip.volumeM3))),
                      subtitle: Text(
                        [
                          MaterialLocalizations.of(context).formatShortDate(trip.recordedAt.toLocal()),
                          if (trip.rejected) l10n.equipmentReadingRejected else l10n.equipmentReadingPending,
                          if (trip.rejected && trip.lastError != null) trip.lastError!,
                        ].join(' · '),
                      ),
                      trailing: trip.rejected
                          ? TextButton(
                              onPressed: () async {
                                await ref.read(appDependenciesProvider).equipment.dismissRejectedTrip(trip.id);
                                await _load();
                              },
                              child: Text(l10n.equipmentReadingDismiss),
                            )
                          : null,
                    ),
                ],
                const AppGap.sm(),
                TextField(
                  key: const Key('equipment_search'),
                  decoration: InputDecoration(labelText: l10n.equipmentSearchLabel, prefixIcon: const Icon(Icons.search)),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const AppGap.sm(),
                if (items.isEmpty)
                  Text(l10n.equipmentEmpty, key: const Key('equipment_empty'))
                else if (visible.isEmpty)
                  Text(l10n.equipmentNoMatches, key: const Key('equipment_no_matches')),
                for (final item in visible)
                  ListTile(
                    key: ValueKey('equipment-${item.id}'),
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(item.hasExpired ? Icons.warning_amber_outlined : Icons.precision_manufacturing_outlined,
                        color: item.hasExpired ? colors.warning : null),
                    title: Text(l10n.equipmentListTitle(item.code, item.name)),
                    subtitle: Text(
                      [
                        item.typeName,
                        if (item.licensePlate.isNotEmpty) item.licensePlate,
                        equipmentStatusLabel(l10n, item.status),
                        if (item.alerts.isNotEmpty) l10n.equipmentAlertsCount(item.alerts.length),
                      ].join(' · '),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(item),
                  ),
              ],
            ),
    );
  }
}
