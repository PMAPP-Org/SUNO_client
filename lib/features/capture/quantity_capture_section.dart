// Captura de cantidades (costos, pieza 4b): en una tarea medida por cantidades, una fila
// por ítem planeado con "Cantidad hoy", su ubicación y su nota; "Agregar ítem no
// planeado" y "Otra fila de este ítem". El controlador guarda el estado y los datos
// automáticos de cada fila (hora, lo que se veía, GPS); la sección solo dibuja. La misma
// sección corrige un rechazo del servidor (`correcting`): cada fila se puede quitar y la
// señalada, cambiar de ítem.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/schedule/quantity_rows.dart';
import '../../data/local/schedule_task_repository.dart' show foldForSearch;
import '../../l10n/l10n.dart';
import '../../ui/theme/app_tokens.dart';

class QuantityCaptureController extends ChangeNotifier {
  QuantityCaptureController({required this._newId, required this._readGps, DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final String Function() _newId;
  final Future<GpsReading?> Function() _readGps;
  final DateTime Function() _now;

  QuantityTaskContext? _task;
  List<QuantityRowDraft> _rows = const [];
  Set<String> _flagged = const {};
  bool _readOnly = false;
  QuantityCheck? _check;
  bool _disposed = false;

  /// La tarea cargada; `null` si la elegida no se mide por cantidades.
  QuantityTaskContext? get task => _task;
  List<QuantityRowDraft> get rows => _rows;
  bool get readOnly => _readOnly;

  /// El resultado de la última validación (se recalcula al editar).
  QuantityCheck? get check => _check;

  /// Hay algo escrito en alguna "Cantidad hoy".
  bool get hasCaptured => _rows.any((r) => r.text.trim().isNotEmpty);
  Set<String> get overruns => overrunItems(_rows);
  bool isFlagged(String clientId) => _flagged.contains(clientId);

  /// Carga la tarea: una fila vacía por ítem planeado y, encima, las filas [stored] de un
  /// registro (la primera de cada ítem planeado ocupa su fila; las demás se agregan).
  /// [known] da código y unidad de los ítems que ya no están en la tarea ni en el
  /// catálogo; [flaggedRows] son las posiciones en [stored] que rechazó el servidor.
  void load(
    QuantityTaskContext task, {
    List<Map<String, Object?>> stored = const [],
    Map<String, QuantityItem> known = const {},
    bool readOnly = false,
    Set<int> flaggedRows = const {},
  }) {
    final rows = <QuantityRowDraft>[
      for (final p in task.planned)
        QuantityRowDraft(clientId: _newId(), item: p.item, planned: p.planned, validated: p.validated, isPlanned: true),
    ];
    final filled = <String>{};
    final flagged = <String>{};
    for (final (index, json) in stored.indexed) {
      final itemId = json['item_id']! as String;
      final planned = task.plannedFor(itemId);
      final item = planned?.item ?? known[itemId] ?? task.catalogItem(itemId) ?? QuantityItem.unknown(itemId);
      final slot = planned != null && !filled.contains(itemId)
          ? rows.indexWhere((r) => r.isPlanned && r.item.itemId == itemId)
          : -1;
      final row = QuantityRowDraft.fromStored(
        json,
        item: item,
        planned: planned,
        fallbackId: _newId(),
        added: slot < 0,
      );
      if (slot >= 0) {
        rows[slot] = row;
        filled.add(itemId);
      } else {
        rows.add(row);
      }
      if (flaggedRows.contains(index)) flagged.add(row.clientId);
    }
    _task = task;
    _rows = rows;
    _flagged = flagged;
    _readOnly = readOnly;
    _check = null;
    notifyListeners();
  }

  /// La tarea elegida ya no se mide por cantidades (o no hay tarea).
  void clear() {
    _task = null;
    _rows = const [];
    _flagged = const {};
    _readOnly = false;
    _check = null;
    notifyListeners();
  }

  /// Lo escrito en "Cantidad hoy". La primera vez que una fila nueva recibe un número se
  /// toman sus datos automáticos: hora, lo que la app mostraba y una lectura GPS puntual.
  /// Una fila que ya existía conserva los suyos (ver `QuantityRowDraft.storedCapture`).
  void setQuantity(String clientId, String text) {
    var started = false;
    _replace(clientId, (row) {
      if (row.isStored || row.capturedAt != null || text.trim().isEmpty) return row.copyWith(text: text);
      started = true;
      return row.copyWith(
        text: text,
        capturedAt: _now().toUtc(),
        seen: QuantitySeen(
          planned: row.isPlanned ? row.planned : null,
          validated: row.isPlanned ? row.validated : null,
          locationId: _task?.taskLocation?.id,
        ),
      );
    });
    if (started) unawaited(_attachGps(clientId));
  }

  void setNote(String clientId, String note) => _replace(clientId, (row) => row.copyWith(note: note));

  /// `null`: la ubicación de la tarea.
  void setLocation(String clientId, String? locationId) {
    _flagged = {..._flagged}..remove(clientId);
    _replace(clientId, (row) => row.copyWith(locationId: locationId));
  }

  void addUnplanned(QuantityItem item) {
    _rows = [..._rows, QuantityRowDraft(clientId: _newId(), item: item, added: true)];
    _changed();
  }

  /// "Otra fila de este ítem" (p. ej. otra ubicación), justo debajo de [clientId].
  void addRowLike(String clientId) {
    final index = _rows.indexWhere((r) => r.clientId == clientId);
    if (index < 0) return;
    final source = _rows[index];
    final copy = QuantityRowDraft(
      clientId: _newId(),
      item: source.item,
      planned: source.planned,
      validated: source.validated,
      isPlanned: source.isPlanned,
      added: true,
    );
    _rows = [..._rows.sublist(0, index + 1), copy, ..._rows.sublist(index + 1)];
    _changed();
  }

  void removeRow(String clientId) {
    _rows = [
      for (final row in _rows)
        if (row.clientId != clientId) row,
    ];
    _flagged = {..._flagged}..remove(clientId);
    _changed();
  }

  /// Corrección de un rechazo: la fila pasa a [item] (planeado o no en la tarea).
  void reassignItem(String clientId, QuantityItem item) {
    final planned = _task?.plannedFor(item.itemId);
    _flagged = {..._flagged}..remove(clientId);
    _replace(
      clientId,
      (row) => row.copyWith(
        item: item,
        planned: planned?.planned,
        validated: planned?.validated,
        isPlanned: planned != null,
      ),
    );
  }

  /// Valida al guardar; las filas con problemas quedan señaladas. Un registro de solo
  /// lectura no tiene nada que validar.
  bool validate() {
    if (_readOnly) return true;
    _check = checkQuantityRows(_rows);
    notifyListeners();
    return _check!.ok;
  }

  /// Las filas que viajan (`RecordQuantityPayload`).
  List<Map<String, Object?>> payload() => quantityPayload(_rows);

  Future<void> _attachGps(String clientId) async {
    final reading = await _readGps();
    if (_disposed || reading == null) return;
    if (!_rows.any((r) => r.clientId == clientId && r.gps == null)) return;
    _replace(clientId, (row) => row.copyWith(gps: reading));
  }

  void _replace(String clientId, QuantityRowDraft Function(QuantityRowDraft row) change) {
    _rows = [for (final row in _rows) row.clientId == clientId ? change(row) : row];
    _changed();
  }

  void _changed() {
    if (_check != null) _check = checkQuantityRows(_rows);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Valor del desplegable para "la ubicación de la tarea" (`location_id: null`).
const _taskLocationValue = '';

class QuantityCaptureSection extends StatelessWidget {
  const QuantityCaptureSection({super.key, required this.controller, this.correcting = false});

  final QuantityCaptureController controller;

  /// Corrección de un rechazo del servidor (`QuantityCorrectionScreen`).
  final bool correcting;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final task = controller.task;
      if (task == null) return const SizedBox.shrink();
      final l10n = context.l10n;
      final theme = Theme.of(context);
      final check = controller.check;
      final overruns = controller.overruns;
      final error = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error);
      return Column(
        key: const Key('quantity_section'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.quantitySectionTitle, style: theme.textTheme.titleSmall),
          if (controller.readOnly) Text(l10n.quantityReadOnly, key: const Key('quantity_read_only')),
          for (final row in controller.rows)
            _QuantityRowCard(
              key: ValueKey('quantity_row-${row.clientId}'),
              row: row,
              task: task,
              controller: controller,
              correcting: correcting,
              problem: check?.rows[row.clientId],
              overrun: overruns.contains(row.item.itemId),
            ),
          if (check?.noQuantity ?? false) Text(l10n.quantityNoneEntered, key: const Key('quantity_none'), style: error),
          if (check?.tooManyRows ?? false)
            Text(l10n.quantityTooManyRows(maxQuantityRows), key: const Key('quantity_too_many'), style: error),
          if (!controller.readOnly && !correcting)
            OutlinedButton.icon(
              key: const Key('quantity_add_unplanned'),
              onPressed: task.unplannedCatalog.isEmpty
                  ? null
                  : () async {
                      final item = await showQuantityItemPicker(context, task.unplannedCatalog);
                      if (item != null) controller.addUnplanned(item);
                    },
              icon: const Icon(Icons.add),
              label: Text(l10n.quantityAddUnplanned),
            ),
        ],
      );
    },
  );
}

class _QuantityRowCard extends StatelessWidget {
  const _QuantityRowCard({
    super.key,
    required this.row,
    required this.task,
    required this.controller,
    required this.correcting,
    required this.problem,
    required this.overrun,
  });

  final QuantityRowDraft row;
  final QuantityTaskContext task;
  final QuantityCaptureController controller;
  final bool correcting;
  final QuantityRowProblem? problem;
  final bool overrun;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final readOnly = controller.readOnly;
    final flagged = controller.isFlagged(row.clientId);
    final warning = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error);
    final id = row.clientId;
    final taskLocation = task.taskLocation;
    final taskLabel = taskLocation == null
        ? l10n.quantityLocationTask
        : l10n.quantityLocationTaskNamed(taskLocation.label);
    final unknownLocation = row.locationId != null && !task.refinements.any((o) => o.id == row.locationId);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(row.item.label, style: theme.textTheme.titleSmall),
            Text(
              row.isPlanned
                  ? l10n.quantityPlannedValidated(
                      formatQuantity(row.planned ?? 0),
                      formatQuantity(row.validated ?? 0),
                      row.item.unit,
                    )
                  : l10n.quantityUnplanned,
              key: ValueKey('quantity_reference-$id'),
              style: theme.textTheme.bodySmall,
            ),
            if (flagged) Text(l10n.quantityRowFlagged, key: ValueKey('quantity_flagged-$id'), style: warning),
            TextFormField(
              key: ValueKey('quantity_field-$id'),
              initialValue: row.text,
              enabled: !readOnly,
              keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
              decoration: InputDecoration(
                labelText: l10n.quantityToday,
                suffixText: row.item.unit.isEmpty ? null : row.item.unit,
                errorText: problem == QuantityRowProblem.invalidNumber ? l10n.quantityInvalid : null,
              ),
              onChanged: (value) => controller.setQuantity(id, value),
            ),
            if (overrun)
              Text(
                l10n.quantityOverrun(
                  formatQuantity((row.validated ?? 0) + todayTotal(controller.rows, row.item.itemId)),
                  formatQuantity(row.planned ?? 0),
                  row.item.unit,
                ),
                key: ValueKey('quantity_overrun-$id'),
                style: warning,
              ),
            if (row.isAdjustment)
              Text(l10n.quantityAdjustment, key: ValueKey('quantity_adjustment-$id'), style: theme.textTheme.bodySmall),
            if (task.refinements.isNotEmpty || row.locationId != null)
              DropdownButtonFormField<String>(
                key: ValueKey('quantity_location-$id'),
                initialValue: row.locationId ?? _taskLocationValue,
                isExpanded: true,
                decoration: InputDecoration(labelText: l10n.quantityLocation),
                items: [
                  DropdownMenuItem(
                    value: _taskLocationValue,
                    child: Text(taskLabel, overflow: TextOverflow.ellipsis),
                  ),
                  for (final option in task.refinements)
                    DropdownMenuItem(
                      value: option.id,
                      child: Text(option.label, overflow: TextOverflow.ellipsis),
                    ),
                  // Una ubicación guardada que ya no está entre las opciones (rechazada o retirada).
                  if (unknownLocation)
                    DropdownMenuItem(
                      value: row.locationId,
                      child: Text(l10n.quantityLocationRefined, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: readOnly
                    ? null
                    : (value) =>
                          controller.setLocation(id, value == null || value == _taskLocationValue ? null : value),
              )
            else if (taskLocation != null)
              Text(taskLabel, style: theme.textTheme.bodySmall),
            TextFormField(
              key: ValueKey('quantity_note-$id'),
              initialValue: row.note,
              enabled: !readOnly,
              maxLength: maxQuantityNote,
              decoration: InputDecoration(
                labelText: row.needsNote ? l10n.quantityNoteRequiredLabel : l10n.quantityNote,
                errorText: switch (problem) {
                  QuantityRowProblem.noteRequired => l10n.quantityNoteRequired,
                  QuantityRowProblem.noteTooLong => l10n.quantityNoteTooLong,
                  _ => null,
                },
              ),
              onChanged: (value) => controller.setNote(id, value),
            ),
            if (!readOnly)
              Wrap(
                spacing: AppSpacing.xs,
                children: [
                  if (!correcting)
                    TextButton(
                      key: ValueKey('quantity_add_row-$id'),
                      onPressed: () => controller.addRowLike(id),
                      child: Text(l10n.quantityAddRow),
                    ),
                  if (correcting && flagged)
                    TextButton(
                      key: ValueKey('quantity_reassign-$id'),
                      onPressed: () async {
                        final item = await showQuantityItemPicker(context, task.allItems);
                        if (item != null) controller.reassignItem(id, item);
                      },
                      child: Text(l10n.quantityReassign),
                    ),
                  if (row.added || correcting)
                    TextButton(
                      key: ValueKey('quantity_remove-$id'),
                      onPressed: () => controller.removeRow(id),
                      child: Text(l10n.quantityRemoveRow),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Buscador de ítems por código o descripción. `null` si se cerró sin elegir.
Future<QuantityItem?> showQuantityItemPicker(BuildContext context, List<QuantityItem> items) =>
    showModalBottomSheet<QuantityItem>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _QuantityItemSheet(items: items),
    );

class _QuantityItemSheet extends StatefulWidget {
  const _QuantityItemSheet({required this.items});

  final List<QuantityItem> items;

  @override
  State<_QuantityItemSheet> createState() => _QuantityItemSheetState();
}

class _QuantityItemSheetState extends State<_QuantityItemSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final needle = foldForSearch(_query.trim());
    final visible = [
      for (final item in widget.items)
        if (needle.isEmpty || foldForSearch('${item.code} ${item.description}').contains(needle)) item,
    ];
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
                  key: const Key('quantity_item_search'),
                  autofocus: true,
                  decoration: InputDecoration(labelText: l10n.quantityItemSearch, prefixIcon: const Icon(Icons.search)),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? Center(child: Text(l10n.quantityItemEmpty))
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, index) {
                          final item = visible[index];
                          return ListTile(
                            key: ValueKey('quantity_item-${item.itemId}'),
                            title: Text(item.label),
                            subtitle: Text(item.unit),
                            onTap: () => Navigator.of(context).pop(item),
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
