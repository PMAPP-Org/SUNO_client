// VisitaCampo — punto de entrada real (Tarea 5 del plan de despliegue del
// demo). Reemplaza el demo de `flutter create` (contador) sin modificar.
// Primera pantalla: el aviso de privacidad si el titular aún no autorizó la
// versión vigente (Ley 1581: autorización previa); si no, el inicio cuando
// hay una sesión guardada y vigente (se trabaja sin red), o el login.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_dependencies.dart';
import 'core/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/home/home_screen.dart';
import 'features/privacy/privacy_notice_screen.dart';
import 'l10n/l10n.dart';
import 'ui/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dependencies = await AppDependencies.bootstrap();
  final consented = await dependencies.consent.isAcceptedForCurrentVersion();
  // Fase A: con una sesión guardada y vigente se entra sin red. El access
  // token se pide en segundo plano; si la sesión fue revocada, la pantalla de
  // inicio vuelve al login (sin tocar la outbox).
  final restored = consented && await dependencies.authController.restoreSession();
  if (restored) unawaited(dependencies.authController.refreshOnce());
  runApp(
    ProviderScope(
      overrides: [appDependenciesProvider.overrideWithValue(dependencies)],
      child: App(
        start: !consented
            ? const PrivacyNoticeScreen()
            : restored
            ? const HomeScreen()
            : const LoginScreen(),
      ),
    ),
  );
}

class App extends StatelessWidget {
  const App({this.start = const LoginScreen(), super.key});

  /// Primera pantalla: el login, o el aviso de privacidad si falta autorizarlo.
  final Widget start;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => context.l10n.appTitle,
      // Tema claro u oscuro según el sistema: en campo, con sol directo o de
      // noche, el usuario elige lo que se lee mejor.
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: start,
    );
  }
}
