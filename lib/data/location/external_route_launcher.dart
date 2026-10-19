import 'package:url_launcher/url_launcher.dart';

import '../../core/location/navigation_target.dart';

class ExternalRouteLauncher implements RouteLauncher {
  const ExternalRouteLauncher();

  @override
  Future<bool> open(NavigationTarget target) async {
    try {
      // Abrir directamente: canLaunchUrl exigiría consultas de paquetes
      // adicionales y puede devolver false aunque el sistema sí lo abra.
      return await launchUrl(target.directionsUri, mode: LaunchMode.externalApplication);
    } on Exception {
      return false;
    }
  }
}
