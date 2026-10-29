import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/forms/form_definition.dart';
import 'package:visitacampo/ui/forms/form_controller.dart';

FormDefinition parse(Map<String, Object?> raw) => (parseFormDefinition(raw) as DefinitionOk).definition;

void main() {
  test('a hidden repeat that still holds rows does not block saving', () {
    final definition = parse({
      'fields': [
        {
          'key': 'enabled',
          'type': 'boolean',
          'label': {'es': 'Activo'},
        },
        {
          'key': 'rows',
          'type': 'repeat',
          'label': {'es': 'Filas'},
          'min_rows': 2,
          'visible_if': {'op': 'eq', 'field': 'enabled', 'value': true},
          'fields': [
            {
              'key': 'note',
              'type': 'text',
              'label': {'es': 'Nota'},
            },
          ],
        },
      ],
    });
    final controller = FormController(
      definition,
      initialAnswers: {
        'enabled': false,
        'rows': [
          {'note': 'a'},
        ],
      },
    );
    expect(controller.validate(), isTrue);
    controller.setAnswer('enabled', true);
    expect(controller.validate(), isFalse, reason: 'visible again: one row is below min_rows');
  });

  test('server errors on hidden or missing rows are dropped; reachable ones stay', () {
    final definition = parse({
      'fields': [
        {
          'key': 'rows',
          'type': 'repeat',
          'label': {'es': 'Filas'},
          'fields': [
            {
              'key': 'count',
              'type': 'integer',
              'label': {'es': 'Cantidad'},
            },
            {
              'key': 'note',
              'type': 'text',
              'label': {'es': 'Nota'},
              'visible_if': {'op': 'eq', 'field': 'count', 'value': 1},
            },
          ],
        },
      ],
    });
    final answers = {
      'rows': [
        {'count': 2},
      ],
    };
    final unreachable = FormController(
      definition,
      initialAnswers: answers,
      serverErrors: {'rows.0.note': 'required', 'rows.5.count': 'required', 'rows.x.count': 'required'},
    );
    expect(unreachable.validate(), isTrue);

    final reachable = FormController(
      definition,
      initialAnswers: answers,
      serverErrors: {'rows.0.count': 'out_of_range'},
    );
    expect(reachable.validate(), isFalse);
    expect(reachable.displayedErrors, containsPair('rows.0.count', 'out_of_range'));
  });

  test('errors inside a repeat point at the nested field', () {
    final result = parseFormDefinition({
      'fields': [
        {
          'key': 'a',
          'type': 'text',
          'label': {'es': 'A'},
        },
        {
          'key': 'rows',
          'type': 'repeat',
          'label': {'es': 'Filas'},
          'fields': [
            {
              'key': 'x',
              'type': 'text',
              'label': {'es': 'X'},
            },
            {
              'key': 'y',
              'type': 'nope',
              'label': {'es': 'Y'},
            },
          ],
        },
      ],
    });
    expect(result, isA<DefinitionInvalid>().having((r) => r.path, 'path', 'fields.1.fields.1.type'));
  });
}
