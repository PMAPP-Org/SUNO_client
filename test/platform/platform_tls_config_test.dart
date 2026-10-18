// Paso 16, tareas 4 y 5: la configuración TLS de cada plataforma, vigilada.
// Un cambio que permita tráfico en claro, CAs del usuario o excepciones de
// ATS rompe este test en vez de pasar desapercibido en un diff de XML.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Android', () {
    test(
      'el manifest usa network_security_config y prohíbe el texto plano y los backups',
      () {
        final manifest = _read('android/app/src/main/AndroidManifest.xml');
        expect(
          manifest,
          contains(
            'android:networkSecurityConfig="@xml/network_security_config"',
          ),
        );
        expect(manifest, contains('android:usesCleartextTraffic="false"'));
        expect(manifest, contains('android:allowBackup="false"'));
      },
    );

    test('network_security_config: sin texto plano y solo CAs del sistema', () {
      final config = _read(
        'android/app/src/main/res/xml/network_security_config.xml',
      );
      final withoutComments = config.replaceAll(
        RegExp(r'<!--.*?-->', dotAll: true),
        '',
      );
      expect(withoutComments, contains('cleartextTrafficPermitted="false"'));
      expect(
        withoutComments,
        isNot(contains('cleartextTrafficPermitted="true"')),
      );
      expect(withoutComments, contains('<certificates src="system" />'));
      expect(
        withoutComments,
        isNot(contains('src="user"')),
        reason: 'nada de CAs instaladas por el usuario',
      );
      expect(withoutComments, isNot(contains('<debug-overrides')));
      expect(
        withoutComments,
        isNot(contains('<domain-config')),
        reason: 'ninguna excepción por dominio',
      );
    });
  });

  test('iOS: App Transport Security sin excepciones', () {
    final plist = _read('ios/Runner/Info.plist');
    for (final relaxation in [
      'NSAllowsArbitraryLoads',
      'NSAllowsArbitraryLoadsInWebContent',
      'NSAllowsArbitraryLoadsForMedia',
      'NSAllowsLocalNetworking',
      'NSExceptionDomains',
      'NSExceptionAllowsInsecureHTTPLoads',
      'NSExceptionMinimumTLSVersion',
    ]) {
      expect(
        plist,
        isNot(contains(relaxation)),
        reason: '$relaxation relajaría ATS',
      );
    }
  });
}
