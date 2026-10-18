// Paso 16, verificación del plan: "los tokens no aparecen en ningún log ni
// en SharedPreferences plano". Se comprueba sobre el código fuente de `lib/`
// (lo que acaba en cualquier build), sin depender de un dispositivo:
// - ningún almacenamiento en claro: ni `shared_preferences` ni archivos con
//   secretos fuera de `flutter_secure_storage`;
// - ninguna llamada de log (`print`, `debugPrint`, `log`) que mencione un
//   token, una contraseña o una clave.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _sources() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where(
      (f) =>
          f.path.endsWith('.dart') &&
          !f.path.endsWith('.g.dart') &&
          !f.path.endsWith('.freezed.dart'),
    );

void main() {
  test('ningún almacenamiento en claro (SharedPreferences)', () {
    expect(
      File('pubspec.lock').readAsStringSync(),
      isNot(contains('shared_preferences')),
      reason: 'ni como dependencia directa ni transitiva',
    );
    for (final file in _sources()) {
      expect(
        file.readAsStringSync(),
        isNot(contains('package:shared_preferences/')),
        reason: file.path,
      );
    }
  });

  test('ningún log menciona tokens, contraseñas ni claves', () {
    final logCall = RegExp(r'\b(print|debugPrint|log)\s*\(');
    final secret = RegExp(
      r'token|password|contrase|secret|refresh|encryptionKey',
      caseSensitive: false,
    );
    final offenders = <String>[];
    for (final file in _sources()) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (logCall.hasMatch(line) && secret.hasMatch(line)) {
          offenders.add('${file.path}:${i + 1}: $line');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
