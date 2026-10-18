import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_tokens.dart';

/// SUNO: warm paper, ink, quiet surfaces and deliberate red.
abstract final class AppTheme {
  static ThemeData get light => _build(Brightness.light, AppStatusColors.light);
  static ThemeData get dark => _build(Brightness.dark, AppStatusColors.dark);

  static ThemeData _build(Brightness brightness, AppStatusColors status) {
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppPalette.brandSeed,
          brightness: brightness,
        ).copyWith(
          primary: dark ? AppPalette.darkAction : AppPalette.action,
          onPrimary: dark ? AppPalette.ink : AppPalette.cream,
          primaryContainer: dark ? AppPalette.darkRose : AppPalette.rose,
          onPrimaryContainer: dark ? AppPalette.darkAction : AppPalette.action,
          secondary: dark ? AppPalette.darkMuted : AppPalette.forest,
          onSecondary: dark ? AppPalette.ink : AppPalette.cream,
          secondaryContainer: dark ? AppPalette.darkSurface : AppPalette.paper,
          onSecondaryContainer: dark ? AppPalette.cream : AppPalette.ink,
          surface: dark ? AppPalette.ink : AppPalette.cream,
          onSurface: dark ? AppPalette.cream : AppPalette.ink,
          onSurfaceVariant: dark ? AppPalette.darkMuted : AppPalette.muted,
          surfaceContainerLowest: dark ? AppPalette.ink : AppPalette.cream,
          surfaceContainerLow: dark ? AppPalette.darkSurface : AppPalette.paper,
          surfaceContainer: dark ? AppPalette.darkSurface : AppPalette.paper,
          surfaceContainerHigh: dark ? AppPalette.darkLine : AppPalette.line,
          surfaceContainerHighest: dark ? AppPalette.darkLine : AppPalette.line,
          outline: AppPalette.border,
          outlineVariant: dark ? AppPalette.darkLine : AppPalette.line,
          surfaceTint: dark ? AppPalette.ink : AppPalette.cream,
        );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Inter',
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.sm),
    );
    final textTheme = base.textTheme.copyWith(
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -1,
      ),
      headlineSmall: base.textTheme.headlineSmall?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -.6,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w600,
        letterSpacing: -.4,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: base.textTheme.bodyLarge?.copyWith(height: 1.5),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.5),
      labelSmall: base.textTheme.labelSmall?.copyWith(
        letterSpacing: 1.2,
        fontWeight: FontWeight.w600,
      ),
    );
    return base.copyWith(
      textTheme: textTheme,
      scaffoldBackgroundColor: scheme.surface,
      extensions: [status],
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: textTheme.titleLarge,
        shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding: const EdgeInsets.all(AppSpacing.md),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(AppSizes.minTouchTarget),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          textStyle: textTheme.labelLarge,
          shape: shape,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(AppSizes.minTouchTarget),
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(AppSizes.minTouchTarget),
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outline),
          shape: shape,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: AppSpacing.lg,
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        labelStyle: textTheme.labelMedium,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
      ),
    );
  }
}

extension AppThemeContext on BuildContext {
  AppStatusColors get statusColors =>
      Theme.of(this).extension<AppStatusColors>()!;
}
