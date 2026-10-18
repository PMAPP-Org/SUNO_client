// "Mapas offline" (Fase B): lista lo que ofrece la organización, confirma el
// tamaño antes de descargar, y después lo muestra como descargado.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/app_dependencies.dart';
import 'package:visitacampo/core/auth/auth_controller.dart';
import 'package:visitacampo/core/basemaps/basemap_manager.dart';
import 'package:visitacampo/core/providers.dart';
import 'package:visitacampo/data/local/database.dart';
import 'package:visitacampo/features/basemaps/basemaps_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../core/basemaps/fake_basemap_transport.dart';
import '../../support/test_app.dart';

/// Espera a [finder] dejando correr la E/S real (archivos), que el reloj
/// simulado de los tests de widgets no avanza.
Future<void> waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(finder, findsWidgets);
}

void main() {
  late AppDatabase db;
  late Directory dir;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dir = Directory.systemTemp.createTempSync('basemaps-screen');
  });
  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('descargar pide confirmación con el tamaño y luego queda descargado', (tester) async {
    final bytes = List<int>.filled(3 * 1024 * 1024, 7);
    final transport = FakeBasemapTransport();
    final roble = info('roble', bytes);
    transport
      ..offered = [roble]
      ..contents['roble'] = bytes;
    final dependencies = AppDependencies(
      database: db,
      dio: Dio(),
      authController: AuthController(transport: FakeAuthTransport(), tokenStore: FakeTokenStore(), deviceId: 'd'),
      deviceId: 'd',
      basemaps: BasemapManager(transport: transport, directory: dir),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const BasemapsScreen()),
      ),
    );
    await waitFor(tester, find.text('Mapa roble'));
    expect(find.text('3 MB · zoom 10–16'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('basemap-download-roble')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ocupa 3 MB'), findsOneWidget);
    await tester.tap(find.byKey(const Key('basemap_download_confirm')));
    await waitFor(tester, find.byKey(const ValueKey('basemap-remove-roble')));
    expect((await tester.runAsync(dependencies.basemaps.downloaded))!.single.info.id, 'roble');
  });
}
