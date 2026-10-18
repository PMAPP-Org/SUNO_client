import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../theme/app_tokens.dart';

/// Original emblem with a typographic wordmark; never a redrawn logo.
class AppBrand extends StatelessWidget {
  const AppBrand({super.key, this.large = false});
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mark = Image.asset(
      'assets/brand/Logo_Principal.png',
      width: large ? AppSizes.brandHero : AppSizes.brandMark,
      height: large ? AppSizes.brandHero : AppSizes.brandMark,
      excludeFromSemantics: true,
    );
    final name = Text(
      context.l10n.appTitle,
      style:
          (large ? theme.textTheme.headlineMedium : theme.textTheme.titleLarge)
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 3),
    );
    return Semantics(
      header: true,
      child: large
          ? Column(
              children: [
                mark,
                const SizedBox(height: AppSpacing.sm),
                name,
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                const SizedBox(width: AppSpacing.sm),
                name,
              ],
            ),
    );
  }
}
