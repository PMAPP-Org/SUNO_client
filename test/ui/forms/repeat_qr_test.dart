import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/ui/forms/dynamic_form.dart';
import 'package:visitacampo/ui/forms/form_controller.dart';

import 'dynamic_form_test.dart' show FakeMedia, pumpForm;

class QrMedia extends FakeMedia implements FormQrDelegate {
  String? result = 'QR-CAPTURADO';
  @override
  Future<String?> scanQr() async => result;
}

FormDefinition definition() =>
    (parseFormDefinition({
              'fields': [
                {
                  'key': 'site',
                  'type': 'text',
                  'label': {'es': 'Sitio'},
                  'default': 'Bogotá',
                },
                {
                  'key': 'rows',
                  'type': 'repeat',
                  'label': {'es': 'Registros'},
                  'max_rows': 3,
                  'min_rows': 1,
                  'fields': [
                    {
                      'key': 'code',
                      'type': 'qr',
                      'label': {'es': 'Código'},
                      'required': true,
                    },
                    {
                      'key': 'name',
                      'type': 'text',
                      'label': {'es': 'Nombre'},
                      'default': 'Nuevo',
                    },
                  ],
                },
              ],
            })
            as DefinitionOk)
        .definition;

void main() {
  test('defaults only initialize new forms, cleared and edited values stay empty', () {
    final fresh = FormController(definition());
    expect(fresh.valueOf('site'), 'Bogotá');
    fresh.setAnswer('site', '');
    fresh.validate();
    expect(fresh.valueOf('site'), isNull);
    final edited = FormController(definition(), initialAnswers: {});
    expect(edited.valueOf('site'), isNull);
    fresh.dispose();
    edited.dispose();
  });

  testWidgets('add, scan, remove middle row, retain values and show nested errors', (tester) async {
    final controller = FormController(definition());
    final media = QrMedia();
    await pumpForm(tester, controller, media: media);
    expect(find.text('Bogotá'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Añadir registro'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Nombre').last, 'Fila $i');
    }
    final add = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Añadir registro'));
    expect(add.onPressed, isNull);
    await tester.tap(find.text('Escanear QR').first);
    await tester.pumpAndSettle();
    expect(find.text('QR-CAPTURADO'), findsOneWidget);
    expect(controller.validate(), isFalse);
    await tester.pump();
    expect(controller.displayedErrors.keys, containsAll(['rows.1.code', 'rows.2.code']));
    await tester.tap(find.byTooltip('Eliminar registro').at(1));
    await tester.pump();
    expect(find.text('Fila 1'), findsNothing);
    expect(find.text('Fila 2'), findsOneWidget);
    final rows = controller.valueOf('rows')! as List<Object?>;
    expect(rows.length, 2);
    expect((rows.last! as Map<String, Object?>)['name'], 'Fila 2');
    await tester.tap(find.text('Escanear QR').last);
    await tester.pumpAndSettle();
    expect(controller.validate(), isTrue);
    media.result = null;
    await tester.tap(find.text('Escanear QR').first);
    await tester.pumpAndSettle();
    expect(find.text('QR-CAPTURADO'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('existing rows do not acquire defaults and server paths remain actionable', (tester) async {
    final controller = FormController(
      definition(),
      initialAnswers: {
        'rows': [
          {'code': 'existing'},
        ],
      },
      serverErrors: {'rows.0.code': 'too_long'},
    );
    await pumpForm(tester, controller);
    expect(find.text('Nuevo'), findsNothing);
    expect(controller.validate(), isFalse);
    await tester.enterText(find.widgetWithText(TextField, 'Código *'), 'fixed');
    await tester.pump();
    expect(controller.validate(), isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
