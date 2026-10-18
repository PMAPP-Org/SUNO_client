// Almacenamiento seguro falso que, como el Keychain real, distingue la
// accesibilidad: un secreto escrito con `unlocked` no aparece al buscarlo con
// `first_unlock_this_device`. `TestFlutterSecureStoragePlatform` (el de
// `setMockInitialValues`) ignora las opciones, así que no serviría para
// probar la migración de `HardenedSecureStorage`.
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

class FakeKeychain extends TestFlutterSecureStoragePlatform {
  FakeKeychain() : super({});

  /// `accesibilidad|clave` → valor. Las mismas entradas sobreviven a un
  /// "reinicio de la app" mientras se reutilice esta instancia.
  final Map<String, String> items = {};

  static String _slot(String key, Map<String, String> options) =>
      '${options['accessibility'] ?? '-'}|$key';

  void install() => FlutterSecureStoragePlatform.instance = this;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => items[_slot(key, options)] = value;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => items[_slot(key, options)];

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => items.containsKey(_slot(key, options));

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => items.remove(_slot(key, options));

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    final prefix = '${options['accessibility'] ?? '-'}|';
    return {
      for (final MapEntry(:key, :value) in items.entries)
        if (key.startsWith(prefix)) key.substring(prefix.length): value,
    };
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      items.clear();
}
