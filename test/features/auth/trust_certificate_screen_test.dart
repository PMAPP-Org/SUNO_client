// Paso 16, verificación del plan: el diálogo TOFU muestra la información
// completa (huella, CN, SAN, emisor, validez) y no hay ningún botón de
// "aceptar" preseleccionado ni accesible sin una acción deliberada.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/security/certificate_info.dart';
import 'package:visitacampo/core/security/pin_store.dart';
import 'package:visitacampo/core/security/trust_store.dart';
import 'package:visitacampo/features/auth/trust_certificate_screen.dart';

import '../../support/test_app.dart';

const _fingerprint =
    'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';

final _certificate = CertificateInfo(
  spkiSha256: 'pin',
  sha256Fingerprint: _fingerprint,
  subject: '/O=Finca/CN=campo.example',
  issuer: '/CN=CA de la finca',
  subjectAltNames: const ['campo.example', '10.0.0.5'],
  notBefore: DateTime.utc(2026, 1, 10),
  notAfter: DateTime.utc(2027, 1, 10),
);

/// Abre el diálogo desde un botón, como lo hace el login, y devuelve la
/// decisión que el diálogo entregó al cerrarse.
Future<List<bool>> _open(
  WidgetTester tester,
  CertificateRejection rejection, {
  DateTime? now,
}) async {
  final decisions = <bool>[];
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final trusted = await Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                fullscreenDialog: true,
                builder: (_) => TrustCertificateScreen(
                  rejection: rejection,
                  now: now == null ? null : () => now,
                ),
              ),
            );
            decisions.add(trusted ?? false);
          },
          child: const Text('abrir'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return decisions;
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) => tester
    .scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);

void main() {
  final untrusted = UntrustedCertificate('campo.example', 8443, _certificate);

  testWidgets('muestra huella, CN, SAN, emisor, validez y el servidor', (
    tester,
  ) async {
    await _open(tester, untrusted, now: DateTime.utc(2026, 6));

    expect(find.textContaining('campo.example:8443'), findsOneWidget);
    expect(find.text(_fingerprint), findsOneWidget);
    expect(find.text('campo.example'), findsOneWidget); // CN
    expect(find.text('campo.example, 10.0.0.5'), findsOneWidget);
    expect(find.text('/CN=CA de la finca'), findsOneWidget);
    expect(find.textContaining('2026'), findsWidgets);
    expect(find.byKey(const Key('tofu_not_valid_now')), findsNothing);
  });

  testWidgets(
    '"Confiar" está deshabilitado hasta confirmar que se comparó la huella',
    (tester) async {
      final decisions = await _open(
        tester,
        untrusted,
        now: DateTime.utc(2026, 6),
      );
      final trust = find.byKey(const Key('tofu_trust_button'));
      await _scrollTo(tester, trust);

      expect(tester.widget<OutlinedButton>(trust).onPressed, isNull);
      await tester.tap(trust);
      await tester.pumpAndSettle();
      expect(
        decisions,
        isEmpty,
        reason: 'un toque en el botón deshabilitado no decide nada',
      );

      await tester.tap(find.byKey(const Key('tofu_compared_check')));
      await tester.pumpAndSettle();
      await tester.tap(trust);
      await tester.pumpAndSettle();
      expect(decisions, [true]);
    },
  );

  testWidgets('cerrar o "No confiar" devuelve false', (tester) async {
    final decisions = await _open(tester, untrusted);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    final cancel = find.byKey(const Key('tofu_cancel_button'));
    await _scrollTo(tester, cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    expect(decisions, [false, false]);
  });

  testWidgets(
    'certificado cambiado: advertencia reforzada con la fecha de la aprobación anterior',
    (tester) async {
      final changed = CertificateChanged(
        'campo.example',
        8443,
        _certificate,
        previous: HostPin(
          host: 'campo.example',
          port: 8443,
          spkiSha256: 'otro',
          subject: '/CN=campo.example',
          approvedAt: DateTime.utc(2026, 3, 2, 12),
        ),
      );
      await _open(tester, changed, now: DateTime.utc(2026, 6));

      expect(find.textContaining('CAMBIÓ'), findsOneWidget);
      expect(find.textContaining('2026'), findsWidgets);
    },
  );

  testWidgets('avisa si el certificado no está vigente hoy', (tester) async {
    await _open(tester, untrusted, now: DateTime.utc(2028));
    expect(find.byKey(const Key('tofu_not_valid_now')), findsOneWidget);
  });
}
