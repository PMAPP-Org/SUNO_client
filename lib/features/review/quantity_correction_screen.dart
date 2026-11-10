// Corregir las cantidades de un registro rechazado (costos, pieza 4b): la misma sección
// de captura de cantidades, con las filas que rechazó el servidor señaladas. Se reasigna
// el ítem o la ubicación, o se quita la fila; al guardar se reenvía
// (`QuarantineService.correctQuantities`).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/schedule/quantity_rows.dart';
import '../../core/sync/quarantine_service.dart';
import '../../l10n/l10n.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import '../capture/quantity_capture_section.dart';

class QuantityCorrectionScreen extends ConsumerStatefulWidget {
  const QuantityCorrectionScreen({super.key, required this.item});

  final QuarantinedRecord item;

  @override
  ConsumerState<QuantityCorrectionScreen> createState() => _QuantityCorrectionScreenState();
}

class _QuantityCorrectionScreenState extends ConsumerState<QuantityCorrectionScreen> {
  late final QuantityCaptureController _controller;
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Corregir no vuelve a leer el GPS: cada fila conserva los datos de su captura.
    _controller = QuantityCaptureController(
      newId: ref.read(appDependenciesProvider).recordCapture.newAttachmentId,
      readGps: () async => null,
    );
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final record = widget.item.record;
    final taskId = record.taskId ?? '';
    final schedule = ref.read(appDependenciesProvider).scheduleTaskRepository;
    final stored = decodeQuantities(record.quantitiesJson);
    final task = await schedule.byId(taskId);
    final quantityContext = await schedule.quantityContext(taskId: taskId, projectId: task?.projectId);
    final known = await schedule.knownItems({for (final row in stored) row['item_id']! as String});
    if (!mounted) return;
    _controller.load(
      quantityContext,
      stored: stored,
      known: known,
      flaggedRows: {for (final flag in widget.item.quantityFlags) flag.index},
    );
    setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    if (!_controller.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.captureFixErrors)));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(appDependenciesProvider).quarantine.correctQuantities(widget.item, _controller.payload());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.quantityCorrectionTitle)),
      body: AppPageBody(
        children: [
          if (!_loaded)
            const Center(child: CircularProgressIndicator())
          else ...[
            Text(l10n.quantityCorrectionExplain),
            const AppGap.sm(),
            QuantityCaptureSection(controller: _controller, correcting: true),
            const AppGap.lg(),
            AppButton(
              key: const Key('quantity_correction_save'),
              label: l10n.correctionSave,
              loadingLabel: l10n.captureSaving,
              isLoading: _saving,
              onPressed: _save,
            ),
          ],
        ],
      ),
    );
  }
}
