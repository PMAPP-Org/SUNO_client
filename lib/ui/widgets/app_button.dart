import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Botón de acción con estado de carga.
///
/// Mientras `isLoading` es `true` se deshabilita y muestra un indicador de
/// progreso, y el lector de pantalla anuncia `loadingLabel` en vez de quedarse
/// sin etiqueta. Reemplaza el `ElevatedButton` + `SizedBox` +
/// `CircularProgressIndicator` que cada pantalla repetía a mano.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.loadingLabel,
    this.icon,
    this.secondary = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final IconData? icon;
  final bool secondary;

  /// Texto para lectores de pantalla mientras carga (por defecto, `label`).
  final String? loadingLabel;

  @override
  Widget build(BuildContext context) {
    final child = isLoading
        ? Semantics(
            label: loadingLabel ?? label,
            child: const SizedBox.square(
              dimension: AppSizes.buttonProgress,
              child: CircularProgressIndicator(
                strokeWidth: AppSizes.buttonProgressStroke,
              ),
            ),
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: AppSizes.buttonProgress),
                const SizedBox(width: AppSpacing.xs),
              ],
              Flexible(child: Text(label, textAlign: TextAlign.center)),
            ],
          );
    if (secondary) {
      return OutlinedButton(
        onPressed: isLoading ? null : onPressed,
        child: child,
      );
    }
    return ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      child: child,
    );
  }
}
