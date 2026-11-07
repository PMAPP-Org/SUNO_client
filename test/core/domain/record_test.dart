// Humo del pipeline de codegen (freezed + json_serializable), Paso 10: si
// `build_runner` dejara de generar código correcto, este test es el primero
// en fallar, antes de que el dominio real del Paso 12 dependa de él.
import 'package:flutter_test/flutter_test.dart';
import 'package:suno/core/domain/record.dart';

void main() {
  group('Record (freezed + json_serializable)', () {
    final capturedAt = DateTime.utc(2026, 7, 30, 14, 5, 9);

    Record buildRecord({double? lat}) => Record(
      id: 'a1a1a1a1-0000-0000-0000-000000000000',
      orgId: 'b2b2b2b2-0000-0000-0000-000000000000',
      version: 1,
      changeSeq: 42,
      templateVersionId: 'c3c3c3c3-0000-0000-0000-000000000000',
      answers: const {'altura_cm': 12},
      lat: lat,
      capturedAt: capturedAt,
      deviceId: 'd4d4d4d4-0000-0000-0000-000000000000',
      createdBy: 'e5e5e5e5-0000-0000-0000-000000000000',
    );

    test('copyWith produce una copia con el campo cambiado, no una mutación', () {
      final original = buildRecord(lat: 4.6);
      final moved = original.copyWith(lat: 4.7);

      expect(original.lat, 4.6, reason: 'copyWith no debe mutar el original');
      expect(moved.lat, 4.7);
    });

    test('== estructural: dos instancias con los mismos campos son iguales', () {
      expect(buildRecord(lat: 4.6), buildRecord(lat: 4.6));
    });

    test('toJson/fromJson hacen un roundtrip exacto', () {
      final record = buildRecord(lat: 4.6);
      final roundtripped = Record.fromJson(record.toJson());

      expect(roundtripped, record);
    });

    test('fromJson sin un campo requerido lanza, nunca produce un valor a medias', () {
      final incomplete = buildRecord(lat: 4.6).toJson()..remove('id');

      expect(() => Record.fromJson(incomplete), throwsA(isA<TypeError>()));
    });

    test(
      'fromJson entiende snake_case real del contrato (app/build.yaml: '
      'field_rename: snake) — regresión: un roundtrip contra sí mismo no '
      'detecta un desajuste consistente en ambas direcciones',
      () {
        final record = Record.fromJson({
          'id': 'a1a1a1a1-0000-0000-0000-000000000000',
          'org_id': 'b2b2b2b2-0000-0000-0000-000000000000',
          'version': 1,
          'change_seq': 42,
          'deleted_at': null,
          'template_version_id': 'c3c3c3c3-0000-0000-0000-000000000000',
          'answers': {'altura_cm': 12},
          'lat': 4.6,
          'lon': null,
          'accuracy_m': null,
          'altitude_m': null,
          'captured_at': capturedAt.toIso8601String(),
          'device_id': 'd4d4d4d4-0000-0000-0000-000000000000',
          'created_by': 'e5e5e5e5-0000-0000-0000-000000000000',
        });

        expect(record.orgId, 'b2b2b2b2-0000-0000-0000-000000000000');
        expect(record.changeSeq, 42);
        expect(record.templateVersionId, 'c3c3c3c3-0000-0000-0000-000000000000');
        expect(record.toJson(), containsPair('org_id', 'b2b2b2b2-0000-0000-0000-000000000000'));
      },
    );
  });
}
