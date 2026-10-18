// Diálogo de confianza TOFU a pantalla completa (Paso 16, tarea 3; ADR-009).
//
// Se muestra cuando `TrustStore` rechaza un certificado aprobable de un
// servidor autohospedado. Requisitos del plan, todos aquí:
// - información completa: huella SHA-256, CN, SAN, emisor y validez;
// - advertencia de riesgo en lenguaje claro (más fuerte si el certificado
//   **cambió** respecto al aprobado antes);
// - **confirmación deliberada**: el botón de confiar está deshabilitado hasta
//   marcar que se comparó la huella, y la acción por defecto (el botón
//   destacado, y "atrás") es no confiar.
//
// La pantalla solo devuelve la decisión (`true` = confiar); guardar el pin es
// de `TrustStore.approve`, en quien la abre.
import 'package:flutter/material.dart';

import '../../core/security/trust_store.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';

class TrustCertificateScreen extends StatefulWidget {
  const TrustCertificateScreen({required this.rejection, this.now, super.key});

  /// Un rechazo aprobable (`rejection.approvable`), con su certificado.
  final CertificateRejection rejection;

  /// Reloj inyectable para los tests de vigencia.
  final DateTime Function()? now;

  /// Abre el diálogo y devuelve `true` solo si el usuario confió.
  static Future<bool> show(
    BuildContext context,
    CertificateRejection rejection,
  ) async {
    final trusted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (_) => TrustCertificateScreen(rejection: rejection),
      ),
    );
    return trusted ?? false;
  }

  @override
  State<TrustCertificateScreen> createState() => _TrustCertificateScreenState();
}

class _TrustCertificateScreenState extends State<TrustCertificateScreen> {
  bool _compared = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final material = MaterialLocalizations.of(context);
    final rejection = widget.rejection;
    final certificate = rejection.certificate!;
    final server = '${rejection.host}:${rejection.port}';
    final now = (widget.now ?? DateTime.now)().toUtc();

    final intro = switch (rejection) {
      CertificateChanged(:final previous) => l10n.tofuChangedIntro(
        server,
        material.formatShortDate(previous.approvedAt.toLocal()),
      ),
      _ => l10n.tofuIntro(server),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tofuTitle),
        leading: CloseButton(onPressed: () => Navigator.of(context).pop(false)),
      ),
      body: AppPageBody(
        children: [
          Text(
            intro,
            key: const Key('tofu_warning'),
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
          const AppGap.sm(),
          Text(l10n.tofuInstruction, style: theme.textTheme.bodyMedium),
          const AppGap.lg(),
          _Field(
            label: l10n.tofuFingerprint,
            value: certificate.sha256Fingerprint,
            valueKey: const Key('tofu_fingerprint'),
            monospace: true,
          ),
          _Field(label: l10n.tofuSubject, value: certificate.commonName),
          _Field(
            label: l10n.tofuAltNames,
            value: certificate.subjectAltNames.isEmpty
                ? l10n.tofuNone
                : certificate.subjectAltNames.join(', '),
          ),
          _Field(label: l10n.tofuIssuer, value: certificate.issuer),
          _Field(
            label: l10n.tofuValidity,
            value: l10n.tofuValidityRange(
              material.formatShortDate(certificate.notBefore.toLocal()),
              material.formatShortDate(certificate.notAfter.toLocal()),
            ),
          ),
          if (!certificate.isValidAt(now))
            Text(
              l10n.tofuNotValidNow,
              key: const Key('tofu_not_valid_now'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          const AppGap.lg(),
          CheckboxListTile(
            key: const Key('tofu_compared_check'),
            value: _compared,
            onChanged: (value) => setState(() => _compared = value ?? false),
            title: Text(l10n.tofuConfirmCheck),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
          ),
          const AppGap.lg(),
          // La acción destacada es NO confiar.
          AppButton(
            key: const Key('tofu_cancel_button'),
            label: l10n.tofuCancel,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          const AppGap.sm(),
          OutlinedButton(
            key: const Key('tofu_trust_button'),
            onPressed: _compared ? () => Navigator.of(context).pop(true) : null,
            child: Text(l10n.tofuTrust),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.value,
    this.valueKey,
    this.monospace = false,
  });

  final String label;
  final String value;
  final Key? valueKey;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelLarge),
          SelectableText(
            value,
            key: valueKey,
            style: monospace
                ? theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace')
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
