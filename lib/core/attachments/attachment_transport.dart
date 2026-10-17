// `AttachmentTransport` — la mitad de red que `AttachmentUploadService`
// necesita (Tarea 7 del plan de despliegue del demo). Implementada por
// `AttachmentApiClient` (Dio real, `data/http/attachment_api_client.dart`) y
// por `FakeAttachmentTransport` en los tests.
import 'attachment_result.dart';

class PresignData {
  const PresignData({required this.alreadyPresent, this.uploadUrl, this.requiredHeaders});

  final bool alreadyPresent;
  final String? uploadUrl;
  final Map<String, String>? requiredHeaders;
}

abstract class AttachmentTransport {
  /// `POST /v1/attachments/presign`. Sin `visit_id` (Decisión de diseño 11
  /// del plan): evita depender de que el `push` de la visita ya haya
  /// terminado en el servidor.
  Future<AttachmentResult<PresignData>> presign({
    required String sha256,
    required int size,
    required String mime,
  });

  /// `PUT` directo a `uploadUrl` (host del object storage, no de la API de
  /// VisitaCampo) con los `headers` que el servidor exigió al firmar.
  ///
  /// **Streaming** (Paso 18, corrige H-05 en el cliente): `body` se envía a
  /// medida que se lee del archivo, con `Content-Length` = [length], sin
  /// armar el contenido en memoria. Quien llama es dueño del stream y lo
  /// cierra siempre (`GuardedUploadStream.close` en un `finally`), también si
  /// esta llamada falla a mitad.
  Future<AttachmentResult<void>> upload({
    required String uploadUrl,
    required Map<String, String> headers,
    required Stream<List<int>> body,
    required int length,
  });

  /// `POST /v1/attachments/{sha256}/commit`.
  Future<AttachmentResult<void>> commit({
    required String sha256,
    required int size,
    required String mime,
  });
}
