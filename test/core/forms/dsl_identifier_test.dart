// El identificador del dialecto cambió con el renombrado del servidor
// (`visitacampo/form@1` → `suno/form@1`): el cliente adopta el nuevo y sigue
// leyendo el viejo, que es el de las plantillas ya guardadas en el teléfono.
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/forms/form_definition.dart';

Map<String, Object?> _template(String dsl) => {
  'dsl': dsl,
  'fields': [
    {
      'key': 'nota',
      'type': 'text',
      'label': {'es': 'Nota'},
    },
  ],
};

void main() {
  test('el dialecto actual es el del servidor', () {
    expect(dslVersion, 'suno/form@1');
    expect(parseFormDefinition(_template('suno/form@1')), isA<DefinitionOk>());
  });

  test('las plantillas guardadas con el identificador anterior se siguen leyendo', () {
    expect(parseFormDefinition(_template('visitacampo/form@1')), isA<DefinitionOk>());
  });

  test('un dialecto desconocido o futuro se rechaza, con cualquiera de los dos prefijos', () {
    for (final dsl in ['suno/form@2', 'visitacampo/form@2', 'otro/form@1']) {
      expect(parseFormDefinition(_template(dsl)), isNot(isA<DefinitionOk>()), reason: dsl);
    }
  });
}
