// Pantalla de login (Tarea 5 del plan de despliegue del demo). Conecta la
// UI directamente con `AuthController.login()` (Paso 13, ya construido) —
// esta pantalla no valida ni decide nada, solo traduce el formulario a los
// parámetros del contrato y el `AuthResult` a un mensaje o una navegación.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_models.dart';
import '../../core/auth/auth_state.dart';
import '../../core/auth/auth_result.dart';
import '../../core/constants.dart';
import '../../core/providers.dart';
import '../../core/security/trust_store.dart';
import '../../core/session/device_handover.dart';
import '../../l10n/l10n.dart';
import '../../ui/theme/app_icons.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/app_brand.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import '../home/home_screen.dart';
import 'trust_certificate_screen.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSubmitting = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final dependencies = ref.read(appDependenciesProvider);
    setState(() => _isSubmitting = true);

    final platform = defaultTargetPlatform == TargetPlatform.iOS
        ? 'ios'
        : 'android';
    final result = await dependencies.authController.login(
      username: _usernameController.text,
      password: _passwordController.text,
      deviceInfo: DeviceInfo(
        deviceId: dependencies.deviceId,
        platform: platform,
        appVersion: kAppVersion,
      ),
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    await result.when(
      ok: (_) async {
        // Teléfono compartido (Fase A): lo que quede sin enviar de otro
        // usuario no puede salir con esta sesión, y los datos de otra
        // organización se borran antes de entrar (`DeviceHandover`).
        final auth = dependencies.authController.state;
        if (auth is Authenticated) {
          final handover = await dependencies.handover.prepare(auth.user);
          if (!mounted) return;
          final messenger = ScaffoldMessenger.of(context);
          final l10n = context.l10n;
          if (handover is HandoverBlocked) {
            try {
              await dependencies.authController.logout();
            } on Object {
              // Sin red no se revoca en el servidor; el token local ya no está.
            }
            messenger.showSnackBar(
              SnackBar(
                content: Text(l10n.loginHandoverBlocked(handover.visits)),
              ),
            );
            return;
          }
          if (handover case HandoverReady(wiped: true)) {
            messenger.showSnackBar(
              SnackBar(content: Text(l10n.loginHandoverWiped)),
            );
          }
        }
        if (!mounted) return;
        // Ley 1581: con sesión ya se puede enviar la prueba de la autorización
        // que el agente dio en el aviso. Si falla, se reintenta en el inicio.
        unawaited(dependencies.consent.syncPending());
        unawaited(
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => const HomeScreen()),
          ),
        );
      },
      err: (error) async {
        if (error case AuthCertificateError(
          :final rejection,
        ) when rejection.approvable) {
          await _offerTrust(rejection);
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_messageFor(error))));
      },
    );
  }

  /// Paso 16 (TOFU): servidor autohospedado con un certificado que no firma
  /// una CA reconocida. Si el usuario confía tras comparar la huella, se
  /// guarda el pin para ese host y se reintenta el login.
  Future<void> _offerTrust(CertificateRejection rejection) async {
    final trusted = await TrustCertificateScreen.show(context, rejection);
    if (!trusted || !mounted) return;
    await ref
        .read(appDependenciesProvider)
        .trustStore
        .approve(rejection.host, rejection.port, rejection.certificate!);
    if (mounted) await _submit();
  }

  String _messageFor(AuthError error) {
    final l10n = context.l10n;
    return error.when(
      network: (message) => l10n.authErrorNetwork,
      invalidCredentials: () => l10n.authErrorInvalidCredentials,
      unauthorized: () => l10n.authErrorUnauthorized,
      unexpectedStatus: (statusCode, body) =>
          l10n.authErrorUnexpectedStatus(statusCode),
      malformedResponse: (details) => l10n.authErrorMalformedResponse,
      certificate: (rejection) => rejection is PinMismatch
          ? l10n.authErrorPinMismatch
          : l10n.authErrorUntrustedCertificate,
      cleartext: () => l10n.authErrorCleartext,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      body: AutofillGroup(
        child: AppPageBody(
          centerVertically: true,
          children: [
            const Align(alignment: Alignment.centerLeft, child: AppBrand()),
            const AppGap.lg(),
            Text(
              l10n.brandDescriptor,
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const AppGap.sm(),
            Text(
              l10n.loginWelcome,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const AppGap.sm(),
            Text(
              l10n.loginIntro,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const AppGap.lg(),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 3,
                  ),
                  left: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  right: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  bottom: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('login_username_field'),
                    controller: _usernameController,
                    decoration: InputDecoration(
                      labelText: l10n.loginUsernameLabel,
                      prefixIcon: const Icon(AppIcons.user),
                    ),
                    autofillHints: const [AutofillHints.username],
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                  ),
                  const AppGap.sm(),
                  TextField(
                    key: const Key('login_password_field'),
                    controller: _passwordController,
                    obscureText: !_showPassword,
                    decoration: InputDecoration(
                      labelText: l10n.loginPasswordLabel,
                      prefixIcon: const Icon(AppIcons.password),
                      suffixIcon: IconButton(
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                        tooltip: _showPassword
                            ? l10n.loginHidePassword
                            : l10n.loginShowPassword,
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                        ),
                      ),
                    ),
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!_isSubmitting) _submit();
                    },
                  ),
                  const AppGap.lg(),
                  AppButton(
                    key: const Key('login_submit_button'),
                    label: l10n.loginSubmit,
                    loadingLabel: l10n.loginSubmitting,
                    isLoading: _isSubmitting,
                    onPressed: _submit,
                  ),
                ],
              ),
            ),
            const AppGap.lg(),
            Text(
              l10n.loginFieldNote,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
