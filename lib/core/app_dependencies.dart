// Composición de dependencias de la app (Tarea 5 del plan de despliegue del
// demo). Un único objeto en vez de un grafo fino de providers de Riverpod:
// `AuthController`/`SyncEngine` no son observables (no son `ChangeNotifier`/
// `StateNotifier`, ver sus propios archivos), así que un grafo reactivo
// alrededor de ellos no aportaría nada — la navegación de esta app es
// imperativa (`Navigator.pushReplacement` tras el resultado de `login()`).
//
// Las Tareas 6 y 7 **añaden campos a esta misma clase** (`locationSource`/
// `photoCapture` en la 6; `syncEngine`/`attachmentUploadService` en la 7) en
// vez de crear objetos de dependencias paralelos.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'attachments/attachment_upload_scheduler.dart';
import 'attachments/attachment_upload_service.dart';
import 'auth/auth_controller.dart';
import 'basemaps/basemap_manager.dart';
import 'auth/auth_state.dart';
import 'auth/session_store.dart';
import 'auth/token_store.dart';
import 'capture/photo_capture.dart';
import 'capture/signature_store.dart';
import 'capture/visit_capture.dart';
import 'constants.dart';
import 'device/device_id_store.dart';
import 'location/gps_sampler.dart';
import 'location/coordinate_settings.dart';
import 'location/gps_settings.dart';
import 'location/location_source.dart';
import 'privacy/consent.dart';
import 'security/pin_store.dart';
import 'session/device_handover.dart';
import 'security/secure_storage.dart';
import 'security/trust_store.dart';
import 'sync/quarantine_service.dart';
import 'sync/sync_coordinator.dart';
import 'sync/sync_engine.dart';
import '../data/capture/file_signature_store.dart';
import '../data/capture/image_picker_photo_capture.dart';
import '../data/http/api_client.dart';
import '../data/http/attachment_api_client.dart';
import '../data/http/auth_interceptor.dart';
import '../data/http/basemap_api_client.dart';
import '../data/http/consent_api_client.dart';
import '../data/http/sync_api_client.dart';
import '../data/local/assignment_repository.dart';
import '../data/local/database.dart';
import '../data/local/encryption_key_store.dart';
import '../data/local/form_template_repository.dart';
import '../data/local/visit_status_repository.dart';
import '../data/location/geolocator_location_source.dart';

class AppDependencies {
  AppDependencies({
    required this.database,
    required this.dio,
    required this.authController,
    required this.deviceId,
    LocationSource? locationSource,
    PhotoCapture? photoCapture,
    SyncEngine? syncEngine,
    AttachmentUploadService? attachmentUploadService,
    SignatureStore? signatureStore,
    GpsSettings? gpsSettings,
    CoordinateSettings? coordinates,
    BasemapManager? basemaps,
    Directory? basemapsDirectory,
    VisitCapture? visitCapture,
    TrustStore? trustStore,
    ConsentService? consent,
  }) : gpsSettings = gpsSettings ?? GpsSettings(HardenedSecureStorage()),
       coordinates = coordinates ?? CoordinateSettings(HardenedSecureStorage()),
       basemaps =
           basemaps ??
           BasemapManager(
             transport: BasemapApiClient(
               dio: dio,
               accessTokenProvider: () => authController.accessToken ?? '',
               // Como las subidas: sin bearer, con la misma política TLS.
               downloadDio: Dio()..httpClientAdapter = dio.httpClientAdapter,
             ),
             directory: basemapsDirectory ?? Directory(p.join(Directory.systemTemp.path, 'visitacampo-basemaps')),
           ),
       trustStore = trustStore ?? TrustStore(pinStore: PinStore(HardenedSecureStorage())),
       consent =
           consent ??
           ConsentService(
             store: ConsentStore(HardenedSecureStorage()),
             transport: ConsentApiClient(dio),
             accessTokenProvider: () => authController.accessToken ?? '',
             deviceId: deviceId,
           ),
       locationSource = locationSource ?? const GeolocatorLocationSource(),
       photoCapture = photoCapture ?? ImagePickerPhotoCapture(),
       signatureStore = signatureStore ?? const FileSignatureStore(),
       visitCapture = visitCapture ?? VisitCapture(db: database),
       syncEngine =
           syncEngine ??
           SyncEngine(
             db: database,
             transport: SyncApiClient(dio: dio, accessTokenProvider: () => authController.accessToken ?? ''),
             deviceId: deviceId,
           ),
       attachmentUploadService =
           attachmentUploadService ??
           AttachmentUploadService(
             db: database,
             transport: AttachmentApiClient(
               dio: dio,
               accessTokenProvider: () => authController.accessToken ?? '',
               // Las URL prefirmadas pasan por la misma política TLS
               // (Paso 16): en un servidor autohospedado van al mismo host.
               uploadDio: Dio()..httpClientAdapter = dio.httpClientAdapter,
             ),
           );

  final AppDatabase database;
  final Dio dio;

  /// Paso 16: confianza TLS (pinning SPKI / TOFU). Ya cargado y conectado al
  /// `dio`; el login lo usa para guardar un certificado aprobado.
  final TrustStore trustStore;

  /// Ley 1581: autorización del titular (aviso de privacidad antes del login)
  /// y envío de su prueba al servidor.
  final ConsentService consent;
  final AuthController authController;
  final String deviceId;
  final LocationSource locationSource;

  /// Cuándo una posición GPS es buena (Fase A), ajustable en Ajustes.
  final GpsSettings gpsSettings;

  /// Mapas base offline (Fase B).
  final BasemapManager basemaps;
  GpsPolicy get gpsPolicy => gpsSettings.policy;

  /// Sistema en que se muestran las coordenadas (Fase C); se guardan en 4326.
  final CoordinateSettings coordinates;

  /// Cambio de usuario en un teléfono compartido (Fase A).
  DeviceHandover get handover => DeviceHandover(database);
  final PhotoCapture photoCapture;
  final SyncEngine syncEngine;
  final AttachmentUploadService attachmentUploadService;

  /// Paso 18: drena la cola de adjuntos sola (arranque, primer plano,
  /// periódico, tras capturar). Una sola instancia: el single-flight solo
  /// protege si todos los disparos pasan por el mismo objeto.
  late final AttachmentUploadScheduler uploadScheduler = AttachmentUploadScheduler(
    service: attachmentUploadService,
    isAuthenticated: () => authController.state is Authenticated,
  );

  /// Fase A: el ciclo completo (outbox → adjuntos → pull) sin esperar al
  /// botón. Una sola instancia, por el mismo motivo que el planificador.
  late final SyncCoordinator syncCoordinator = SyncCoordinator(
    drainOutbox: syncEngine.drainOutbox,
    uploadAttachments: ({required force}) => uploadScheduler.nudge(force: force),
    outstandingAttachments: attachmentUploadService.outstanding,
    pull: syncEngine.pull,
    isAuthenticated: () => authController.state is Authenticated,
  );

  /// Paso 22: dónde se guardan las firmas y el guardado de una visita.
  final SignatureStore signatureStore;
  final VisitCapture visitCapture;

  /// Estado de sincronización de las visitas, para la pantalla de inicio.
  VisitStatusRepository get visitStatus => VisitStatusRepository(database);

  /// Asignaciones del agente (Fase B).
  AssignmentRepository get assignments => AssignmentRepository(database);

  /// Revisión de la cuarentena (Paso 23), sobre el mismo `SyncEngine`.
  QuarantineService get quarantine => QuarantineService(db: database, engine: syncEngine);

  /// Caché de plantillas (Paso 21): **la misma** instancia que alimenta el
  /// pull, para que las pantallas vean su invalidación.
  FormTemplateRepository get formTemplates => syncEngine.templates;

  static Future<AppDependencies> bootstrap() async {
    // Paso 16: Keychain "after first unlock, this device only" (migra los
    // secretos escritos antes) y Keystore en Android.
    final secureStorage = HardenedSecureStorage();

    final deviceIdStore = DeviceIdStore(read: secureStorage.read, write: secureStorage.write);
    final deviceId = await deviceIdStore.getOrCreateId();

    final encryptionKeyStore = EncryptionKeyStore(secureStorage);
    final encryptionKey = await encryptionKeyStore.getOrCreateKey();
    final documentsDir = await getApplicationDocumentsDirectory();
    final dbFile = File(p.join(documentsDir.path, 'visitacampo.db'));
    final database = AppDatabase.open(
      createEncryptedExecutor(file: dbFile, encryptionKey: encryptionKey),
    );

    final trustStore = TrustStore(
      pinStore: PinStore(secureStorage),
      officialPins: SpkiPinPolicy.fromEnvironment(kApiBaseUrl),
    );
    await trustStore.load();
    final dio = Dio(BaseOptions(baseUrl: kApiBaseUrl))..httpClientAdapter = trustStore.adapter();
    final tokenStore = SecureTokenStore(secureStorage);
    final authController = AuthController(
      transport: AuthApiClient(dio),
      tokenStore: tokenStore,
      deviceId: deviceId,
      // Fase A: volver a entrar sin red (perfil + caducidad del refresh).
      sessionStore: SecureSessionStore(secureStorage),
    );
    dio.interceptors.add(AuthInterceptor(dio: dio, controller: authController));
    final gpsSettings = GpsSettings(secureStorage);
    await gpsSettings.load();
    final coordinates = CoordinateSettings(secureStorage);
    await coordinates.load();

    return AppDependencies(
      database: database,
      dio: dio,
      authController: authController,
      deviceId: deviceId,
      trustStore: trustStore,
      gpsSettings: gpsSettings,
      coordinates: coordinates,
      basemapsDirectory: Directory(p.join(documentsDir.path, 'basemaps')),
    );
  }
}
