// Costos, etapa 1: selector "Tarea del cronograma" (búsqueda por EDT o nombre)
// y "% avance acumulado" con el último validado como referencia.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/data/local/schedule_task_repository.dart';
import 'package:visitacampo/features/capture/task_progress_section.dart';

import '../../support/test_app.dart';

const _tasks = [
  ScheduleTaskItem(id: 't-2', projectName: 'Obra Norte', code: '1.1', name: 'Localización', lastValidatedPct: null),
  ScheduleTaskItem(id: 't-3', projectName: 'Obra Norte', code: '1.2', name: 'Descapote', lastValidatedPct: 40),
];

void main() {
  late TextEditingController controller;
  String? selected;
  final picks = <String?>[];

  setUp(() {
    controller = TextEditingController();
    selected = null;
    picks.clear();
  });
  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester, {String? errorText}) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListView(
              children: [
                TaskProgressSection(
                  tasks: _tasks,
                  selectedId: selected,
                  controller: controller,
                  errorText: errorText,
                  onSelected: (id) => setState(() {
                    selected = id;
                    picks.add(id);
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sin tarea: es opcional y no pide %', (tester) async {
    await pump(tester);
    expect(find.text('Sin tarea (opcional)'), findsOneWidget);
    expect(find.byKey(const Key('capture_progress_field')), findsNothing);
  });

  testWidgets('busca por EDT o nombre y elige la tarea', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('capture_task_picker')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('task_picker_search')), 'descap');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task_picker_item-t-2')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('task_picker_item-t-3')));
    await tester.pumpAndSettle();
    expect(picks, ['t-3']);
    expect(find.text('1.2 Descapote'), findsOneWidget);
    expect(find.text('Último validado: 40 %'), findsOneWidget);
  });

  testWidgets('un % menor que el último validado se avisa', (tester) async {
    selected = 't-3';
    await pump(tester);
    await tester.enterText(find.byKey(const Key('capture_progress_field')), '35');
    await tester.pump();
    expect(find.byKey(const Key('capture_progress_below')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('capture_progress_field')), '45');
    await tester.pump();
    expect(find.byKey(const Key('capture_progress_below')), findsNothing);
  });

  testWidgets('"Sin tarea" la quita', (tester) async {
    selected = 't-2';
    await pump(tester);
    expect(find.text('Sin avance validado todavía.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('capture_task_picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task_picker_none')));
    await tester.pumpAndSettle();
    expect(picks, [null]);
  });

  testWidgets('muestra el error que le pasa la pantalla', (tester) async {
    selected = 't-2';
    await pump(tester, errorText: 'Indica el % de avance acumulado.');
    expect(find.text('Indica el % de avance acumulado.'), findsOneWidget);
  });
}
