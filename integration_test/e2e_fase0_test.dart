// Prueba E2E de la Fase 0 (Paso 14). La ejecuta `tool/e2e.sh`, que levanta
// el servidor, controla el modo avión y verifica el resultado en el servidor.
// No funciona sola: necesita los --dart-define que pasa el script.
//
// Coordinación con el script por `adb logcat` (tag `flutter`):
//   E2E:READY_FOR_OFFLINE  → el script activa el modo avión
//   E2E:SAVED_OFFLINE      → el script lo desactiva
//   E2E:SYNCED             → el script verifica en el servidor
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:visitacampo/features/home/visit_status_list.dart';
import 'package:visitacampo/main.dart' as app;

const _username = String.fromEnvironment('E2E_USERNAME');
const _password = String.fromEnvironment('E2E_PASSWORD');
const _marker = String.fromEnvironment('E2E_MARKER');
const _host = String.fromEnvironment('E2E_HOST', defaultValue: '10.0.2.2');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('una visita creada en modo avión llega al servidor al reconectar', (tester) async {
    expect(
      _username.isNotEmpty && _password.isNotEmpty && _marker.isNotEmpty,
      isTrue,
      reason: 'Ejecutar con tool/e2e.sh: faltan E2E_USERNAME/E2E_PASSWORD/E2E_MARKER',
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
    await tester.pump();
    await _tapVisible(tester, find.byKey(const Key('tofu_trust_button')));
    await _pumpUntil(tester, find.byKey(const Key('home_new_visit_button')), timeout: const Duration(seconds: 60));

    // Sincronización inicial: trae la plantilla publicada.
    await _tapVisible(tester, find.byKey(const Key('home_sync_button')));
    await _pumpUntil(tester, find.byKey(const Key('home_last_sync')), timeout: const Duration(seconds: 60));

    // Sin red.
    _mark('READY_FOR_OFFLINE');
    await _waitUntilOffline(tester);

    // Captura offline.
    await _tapVisible(tester, find.byKey(const Key('home_new_visit_button')));
    await _pumpUntil(tester, find.byKey(const Key('capture_save_button')));
    final notas = find.descendant(of: find.byKey(const ValueKey('form-field-notas')), matching: find.byType(TextField));
    await tester.enterText(notas, _marker);
    await _tapVisible(tester, find.byKey(const Key('capture_save_button')));
    await _pumpUntil(tester, find.byKey(const Key('home_new_visit_button')));
    await _pumpUntil(tester, _chip('Pendiente'));
    _mark('SAVED_OFFLINE');

    // Con red: sincroniza hasta que la visita quede confirmada.
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (_chip('Sincronizada').evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('La visita no pasó a Sincronizada en 120 s');
      await _tapVisible(tester, find.byKey(const Key('home_sync_button')));
      await _pumpFor(tester, const Duration(seconds: 10));
    }
    _mark('SYNCED');
  });
}

Finder _chip(String label) => find.descendant(of: find.byType(VisitStatusChip), matching: find.text(label));

/// Las casillas del aviso y el botón de guardar pueden quedar fuera de pantalla.
Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

void _mark(String name) {
  // ignore: avoid_print
  print('E2E:$name');
}

/// La propia prueba comprueba que el modo avión ya está activo: ningún
/// paquete llega al host.
Future<void> _waitUntilOffline(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (true) {
    // La excepción se captura dentro: `runAsync` informa al framework de lo
    // que escapa del callback y la prueba fallaría.
    final reachable = await tester.runAsync(() async {
      try {
        (await Socket.connect(_host, 443, timeout: const Duration(seconds: 2))).destroy();
        return true;
      } on SocketException {
        return false;
      }
    });
    if (reachable == false) return;
    if (DateTime.now().isAfter(deadline)) fail('El host seguía accesible tras 60 s: ¿modo avión?');
    await _pumpFor(tester, const Duration(seconds: 1));
  }
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
