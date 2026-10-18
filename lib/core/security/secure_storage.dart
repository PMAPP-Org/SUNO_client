// Almacenamiento seguro endurecido (Paso 16, tarea 6; cierra la deuda del
// Paso 13 anotada en `token_store.dart`).
//
// Guarda los secretos del dispositivo: la clave de SQLCipher (Paso 11), el
// id del dispositivo, el refresh token (Paso 13) y los pines TLS aprobados
// por el usuario (`pin_store.dart`).
//
// - **iOS/macOS**: Keychain con `first_unlock_this_device`
//   (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). "This device only":
//   el secreto no viaja en copias de iCloud/iTunes ni a otro teléfono
//   restaurado desde backup. "After first unlock" (y no `unlocked`): la
//   subida en segundo plano (Paso 18) y la sincronización tienen que poder
//   leer la clave de la BD con la pantalla bloqueada. `synchronizable:
//   false`: nada de iCloud Keychain.
// - **Android**: las opciones por defecto de `flutter_secure_storage` 10 ya
//   son las fuertes — clave AES-GCM envuelta con RSA-OAEP en el Android
//   Keystore. El plan nombraba `EncryptedSharedPreferences`, que Google y el
//   propio paquete han retirado (el paquete migra sus datos solo a este
//   esquema). Con `android:allowBackup="false"` y `dataExtractionRules`
//   (AndroidManifest) tampoco sale en backups.
//
// **Migración** (iOS): el Keychain incluye la accesibilidad en la consulta,
// así que un secreto escrito antes de este paso (accesibilidad por defecto,
// `unlocked`) no aparece al leer con la nueva. Perder así la clave de
// SQLCipher dejaría la BD local ilegible — outbox incluida. Por eso, si la
// lectura endurecida no encuentra la clave, se busca con las opciones
// antiguas y, si está, se reescribe endurecida y se borra la antigua.
import 'dart:io' show Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Opciones de Keychain de todos los secretos de la app.
const IOSOptions kHardenedAppleOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  synchronizable: false,
);

/// Las opciones con las que se escribía antes del Paso 16 (las por defecto).
const IOSOptions _legacyAppleOptions = IOSOptions.defaultOptions;

class HardenedSecureStorage extends FlutterSecureStorage {
  /// [migrateLegacy]: en tests se fuerza; en la app, solo en plataformas
  /// Apple (en Android las opciones de Keychain no existen y la lectura
  /// "antigua" sería la misma).
  HardenedSecureStorage({bool? migrateLegacy})
    : _migrateLegacy = migrateLegacy ?? (Platform.isIOS || Platform.isMacOS),
      super(iOptions: kHardenedAppleOptions, mOptions: kHardenedAppleOptions);

  final bool _migrateLegacy;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final value = await super.read(
      key: key,
      aOptions: aOptions,
      lOptions: lOptions,
      wOptions: wOptions,
    );
    if (value != null || !_migrateLegacy) return value;

    final legacy = await super.read(
      key: key,
      iOptions: _legacyAppleOptions,
      mOptions: _legacyAppleOptions,
    );
    if (legacy == null) return null;
    // Primero la copia endurecida, después el borrado: si la app muere entre
    // los dos pasos, el secreto sigue existiendo (dos veces), nunca cero.
    await super.write(key: key, value: legacy);
    await super.delete(
      key: key,
      iOptions: _legacyAppleOptions,
      mOptions: _legacyAppleOptions,
    );
    return legacy;
  }
}
