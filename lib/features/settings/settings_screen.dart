// Ajustes (Fase A): la cuenta y el dispositivo, el GPS y cerrar sesión.
//
// - **Cuenta y dispositivo**: quién está en el teléfono, para qué
//   organización, el identificador del dispositivo y el servidor (solo
//   lectura: el servidor lo fija la compilación, `kApiBaseUrl`).
// - **GPS**: precisión objetivo, lecturas a promediar y tiempo máximo
//   (`GpsSettings`), para adaptarlo al terreno del proyecto.
// - **Cerrar sesión**: avisa si quedan cambios sin enviar. Se conservan en
//   el teléfono y salen cuando el mismo agente vuelva a entrar; mientras
//   tanto nadie más puede entrar en él (`DeviceHandover`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_state.dart';
import '../../core/constants.dart';
import '../../core/location/gps_sampler.dart';
import '../../core/location/gps_settings.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/widgets/app_page_body.dart';
import '../auth/login_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late GpsPolicy _policy;

  @override
  void initState() {
    super.initState();
    _policy = ref.read(appDependenciesProvider).gpsSettings.policy;
  }

  Future<void> _updateGps(GpsPolicy policy) async {
    setState(() => _policy = policy);
    await ref.read(appDependenciesProvider).gpsSettings.update(policy);
  }

  Future<void> _logout() async {
    final dependencies = ref.read(appDependenciesProvider);
    final auth = dependencies.authController.state;
    final l10n = context.l10n;
    final unsent = auth is Authenticated ? await dependencies.handover.unsentVisitsOf(auth.user) : 0;
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsLogoutTitle),
        content: Text(unsent > 0 ? l10n.settingsLogoutUnsent(unsent) : l10n.settingsLogoutBody),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.reviewConfirmCancel)),
          FilledButton(
            key: const Key('settings_logout_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsLogout),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Sin red, la revocación en el servidor falla: el token local se borra
    // igual y el refresh caduca solo.
    try {
      await dependencies.authController.logout();
    } on Object {
      // Ver arriba: cerrar sesión en el teléfono no depende de la red.
    }
    if (!mounted) return;
    unawaited(
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
        (_) => false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dependencies = ref.watch(appDependenciesProvider);
    final auth = dependencies.authController.state;
    final user = auth is Authenticated ? auth.user : null;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: AppPageBody(
        children: [
          Text(l10n.settingsAccount, style: theme.textTheme.titleSmall),
          if (user != null) ...[
            ListTile(title: Text(l10n.settingsUser), subtitle: Text(user.username), key: const Key('settings_user')),
            ListTile(title: Text(l10n.settingsOrganization), subtitle: SelectableText(user.orgId)),
          ],
          ListTile(title: Text(l10n.settingsDevice), subtitle: SelectableText(dependencies.deviceId)),
          ListTile(title: Text(l10n.settingsServer), subtitle: SelectableText(kApiBaseUrl)),
          ListTile(title: Text(l10n.settingsAppVersion), subtitle: const Text(kAppVersion)),
          const AppGap.lg(),
          Text(l10n.settingsGps, style: theme.textTheme.titleSmall),
          Text(l10n.settingsGpsHelp, style: theme.textTheme.bodySmall),
          _Choice<double>(
            key: const Key('settings_gps_accuracy'),
            label: l10n.settingsGpsAccuracy,
            value: _policy.targetAccuracyM,
            options: GpsOptions.targetAccuracyM,
            format: (v) => l10n.gpsAccuracy(v.round()),
            onChanged: (v) => _updateGps(
              GpsPolicy(targetAccuracyM: v, samples: _policy.samples, timeout: _policy.timeout),
            ),
          ),
          _Choice<int>(
            key: const Key('settings_gps_samples'),
            label: l10n.settingsGpsSamples,
            value: _policy.samples,
            options: GpsOptions.samples,
            format: (v) => '$v',
            onChanged: (v) => _updateGps(
              GpsPolicy(targetAccuracyM: _policy.targetAccuracyM, samples: v, timeout: _policy.timeout),
            ),
          ),
          _Choice<int>(
            key: const Key('settings_gps_timeout'),
            label: l10n.settingsGpsTimeout,
            value: _policy.timeout.inSeconds,
            options: GpsOptions.timeoutSeconds,
            format: l10n.settingsSeconds,
            onChanged: (v) => _updateGps(
              GpsPolicy(
                targetAccuracyM: _policy.targetAccuracyM,
                samples: _policy.samples,
                timeout: Duration(seconds: v),
              ),
            ),
          ),
          const AppGap.lg(),
          OutlinedButton.icon(
            key: const Key('settings_logout'),
            icon: const Icon(Icons.logout),
            label: Text(l10n.settingsLogout),
            onPressed: _logout,
          ),
        ],
      ),
    );
  }
}

class _Choice<T> extends StatelessWidget {
  const _Choice({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> options;
  final String Function(T) format;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    items: [for (final option in options) DropdownMenuItem(value: option, child: Text(format(option)))],
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
  );
}
