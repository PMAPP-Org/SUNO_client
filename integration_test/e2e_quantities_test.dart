// Prueba E2E de cantidades (costos, pieza 4b). La ejecuta `E2E_FLOW=quantities bash
// tool/e2e.sh`, que siembra la tarea 1.1 medida por cantidades (`bootstrap_demo
// --with-quantities`), valida el registro en el servidor cuando la prueba lo pide y
// verifica el resultado. No funciona sola: necesita los --dart-define del script.
//
// Coordinación con el script por `adb logcat` (tag `flutter`):
//   E2E:SHOT:<nombre>     → el script guarda una captura de pantalla (si E2E_SHOTS)
//   E2E:SYNCED            → el script valida el registro en el servidor
//   E2E:VALIDATED_SEEN    → la tarea muestra lo validado (12,5 m3)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:suno/features/home/record_status_list.dart';
import 'package:suno/main.dart' as app;

const _username = String.fromEnvironment('E2E_USERNAME');
const _password = String.fromEnvironment('E2E_PASSWORD');
const _marker = String.fromEnvironment('E2E_MARKER');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cantidades capturadas en campo llegan, se validan y la tarea lo refleja', (tester) async {
    expect(
      _username.isNotEmpty && _password.isNotEmpty && _marker.isNotEmpty,
      isTrue,
      reason: 'Ejecutar con E2E_FLOW=quantities tool/e2e.sh: faltan E2E_USERNAME/E2E_PASSWORD/E2E_MARKER',
    );

    await app.main();
    await _pumpUntilAny(tester, [
      find.byKey(const Key('privacy_accept_button')),
      find.byKey(const Key('login_submit_button')),
    ]);

    // Aviso de privacidad (Ley 1581), solo si falta la autorización.
    if (find.byKey(const Key('privacy_accept_button')).evaluate().isNotEmpty) {
      for (final purpose in ['account', 'location', 'photos']) {
        await _tapVisible(tester, find.byKey(Key('privacy_$purpose')));
      }
      await _tapVisible(tester, find.byKey(const Key('privacy_accept_button')));
      await _pumpUntil(tester, find.byKey(const Key('login_submit_button')));
    }

    // Login. El primer intento choca con la CA interna de Caddy: TOFU.
    await tester.enterText(find.byKey(const Key('login_username_field')), _username);
    await tester.enterText(find.byKey(const Key('login_password_field')), _password);
    await _tapVisible(tester, find.byKey(const Key('login_submit_button')));
    await _pumpUntil(tester, find.byKey(const Key('tofu_trust_button')));
    await _tapVisible(tester, find.byKey(const Key('tofu_compared_check')));
    await _tapVisible(tester, find.byKey(const Key('tofu_trust_button')));
    await _pumpUntil(tester, find.byKey(const Key('home_new_record_button')), timeout: const Duration(seconds: 60));

    // Sincronización inicial: plantilla, tareas, ítems planeados y catálogo.
    await _tapVisible(tester, find.byKey(const Key('home_sync_button')));
    await _pumpUntil(tester, find.byKey(const Key('home_last_sync')), timeout: const Duration(seconds: 60));

    // Captura (con red): 12,5 m3 del 1.1 planeado y 3 m3 del 1.2 no planeado, con nota.
    await _tapVisible(tester, find.byKey(const Key('home_new_record_button')));
    await _pumpUntil(tester, find.byKey(const Key('capture_save_button')));
    final notas = find.descendant(of: find.byKey(const ValueKey('form-field-notas')), matching: find.byType(TextField));
    await tester.enterText(notas, _marker);
    await _pickExcavation(tester);
    await _pumpUntil(tester, find.textContaining('Planeado 100 m3'));
    expect(find.byKey(const Key('capture_progress_field')), findsNothing, reason: 'cantidades en lugar del %');
    await tester.enterText(_byKeyPrefix('quantity_field-').first, '12,5');
    await tester.pump();
    await tester.ensureVisible(_byKeyPrefix('quantity_field-').first);
    await _shot(tester, 'captura-cantidades');
    await _tapVisible(tester, find.byKey(const Key('quantity_add_unplanned')));
    await _pumpUntil(tester, find.byKey(const Key('quantity_item_search')));
    await tester.enterText(find.byKey(const Key('quantity_item_search')), 'retiro');
    await tester.pump();
    await _shot(tester, 'buscador-items');
    await _tapVisible(tester, find.textContaining('Retiro de sobrantes'));
    await _pumpUntil(tester, find.text('No planeado en esta tarea'));
    await tester.enterText(_byKeyPrefix('quantity_field-').last, '3');
    await tester.enterText(_byKeyPrefix('quantity_note-').last, 'sobrante E2E');
    await tester.pump();
    await tester.ensureVisible(_byKeyPrefix('quantity_note-').last);
    await _shot(tester, 'captura-no-planeado');
    await _tapVisible(tester, find.byKey(const Key('capture_save_button')));
    await _pumpUntil(tester, find.byKey(const Key('home_new_record_button')));

    // Sincroniza hasta que el registro quede confirmado.
    final synced = DateTime.now().add(const Duration(seconds: 120));
    while (_chip('Sincronizado').evaluate().isEmpty) {
      if (DateTime.now().isAfter(synced)) fail('El registro no pasó a Sincronizado en 120 s');
      await _tapVisible(tester, find.byKey(const Key('home_sync_button')));
      await _pumpFor(tester, const Duration(seconds: 10));
    }
    await _shot(tester, 'inicio-sincronizado');
    // La fila de la lista (un `ListTile` con el chip de estado) abre el detalle.
    await _tapVisible(tester, find.ancestor(of: _chip('Sincronizado').first, matching: find.byType(ListTile)).first);
    await _pumpUntil(tester, find.text('Cantidades'));
    await tester.ensureVisible(find.text('Cantidades'));
    await tester.pump();
    await _shot(tester, 'detalle-registro');
    await _back(tester, find.text('Cantidades'));
    await _pumpUntil(tester, find.byKey(const Key('home_new_record_button')));
    _mark('SYNCED');

    // El script valida el registro; la tarea lo muestra tras sincronizar.
    final validated = DateTime.now().add(const Duration(seconds: 180));
    while (true) {
      await _tapVisible(tester, find.byKey(const Key('home_sync_button')));
      await _pumpFor(tester, const Duration(seconds: 10));
      await _tapVisible(tester, find.byKey(const Key('home_new_record_button')));
      await _pumpUntil(tester, find.byKey(const Key('capture_save_button')));
      await _pickExcavation(tester);
      await _pumpUntil(tester, find.textContaining('Planeado 100 m3'));
      if (find.textContaining('validado 12,5 m3').evaluate().isNotEmpty) break;
      if (DateTime.now().isAfter(validated)) fail('La tarea no mostró lo validado en 180 s');
      await _back(tester, find.byKey(const Key('capture_save_button')));
      await _pumpUntil(tester, find.byKey(const Key('home_new_record_button')));
    }
    await tester.ensureVisible(find.textContaining('validado 12,5 m3'));
    await tester.pump();
    await _shot(tester, 'tarea-validada');
    _mark('VALIDATED_SEEN');
    await _back(tester, find.byKey(const Key('capture_save_button')));
    await _pumpUntil(tester, find.byKey(const Key('home_new_record_button')));

    // Rechazo y corrección: el script vuelve capítulo el 1.2 en el servidor; el teléfono
    // todavía lo tiene en su catálogo, así que el registro sale y vuelve rechazado
    // (`item_not_in_project`). Se corrige en "Para revisar" pasando la fila al 1.1.
    _mark('BREAK_ITEM');
    await _pumpFor(tester, const Duration(seconds: 20));
    await _tapVisible(tester, find.byKey(const Key('home_new_record_button')));
    await _pumpUntil(tester, find.byKey(const Key('capture_save_button')));
    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey('form-field-notas')), matching: find.byType(TextField)),
      '$_marker-r',
    );
    await _pickExcavation(tester);
    await _tapVisible(tester, find.byKey(const Key('quantity_add_unplanned')));
    await _pumpUntil(tester, find.byKey(const Key('quantity_item_search')));
    await _tapVisible(tester, find.textContaining('Retiro de sobrantes'));
    await _pumpUntil(tester, find.text('No planeado en esta tarea'));
    await tester.enterText(_byKeyPrefix('quantity_field-').last, '2');
    await tester.enterText(_byKeyPrefix('quantity_note-').last, 'rechazo E2E');
    await tester.pump();
    await _tapVisible(tester, find.byKey(const Key('capture_save_button')));
    await _pumpUntil(tester, find.byKey(const Key('home_new_record_button')));

    final rejected = DateTime.now().add(const Duration(seconds: 120));
    while (find.byKey(const Key('home_review_button')).evaluate().isEmpty) {
      if (DateTime.now().isAfter(rejected)) fail('El registro no llegó a "Para revisar" en 120 s');
      await _tapVisible(tester, find.byKey(const Key('home_sync_button')));
      await _pumpFor(tester, const Duration(seconds: 10));
    }
    // Una sincronización más: el catálogo ya sin el 1.2 señala la fila.
    await _tapVisible(tester, find.byKey(const Key('home_sync_button')));
    await _pumpFor(tester, const Duration(seconds: 10));
    await _tapVisible(tester, find.byKey(const Key('home_review_button')));
    await _pumpUntil(tester, find.byKey(const Key('review_correct_quantities')));
    await _pumpUntil(tester, find.textContaining('Fila del ítem 1.2'));
    await _shot(tester, 'revision-rechazo');
    await _tapVisible(tester, find.byKey(const Key('review_correct_quantities')));
    await _pumpUntil(tester, find.byKey(const Key('quantity_correction_save')));
    await _pumpUntil(tester, _byKeyPrefix('quantity_reassign-'));
    await tester.ensureVisible(_byKeyPrefix('quantity_reassign-').first);
    await tester.pump();
    await _shot(tester, 'correccion-cantidades');
    await _tapVisible(tester, _byKeyPrefix('quantity_reassign-').first);
    await _pumpUntil(tester, find.byKey(const Key('quantity_item_search')));
    await _tapVisible(tester, find.textContaining('Excavación mecánica').last);
    await _pumpFor(tester, const Duration(seconds: 1));
    await _tapVisible(tester, find.byKey(const Key('quantity_correction_save')));
    await _pumpUntil(tester, find.byKey(const Key('review_empty')));
    await _back(tester, find.byKey(const Key('review_empty')));
    await _pumpUntil(tester, find.byKey(const Key('home_new_record_button')));

    final corrected = DateTime.now().add(const Duration(seconds: 120));
    while (_chip('Sincronizado').evaluate().length < 2) {
      if (DateTime.now().isAfter(corrected)) fail('El registro corregido no pasó a Sincronizado en 120 s');
      await _tapVisible(tester, find.byKey(const Key('home_sync_button')));
      await _pumpFor(tester, const Duration(seconds: 10));
    }
    _mark('CORRECTED');
  });
}

/// Cierra la pantalla que contiene [inside].
Future<void> _back(WidgetTester tester, Finder inside) async {
  await Navigator.of(tester.element(inside.first)).maybePop();
  await tester.pump();
}

Future<void> _pickExcavation(WidgetTester tester) async {
  await _tapVisible(tester, find.byKey(const Key('capture_task_picker')));
  await _pumpUntil(tester, find.byKey(const Key('task_picker_search')));
  await tester.enterText(find.byKey(const Key('task_picker_search')), 'excav');
  await tester.pump();
  await _tapVisible(tester, find.text('1.1 Excavación'));
  await _pumpUntil(tester, find.byKey(const Key('quantity_section')));
}

Finder _byKeyPrefix(String prefix) => find.byWidgetPredicate(
  (widget) => widget.key is ValueKey<String> && (widget.key! as ValueKey<String>).value.startsWith(prefix),
);

Finder _chip(String label) => find.descendant(of: find.byType(RecordStatusChip), matching: find.text(label));

/// Hace visible el widget antes de tocarlo y espera (hasta 10 s) a que el
/// toque le llegue de verdad: un SnackBar abierto puede quedar sobre
/// el teclado y tapar el botón hasta que se cierra.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 100));
    final target = tester.renderObject(finder);
    final hits = tester.hitTestOnBinding(tester.getCenter(finder)).path;
    if (hits.any((entry) => entry.target == target) || DateTime.now().isAfter(deadline)) break;
  }
  await tester.tap(finder);
  await tester.pump();
}

void _mark(String name) {
  // ignore: avoid_print
  print('E2E:$name');
}

/// Pide al script una captura de pantalla y le da tiempo de tomarla.
Future<void> _shot(WidgetTester tester, String name) async {
  _mark('SHOT:$name');
  await _pumpFor(tester, const Duration(seconds: 3));
}

/// `pumpAndSettle` no sirve: los temporizadores de sincronización y las
/// animaciones de carga nunca dejan la app quieta.
Future<void> _pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) =>
    _pumpUntilAny(tester, [finder], timeout: timeout);

Future<void> _pumpUntilAny(
  WidgetTester tester,
  List<Finder> finders, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!finders.any((f) => f.evaluate().isNotEmpty)) {
    if (DateTime.now().isAfter(deadline)) fail('No apareció ninguno de $finders en $timeout');
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _pumpFor(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}
