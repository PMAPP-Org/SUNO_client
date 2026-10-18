// Paso 16, tarea 6: secretos en el Keychain con
// `first_unlock_this_device`, y migración de los escritos antes con la
// accesibilidad por defecto (perder la clave de SQLCipher dejaría la BD local
// —outbox incluida— ilegible).
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/security/secure_storage.dart';

import 'fake_keychain.dart';

void main() {
  late FakeKeychain keychain;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    keychain = FakeKeychain()..install();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'escribe con "after first unlock, this device only" y sin iCloud',
    () async {
      await HardenedSecureStorage(
        migrateLegacy: true,
      ).write(key: 'k', value: 'v');

      expect(keychain.items, {'first_unlock_this_device|k': 'v'});
      expect(kHardenedAppleOptions.params['synchronizable'], 'false');
    },
  );

  test(
    'un secreto de antes del Paso 16 se lee, se reescribe endurecido y se borra el antiguo',
    () async {
      // Escrito como lo hacía la app hasta ahora: `FlutterSecureStorage()`.
      await const FlutterSecureStorage().write(key: 'db_key', value: 'secreto');
      expect(keychain.items.keys.single, startsWith('unlocked|'));

      final storage = HardenedSecureStorage(migrateLegacy: true);
      expect(await storage.read(key: 'db_key'), 'secreto');
      expect(keychain.items, {'first_unlock_this_device|db_key': 'secreto'});

      // La segunda lectura ya no necesita migrar.
      expect(await storage.read(key: 'db_key'), 'secreto');
    },
  );

  test(
    'una clave que no existe en ninguno de los dos sigue siendo null',
    () async {
      expect(
        await HardenedSecureStorage(migrateLegacy: true).read(key: 'nada'),
        isNull,
      );
      expect(keychain.items, isEmpty);
    },
  );

  test('sin migración (Android), no se buscan entradas antiguas', () async {
    await const FlutterSecureStorage().write(key: 'k', value: 'v');
    expect(
      await HardenedSecureStorage(migrateLegacy: false).read(key: 'k'),
      isNull,
    );
  });
}
