import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../l10n/l10n.dart';

/// Camera ownership ends with this route. Only QR text is returned; never opened.
class QrCaptureScreen extends StatefulWidget {
  const QrCaptureScreen({super.key});

  @override
  State<QrCaptureScreen> createState() => _QrCaptureScreenState();
}

class _QrCaptureScreenState extends State<QrCaptureScreen> with WidgetsBindingObserver {
  final _camera = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  bool _returned = false;
  bool _unavailable = false;

  /// Paradas y arranques en cola: un `start` al volver no puede adelantarse
  /// al `stop` de un paso breve a inactiva (cortina de notificaciones).
  Future<void> _lifecycle = Future.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_camera.value.hasCameraPermission || _returned) return;
    _enqueue(state == AppLifecycleState.resumed ? _resumeCamera : _stopCamera);
  }

  void _enqueue(Future<void> Function() step) => _lifecycle = _lifecycle.then((_) => step());

  Future<void> _stopCamera() async {
    try {
      await _camera.stop();
    } on MobileScannerException {
      // Ya parada o sin cámara: no hay nada que liberar.
    }
  }

  Future<void> _resumeCamera() async {
    try {
      await _camera.start();
      if (mounted && _unavailable) setState(() => _unavailable = false);
    } on MobileScannerException {
      if (mounted) setState(() => _unavailable = true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.formScanQr)),
    body: _unavailable
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(context.l10n.formQrUnavailable, textAlign: TextAlign.center),
                TextButton(onPressed: () => _enqueue(_resumeCamera), child: Text(context.l10n.formQrRetry)),
              ],
            ),
          )
        : MobileScanner(
            controller: _camera,
            errorBuilder: (_, _) => Center(child: Text(context.l10n.formQrUnavailable)),
            onDetect: (capture) {
              final text = capture.barcodes.firstOrNull?.rawValue;
              if (_returned || text == null || text.isEmpty || !mounted) return;
              _returned = true;
              Navigator.of(context).pop(text);
            },
          ),
  );
}
