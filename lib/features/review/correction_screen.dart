// Corregir una visita rechazada (Paso 23): el mismo formulario dinámico de la
// captura, con las respuestas del agente y los campos que señaló el servidor
// marcados desde el principio. Al guardar se reenvía como operación nueva
// (`QuarantineService.correct`).
//
// Foto, firma y ubicación no se pueden recapturar aquí (sin `FormMediaDelegate`):
// si el servidor señala uno de esos campos, la visita se reintenta o se
// descarta desde la revisión.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/capture/visit_capture.dart';
import '../../core/providers.dart';
import '../../core/sync/quarantine_service.dart';
import '../../data/local/form_template_repository.dart';
import '../../l10n/l10n.dart';
import '../../ui/forms/dynamic_form.dart';
import '../../ui/forms/form_controller.dart';
import '../../ui/forms/template_status.dart';
import '../../ui/widgets/app_button.dart';
import '../../ui/widgets/app_page_body.dart';

class CorrectionScreen extends ConsumerStatefulWidget {
  const CorrectionScreen({super.key, required this.item});

  final QuarantinedVisit item;

  @override
  ConsumerState<CorrectionScreen> createState() => _CorrectionScreenState();
}

class _CorrectionScreenState extends ConsumerState<CorrectionScreen> {
  TemplateLookup? _lookup;
  FormController? _form;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _form?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final visit = widget.item.visit;
    final lookup = await ref
        .read(appDependenciesProvider)
        .formTemplates
        .forVisit(orgId: visit.orgId, templateVersionId: visit.templateVersionId);
    if (!mounted) return;
    setState(() {
      _lookup = lookup;
      if (lookup is TemplateReady) {
        _form = FormController(
          lookup.definition,
          initialAnswers: widget.item.localAnswers,
          serverErrors: widget.item.answerViolations,
        );
      }
    });
  }

  Future<void> _save() async {
    final form = _form;
    final lookup = _lookup;
    if (form == null || lookup is! TemplateReady) return;
    final l10n = context.l10n;
    if (!form.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.captureFixErrors)));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(appDependenciesProvider)
          .quarantine
          .correct(widget.item, keptAnswers(lookup.definition, form.answers));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final lookup = _lookup;
    final form = _form;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.correctionTitle)),
      body: AppPageBody(
        children: [
          if (lookup == null)
            const Center(child: CircularProgressIndicator())
          else if (form == null)
            Text(templateLookupMessage(l10n, lookup) ?? l10n.formTemplateMissing, key: const Key('correction_no_template'))
          else ...[
            DynamicForm(controller: form),
            const AppGap.lg(),
            AppButton(
              key: const Key('correction_save_button'),
              label: l10n.correctionSave,
              loadingLabel: l10n.captureSaving,
              isLoading: _saving,
              onPressed: _save,
            ),
          ],
        ],
      ),
    );
  }
}
