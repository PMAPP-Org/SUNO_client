// Paso 16, regresión de H-10 (doc 07): QField guardaba sus cookies en una
// clave sin interpolar y cada una pisaba la anterior. Aquí: aprobar pines
// para tres servidores, "reiniciar" la app (instancias nuevas sobre el mismo
// almacenamiento) y comprobar que los tres siguen, cada uno el suyo.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/security/certificate_info.dart';
import 'package:visitacampo/core/security/pin_store.dart';
import 'package:visitacampo/core/security/secure_storage.dart';
import 'package:visitacampo/core/security/trust_store.dart';

import 'fake_keychain.dart';

CertificateInfo _cert(String spki) => CertificateInfo(
  spkiSha256: spki,
  sha256Fingerprint: 'AB',
  subject: '/CN=$spki',
  issuer: '/CN=$spki',
  subjectAltNames: const [],
  notBefore: DateTime.utc(2026),
  notAfter: DateTime.utc(2027),
);

void main() {
  late FakeKeychain keychain;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    keychain = FakeKeychain()..install();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  TrustStore freshApp() => TrustStore(
    pinStore: PinStore(HardenedSecureStorage(migrateLegacy: true)),
  );

  test('tres hosts aprobados persisten tras reiniciar, sin pisarse', () async {
    final session = freshApp();
    await session.approve('campo-a.example', 443, _cert('pin-a'));
    await session.approve('campo-b.example', 443, _cert('pin-b'));
    await session.approve('campo-a.example', 8443, _cert('pin-a-8443'));

    final restarted = freshApp();
    expect(
      restarted.approvedPins,
      isEmpty,
      reason: 'antes de load() no hay nada en memoria',
    );
    await restarted.load();

    final pins = restarted.approvedPins.map(
      (key, pin) => MapEntry(key, pin.spkiSha256),
    );
    expect(pins, {
      'campo-a.example:443': 'pin-a',
      'campo-b.example:443': 'pin-b',
      'campo-a.example:8443': 'pin-a-8443',
    });
    expect(
      keychain.items.keys,
      everyElement(
        startsWith('first_unlock_this_device|visitacampo.tls_pin.v1.'),
      ),
    );
  });

  test('re-aprobar un host sustituye solo su pin', () async {
    final session = freshApp();
    await session.approve('campo-a.example', 443, _cert('viejo'));
    await session.approve('campo-b.example', 443, _cert('pin-b'));
    await session.approve('CAMPO-A.example', 443, _cert('nuevo'));

    final restarted = freshApp();
    await restarted.load();
    expect(restarted.approvedPins['campo-a.example:443']!.spkiSha256, 'nuevo');
    expect(restarted.approvedPins['campo-b.example:443']!.spkiSha256, 'pin-b');
  });

  test('olvidar un host no toca los demás ni otros secretos', () async {
    await HardenedSecureStorage(
      migrateLegacy: true,
    ).write(key: 'visitacampo.db_key', value: 'x');
    final session = freshApp();
    await session.approve('campo-a.example', 443, _cert('a'));
    await session.approve('campo-b.example', 443, _cert('b'));
    await session.forget('campo-a.example', 443);

    final restarted = freshApp();
    await restarted.load();
    expect(restarted.approvedPins.keys, ['campo-b.example:443']);
    expect(keychain.items['first_unlock_this_device|visitacampo.db_key'], 'x');
  });

  test(
    'una entrada corrupta se ignora: ese host vuelve a pedir aprobación',
    () async {
      await HardenedSecureStorage(
        migrateLegacy: true,
      ).write(key: 'visitacampo.tls_pin.v1.roto:443', value: '{no-json');
      final restarted = freshApp();
      await restarted.load();
      expect(restarted.approvedPins, isEmpty);
    },
  );

  test('CertificateInfo lee CN y validez', () {
    final info = _cert('x');
    expect(info.commonName, 'x');
    expect(info.isValidAt(DateTime.utc(2026, 6)), isTrue);
    expect(info.isValidAt(DateTime.utc(2028)), isFalse);
    expect(
      () => CertificateInfo.fromDer(
        Uint8List.fromList([1, 2, 3]),
        subject: '',
        issuer: '',
        notBefore: DateTime.utc(2026),
        notAfter: DateTime.utc(2027),
      ),
      throwsFormatException,
    );
  });
}
