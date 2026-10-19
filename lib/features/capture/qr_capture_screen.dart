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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_camera.value.hasCameraPermission || _returned) return;
    if (state == AppLifecycleState.resumed) {
      _camera.start();
    } else {
      _camera.stop();
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
    body: MobileScanner(
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
