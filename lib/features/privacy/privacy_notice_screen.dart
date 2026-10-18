// Aviso de privacidad y autorización del titular (Ley 1581, art. 9 y 12).
//
// Se muestra al primer arranque y cada vez que cambia la versión del aviso,
// **antes del login**: nada de la cuenta, la ubicación ni las fotos se trata
// sin la autorización. Cada finalidad tiene su casilla (autorización expresa,
// no un "acepto" genérico) y "Acepto y continúo" solo se habilita con las
// tres. La prueba se envía al servidor tras el login (`ConsentService`).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/privacy/consent.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';
import '../auth/login_screen.dart';

class PrivacyNoticeScreen extends ConsumerStatefulWidget {
  const PrivacyNoticeScreen({super.key});

  @override
  ConsumerState<PrivacyNoticeScreen> createState() =>
      _PrivacyNoticeScreenState();
}

class _PrivacyNoticeScreenState extends ConsumerState<PrivacyNoticeScreen> {
  final Set<PrivacyPurpose> _accepted = {};
  bool _saving = false;

  bool get _complete => _accepted.containsAll(PrivacyPurpose.values);

  Future<void> _accept() async {
    setState(() => _saving = true);
    await ref.read(appDependenciesProvider).consent.accept(Set.of(_accepted));
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
    );
  }

  void _decline() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.privacyDeclined)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final purposes = {
      PrivacyPurpose.account: (
        l10n.privacyPurposeAccountTitle,
        l10n.privacyPurposeAccountBody,
      ),
      PrivacyPurpose.location: (
        l10n.privacyPurposeLocationTitle,
        l10n.privacyPurposeLocationBody,
      ),
      PrivacyPurpose.photos: (
        l10n.privacyPurposePhotosTitle,
        l10n.privacyPurposePhotosBody,
      ),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.privacyTitle),
        automaticallyImplyLeading: false,
      ),
      body: AppPageBody(
        children: [
          Text(l10n.privacyIntro, style: theme.textTheme.bodyLarge),
          const AppGap.sm(),
          Text(l10n.privacyResponsible, style: theme.textTheme.bodyMedium),
          const AppGap.lg(),
          for (final MapEntry(key: purpose, value: (title, body))
              in purposes.entries)
            CheckboxListTile(
              key: Key('privacy_${purpose.name}'),
              value: _accepted.contains(purpose),
              onChanged: (checked) => setState(() {
                if (checked ?? false) {
                  _accepted.add(purpose);
                } else {
                  _accepted.remove(purpose);
                }
              }),
              title: Text(title),
              subtitle: Text(body),
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
          const AppGap.sm(),
          Text(l10n.privacyRights, style: theme.textTheme.bodyMedium),
          const AppGap.lg(),
          if (!_complete)
            Text(l10n.privacyAllRequired, style: theme.textTheme.bodySmall),
          const AppGap.sm(),
          AppButton(
            key: const Key('privacy_accept_button'),
            label: l10n.privacyAccept,
            isLoading: _saving,
            onPressed: _complete && !_saving ? _accept : null,
          ),
          const AppGap.sm(),
          TextButton(
            key: const Key('privacy_decline_button'),
            onPressed: _decline,
            child: Text(l10n.privacyDecline),
          ),
          const AppGap.sm(),
          Text(
            l10n.privacyVersion(kPrivacyNoticeVersion),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
