import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/features/auth/login_screen.dart';
import 'package:visitacampo/l10n/l10n.dart';
import 'package:visitacampo/ui/theme/app_theme.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('SUNO login: narrow screen, large text, keyboard, dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: dark ? AppTheme.dark : AppTheme.light,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(2),
                viewInsets: const EdgeInsets.only(bottom: 240),
              ),
              child: child!,
            ),
            home: const LoginScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SUNO'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('login_submit_button')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
