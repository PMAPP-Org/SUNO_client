// "Mapas offline" (Fase B), desde Ajustes: los mapas base de la
// organización, cuáles están en el teléfono, y descargarlos o borrarlos.
//
// Antes de descargar se confirma el tamaño (un paquete puede pesar cientos de
// MB; se recomienda wifi). Lo descargado se verifica antes de activarse
// (`BasemapManager.download`). Sin red se ven solo los ya descargados.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/basemaps/basemap_manager.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../ui/widgets/app_page_body.dart';

class BasemapsScreen extends ConsumerStatefulWidget {
  const BasemapsScreen({super.key});

  @override
  ConsumerState<BasemapsScreen> createState() => _BasemapsScreenState();
}

class _BasemapsScreenState extends ConsumerState<BasemapsScreen> {
  List<BasemapEntry>? _entries;
  bool _online = true;

  /// Descarga en curso: id → fracción (0–1), o `null` si aún no se sabe.
  final Map<String, double?> _progress = {};

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  BasemapManager get _manager => ref.read(appDependenciesProvider).basemaps;

  Future<void> _refresh() async {
    final result = await _manager.refresh();
    if (!mounted) return;
    setState(() {
      _entries = result.entries;
      _online = result.online;
    });
  }

  Future<void> _download(BasemapInfo info) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.basemapDownloadTitle(info.name)),
        content: Text(l10n.basemapDownloadBody(_megabytes(info.size))),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(l10n.reviewConfirmCancel)),
          FilledButton(
            key: const Key('basemap_download_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.basemapDownload),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _progress[info.id] = null);
    final result = await _manager.download(
      info,
      onProgress: (received, total) {
        if (mounted && total > 0) setState(() => _progress[info.id] = received / total);
      },
    );
    if (!mounted) return;
    setState(() => _progress.remove(info.id));
    final message = switch (result) {
      BasemapDownloaded() => l10n.basemapDownloaded(info.name),
      BasemapCorrupted() => l10n.basemapCorrupted,
      BasemapNoSpace() => l10n.basemapNoSpace,
      BasemapUnavailable() => l10n.basemapUnavailable,
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    await _refresh();
  }

  Future<void> _remove(BasemapInfo info) async {
    await _manager.remove(info);
    await _refresh();
  }

  static int _megabytes(int bytes) => (bytes / (1024 * 1024)).ceil();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.basemapsTitle)),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: AppPageBody(
                children: [
                  if (!_online) Text(l10n.basemapsOffline, key: const Key('basemaps_offline')),
                  if (entries.isEmpty) Text(l10n.basemapsEmpty, key: const Key('basemaps_empty')),
                  for (final entry in entries)
                    ListTile(
                      key: ValueKey('basemap-${entry.info.id}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(entry.downloaded ? Icons.offline_pin : Icons.map_outlined),
                      title: Text(entry.info.name),
                      subtitle: _progress.containsKey(entry.info.id)
                          ? LinearProgressIndicator(value: _progress[entry.info.id])
                          : Text(
                              l10n.basemapDetails(
                                _megabytes(entry.info.size),
                                entry.info.minZoom,
                                entry.info.maxZoom,
                              ),
                            ),
                      trailing: _progress.containsKey(entry.info.id)
                          ? null
                          : entry.downloaded
                          ? IconButton(
                              key: ValueKey('basemap-remove-${entry.info.id}'),
                              tooltip: l10n.basemapRemove,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _remove(entry.info),
                            )
                          : IconButton(
                              key: ValueKey('basemap-download-${entry.info.id}'),
                              tooltip: l10n.basemapDownload,
                              icon: const Icon(Icons.download),
                              onPressed: _online ? () => _download(entry.info) : null,
                            ),
                    ),
                ],
              ),
            ),
    );
  }
}
