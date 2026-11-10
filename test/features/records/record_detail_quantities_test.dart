// Costos, pieza 4b: el detalle del registro muestra sus cantidades, una por bloque
// (ítem; cantidad con unidad; ubicación; nota), sin desbordar a 390 px.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/app_dependencies.dart';
import 'package:suno/core/auth/auth_controller.dart';
import 'package:suno/core/auth/auth_models.dart';
import 'package:suno/core/auth/auth_result.dart';
import 'package:suno/core/providers.dart';
import 'package:suno/data/local/database.dart';
import 'package:suno/features/records/record_detail_screen.dart';

import '../../core/auth/fake_auth_transport.dart';
import '../../core/auth/fake_token_store.dart';
import '../../support/test_app.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  testWidgets('muestra las cantidades del registro', (tester) async {
    final auth = AuthController(
      transport: FakeAuthTransport()
        ..loginResponses.add(
          AuthResult.ok(
            LoginResponse(
              tokens: TokenPair(
                accessToken: 'a',
                tokenType: 'Bearer',
                expiresIn: 900,
                refreshToken: 'r',
                refreshExpiresIn: 3600,
                serverTime: DateTime.utc(2026, 11, 9),
              ),
              user: const UserProfile(id: 'user-1', username: 'agente1', orgId: 'org-1', roles: ['agent']),
            ),
          ),
        ),
      tokenStore: FakeTokenStore(),
      deviceId: 'device-1',
    );
    await auth.login(
      username: 'agente1',
      password: 'x',
      deviceInfo: const DeviceInfo(deviceId: 'device-1', platform: 'android', appVersion: '1.0.0'),
    );
    final dependencies = AppDependencies(database: db, dio: Dio(), authController: auth, deviceId: 'device-1');
    await db
        .into(db.knownItems)
        .insert(KnownItemsCompanion.insert(itemId: 'item-1', code: '2.1', description: 'Concreto zapatas', unit: 'm3'));
    await db
        .into(db.records)
        .insert(
          RecordsCompanion.insert(
            id: 'record-1',
            orgId: 'org-1',
            version: 1,
            templateVersionId: 'tv-1',
            answersJson: '{}',
            capturedAt: DateTime.utc(2026, 11, 9, 15),
            deviceId: 'device-1',
            createdBy: 'user-1',
            taskId: const Value('task-1'),
            quantitiesJson: Value(
              jsonEncode([
                {'item_id': 'item-1', 'location_id': null, 'quantity': 12.5, 'note': 'frente norte'},
                {'item_id': 'item-7', 'location_id': 'loc-x', 'quantity': -1, 'note': 'ajuste'},
              ]),
            ),
          ),
        );
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
        child: testApp(const RecordDetailScreen(recordId: 'record-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cantidades'), findsOneWidget);
    expect(find.text('2.1 Concreto zapatas'), findsOneWidget);
    expect(find.text('12,5 m3'), findsOneWidget);
    expect(find.text('Ubicación: La de la tarea'), findsOneWidget);
    expect(find.text('Nota: frente norte'), findsOneWidget);
    expect(find.text('item-7'), findsOneWidget, reason: 'sin datos del ítem, su id');
    expect(find.text('-1'), findsOneWidget);
    expect(find.text('Ubicación: Ubicación precisada'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
