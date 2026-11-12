// Esquema Drift del Paso 11 (ADR-002). Tres tablas, un solo archivo de BD:
// el outbox es una tabla más del mismo esquema, así que "guardar registro +
// encolar operación" es una única transacción SQLite (ver
// `database.dart::saveRecordWithOutboxOp`), no dos pasos con riesgo de
// divergencia si el proceso muere entre medias.
import 'package:drift/drift.dart';

/// Espejo local de `Record` (contrato `server/openapi/v1.yaml`,
/// `server/suno/core/models/record.py`).
class Records extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  IntColumn get version => integer()();

  /// `null`: creada localmente, el servidor todavía no le asignó
  /// `change_seq` (doc 08 §4.4 — ese número solo existe tras el push).
  IntColumn get changeSeq => integer().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  TextColumn get templateVersionId => text()();

  /// JSON serializado (`Map<String, dynamic>` codificado por el `SyncEngine`,
  /// Paso 12) — la propia tabla no interpreta las respuestas del formulario.
  TextColumn get answersJson => text()();
  RealColumn get lat => real().nullable()();
  RealColumn get lon => real().nullable()();
  RealColumn get accuracyM => real().nullable()();
  RealColumn get altitudeM => real().nullable()();
  DateTimeColumn get capturedAt => dateTime()();
  TextColumn get deviceId => text()();
  TextColumn get createdBy => text()();

  /// Fase A (editar y borrar): la última versión **confirmada por el
  /// servidor** (`data` del contrato, JSON). `null` si el servidor todavía no
  /// la conoce. Mientras el registro tiene cambios locales sin enviar, el pull
  /// solo actualiza esta copia, sin pisar lo que el agente editó; si el agente
  /// descarta un cambio rechazado, el registro vuelve a esta versión.
  TextColumn get serverDataJson => text().nullable()();

  /// Fase B: la asignación que originó el registro, si la hubo.
  TextColumn get assignmentId => text().nullable()();

  /// Costos, etapa 1: la tarea del cronograma cuyo avance
  /// reporta el registro y el % acumulado. Los dos o ninguno, como en el
  /// servidor (`record_task_progress_pair`).
  TextColumn get taskId => text().nullable()();
  RealColumn get progressPct => real().nullable()();

  /// Costos, pieza 4b: las cantidades ejecutadas, JSON con la forma del contrato
  /// (`RecordQuantityPayload` al capturar, `RecordQuantity` tras el pull). `[]` sin
  /// cantidades. Ver `core/schedule/quantity_rows.dart`.
  TextColumn get quantitiesJson => text().withDefault(const Constant('[]'))();

  /// El servidor rechazó un cambio porque el registro ya está validado
  /// (`record_validated`): desde entonces sus cantidades son de solo lectura en la
  /// captura. Solo local: el contrato no publica la revisión.
  BoolColumn get knownValidated => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Operaciones pendientes de sincronizar (doc 08 §4.3). La máquina de
/// estados completa (`pending → inflight → applied/conflicted/rejected/
/// quarantine`) es dominio del Paso 12 — esta tabla solo persiste lo que esa
/// máquina necesita leer al arrancar la app, para que el outbox sobreviva un
/// cierre de la app a mitad de un drenaje.
class OutboxOps extends Table {
  /// UUIDv7 (Paso 12) — la idempotencia real del push depende de que este
  /// valor se genere una sola vez en el dispositivo, nunca en el servidor.
  TextColumn get opUuid => text()();

  /// Contrato `EntityType`: `record` | `record_attachment` | `assignment` |
  /// `form_template_version`. Texto y no un enum Drift a propósito: el
  /// contrato es la fuente de verdad de qué valores son válidos, no el
  /// esquema local — igual que el servidor (`sync/schemas.py::EntityType`).
  TextColumn get entity => text()();
  TextColumn get entityId => text()();

  /// `create` | `update` | `delete` (contrato `RawSyncOp.op_type`).
  TextColumn get opType => text()();

  /// `null` en `create` (doc 08: "el `create` del push envía `base_version:
  /// null`, nunca 0").
  IntColumn get baseVersion => integer().nullable()();

  /// JSON serializado del `payload` de la operación tal como viajará en
  /// `POST /v1/sync/push` (contrato `RawSyncOp.payload`).
  TextColumn get payloadJson => text()();

  /// El `message` de `OpErrorSchema` cuando el estado es `quarantine`
  /// (`OutboxOpState.quarantine.reason`) — persistido para que sobreviva un
  /// reinicio de la app; sin esto, el usuario perdería el motivo mostrado en
  /// la UI de conflictos (Paso 23) cada vez que cierra la app.
  /// Nunca lleva `details` del error (RD-12: nunca el dato que falló).
  TextColumn get errorMessage => text().nullable()();

  /// Revisión de cuarentena (Paso 23):
  /// - `errorCode`: `code` del contrato (`validation_error`, `not_found`,
  ///   `conflict`…), que decide qué acciones ofrece la pantalla;
  /// - `errorFieldsJson`: los pares `field`/`reason` que señaló el servidor
  ///   (`fieldViolations`), solo eso;
  /// - `serverRowJson`: la fila autoritativa de un `conflict`. Se guarda en
  ///   vez de aplicarla, para no pisar la versión del agente sin que él decida.
  TextColumn get errorCode => text().nullable()();
  TextColumn get errorFieldsJson => text().nullable()();
  TextColumn get serverRowJson => text().nullable()();

  /// Estado de la máquina de doc 08 §4.3, como texto (Paso 12 define el
  /// `sealed class OutboxOpState` que produce/consume estos valores).
  TextColumn get state => text()();

  /// Orden FIFO de drenaje: el `SyncEngine` (Paso 12) procesa el outbox en
  /// el orden en que el usuario generó las operaciones, no en orden
  /// arbitrario — importante porque una `update`/`delete` puede depender de
  /// que su `create` ya se haya aplicado.
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {opUuid};
}

/// Adjuntos pendientes de subir (Paso 18). `sha256` es la misma clave que
/// `Blob.sha256` en el servidor (`core/models/record.py`): el adjunto se
/// identifica por contenido, nunca por nombre de archivo — la mitigación de
/// RD-06 (path traversal) empieza aquí, no solo en el backend.
class AttachmentQueue extends Table {
  TextColumn get sha256 => text()();
  TextColumn get localPath => text()();

  /// `pending` | `uploading` | `uploaded` | `failed`. Transiciones (Paso 18,
  /// `AttachmentUploadService`): `pending → uploading → uploaded`; un fallo
  /// transitorio (red, 5xx, URL caducada) vuelve a `pending` con backoff; uno
  /// permanente (archivo ausente, 4xx de validación) pasa a `failed` hasta
  /// que el agente lo reintenta. Un `uploading` huérfano (la app murió a
  /// mitad) vuelve a `pending` al arrancar.
  TextColumn get state => text()();
  DateTimeColumn get createdAt => dateTime()();

  /// MIME con el que se presigna y confirma la subida (allow-list del
  /// servidor). La cámara produce fotos JPEG y la firma PNG; el servidor
  /// comprueba los magic bytes contra este valor.
  TextColumn get mime => text().withDefault(const Constant('image/jpeg'))();

  /// Reintento en segundo plano (Paso 18). Se persiste, a
  /// diferencia del backoff del outbox de datos: una foto que no sube por
  /// mala cobertura no debe reintentarse en ráfaga cada vez que se abre la app.
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// `null`: se puede intentar ya.
  DateTimeColumn get nextAttemptAt => dateTime().nullable()();

  /// Motivo del último fallo, para mostrárselo al agente. Nunca lleva la URL
  /// prefirmada ni el cuerpo de la respuesta (RD-12).
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {sha256};
}

/// Cursor de pull persistido (Paso 12, `SyncEngine.pull()`). Fila única
/// (`id` siempre `0`, forzado por el `CHECK`) — no hay "cursor por
/// dispositivo" que rastrear porque esta tabla ya vive en la BD de un solo
/// dispositivo.
class SyncCursor extends Table {
  // Sin CHECK SQL de "fila única": el único código que escribe esta tabla
  // es `AppDatabase.writeCursor()`, que siempre usa `id=0` — no hay una
  // ruta de escritura externa que pudiera violar el invariante.
  // `clientDefault` (no `.withDefault`) para que `id` no sea obligatorio en
  // `SyncCursorCompanion.insert(...)`.
  IntColumn get id => integer().clientDefault(() => 0)();
  TextColumn get cursor => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Caché local de `form_template_version` (Paso 21, tareas 5-6), alimentada
/// por el pull.
///
/// **La clave es la versión, no la plantilla** (corrige H-11: QField cacheaba
/// por `layerId` en un `Q_GLOBAL_STATIC` que nunca se invalidaba). Cada fila es
/// una versión inmutable; un registro histórico sigue leyendo la suya, y un
/// registro nuevo usa la publicada más alta de su plantilla
/// (`FormTemplateRepository`). Un tombstone marca `deletedAt` en vez de borrar,
/// por la misma razón: la versión deja de ofrecerse para registros nuevos, pero
/// los registros que ya la referencian siguen siendo interpretables.
///
/// `definitionJson` se guarda tal como llegó y se valida **al usarlo**: la
/// tabla no interpreta la plantilla.
class FormTemplateVersions extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  TextColumn get templateId => text()();
  IntColumn get versionNumber => integer()();
  TextColumn get name => text().nullable()();
  TextColumn get definitionJson => text()();
  DateTimeColumn get publishedAt => dateTime().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  IntColumn get version => integer()();
  IntColumn get changeSeq => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Espejo local de `record_attachment` (Paso 22): qué foto o firma pertenece a
/// qué registro.
///
/// La escribe la captura (en la misma transacción que el registro, su
/// operación de outbox y la cola de subida) y la actualiza el pull. Es lo que
/// permite enseñar al agente "con fotos pendientes de subir": el `sha256`
/// enlaza cada adjunto con su fila en `AttachmentQueue`.
class RecordAttachments extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  TextColumn get recordId => text()();
  TextColumn get sha256 => text()();

  /// `foto` | `firma` | `doc` (contrato `RecordAttachment.role`).
  TextColumn get role => text()();
  TextColumn get caption => text().nullable()();
  DateTimeColumn get capturedAt => dateTime()();

  /// `order` del contrato (palabra reservada en SQL: se renombra aquí).
  IntColumn get position => integer()();

  /// `null` hasta que el servidor la confirma.
  IntColumn get version => integer().nullable()();
  IntColumn get changeSeq => integer().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Espejo local de `Assignment` (Fase B): trabajo planificado que origina
/// registros. Llega por el pull y el cliente no la modifica. Todas las de
/// la organización: la pantalla filtra las del
/// agente.
class Assignments extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  IntColumn get version => integer()();
  IntColumn get changeSeq => integer().nullable()();
  TextColumn get templateVersionId => text()();
  TextColumn get assignedTo => text()();
  TextColumn get title => text().nullable()();
  DateTimeColumn get scheduledFor => dateTime().nullable()();
  RealColumn get lat => real().nullable()();
  RealColumn get lon => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Avance de campo (costos, etapa 1): tareas del cronograma de las que el
/// usuario con sesión es responsable, tal como las entrega
/// `GET /v1/projects/tasks`. `ScheduleTaskSync` las reemplaza enteras cuando la
/// lista cambia: lo que deja de venir (tarea retirada, responsabilidad
/// quitada) desaparece.
@DataClassName('ScheduleTaskRow')
class ScheduleTasks extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();

  /// De quién es la lista: en un teléfono compartido solo se ofrecen las del
  /// usuario con sesión (`ScheduleTaskRepository.forUser`).
  TextColumn get userId => text()();
  TextColumn get projectId => text()();
  TextColumn get projectName => text()();
  TextColumn get wbs => text()();
  TextColumn get outlineNumber => text()();
  TextColumn get name => text()();

  /// % del último registro validado de la tarea; `null` si no hay.
  RealColumn get lastValidatedPct => real().nullable()();

  /// Costos, pieza 4b: `quantities` si la tarea tiene ítems planeados (la captura
  /// pide cantidades en vez del %); `pct` en el resto.
  TextColumn get measuredBy => text().withDefault(const Constant('pct'))();

  /// Orden en que llegó (proyecto y orden del Project).
  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// `version` de la última lista de tareas descargada (fila única, `id` = 0):
/// se reenvía para que el servidor conteste "sin cambios".
@DataClassName('ScheduleTaskListState')
class ScheduleTaskState extends Table {
  IntColumn get id => integer().clientDefault(() => 0)();
  TextColumn get orgId => text()();
  TextColumn get userId => text()();
  TextColumn get version => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Costos, pieza 4b: ítems planeados de cada tarea (`FieldTask.planned_items`). Se
/// reemplazan junto con la lista de tareas.
@DataClassName('TaskPlannedItemRow')
class TaskPlannedItems extends Table {
  TextColumn get taskId => text()();
  TextColumn get itemId => text()();
  TextColumn get code => text()();
  TextColumn get description => text()();
  TextColumn get unit => text()();
  RealColumn get plannedQuantity => real()();

  /// Lo validado en la tarea a la fecha de la última descarga (`executed_quantity`).
  RealColumn get validatedQuantity => real()();
  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {taskId, itemId};
}

/// Costos, pieza 4b: dónde se puede precisar la ubicación de una fila de cantidad
/// (`FieldTask.location_options`): la ubicación de la tarea y sus descendientes.
@DataClassName('TaskLocationOptionRow')
class TaskLocationOptions extends Table {
  TextColumn get taskId => text()();
  TextColumn get locationId => text()();
  TextColumn get label => text()();

  /// Es la ubicación de la propia tarea (`FieldTask.location`); las demás la precisan.
  BoolColumn get isTaskLocation => boolean()();
  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {taskId, locationId};
}

/// Costos, pieza 4b: ítems medibles del presupuesto vigente de cada proyecto
/// (`FieldTaskList.project_items`), para "Agregar ítem no planeado".
@DataClassName('ProjectItemRow')
class ProjectItems extends Table {
  TextColumn get projectId => text()();
  TextColumn get itemId => text()();
  TextColumn get code => text()();
  TextColumn get description => text()();
  TextColumn get unit => text()();
  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {projectId, itemId};
}

/// Costos, pieza 4b: código, descripción y unidad de cada ítem visto alguna vez. A
/// diferencia del catálogo, no se reemplaza: un ítem que sale del presupuesto vigente
/// (p. ej. se volvió capítulo) se sigue pudiendo nombrar en el detalle de un registro o
/// en un rechazo del servidor.
@DataClassName('KnownItemRow')
class KnownItems extends Table {
  TextColumn get itemId => text()();
  TextColumn get code => text()();
  TextColumn get description => text()();
  TextColumn get unit => text()();

  @override
  Set<Column> get primaryKey => {itemId};
}

/// Espejo local de la lista de equipos visibles (`GET /v1/equipment`), para
/// consultarlos sin red. Cada fila guarda el JSON del servidor tal como llegó:
/// la tabla no interpreta la ficha. Añadida en `schemaVersion` 10.
@DataClassName('EquipmentCacheRow')
class EquipmentCache extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  TextColumn get code => text()();
  TextColumn get qrIdentifier => text()();
  TextColumn get dataJson => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Huella (`version`) de la última lista de equipos descargada, para que el
/// servidor conteste "sin cambios". Una sola fila (`id = 0`).
@DataClassName('EquipmentCatalogMetaRow')
class EquipmentCatalogMeta extends Table {
  IntColumn get id => integer().clientDefault(() => 0)();
  TextColumn get orgId => text()();
  TextColumn get version => text()();
  DateTimeColumn get fetchedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Lecturas de medidor tomadas en campo y todavía sin confirmar por el
/// servidor. El `id` lo genera el teléfono y hace el reenvío idempotente.
/// `state`: `pending` (se enviará) o `rejected` (el servidor la rechazó y no
/// se reintenta; `lastError` dice por qué). `userId` atribuye la lectura a
/// quien la tomó (teléfono compartido). Añadida en `schemaVersion` 10.
@DataClassName('MeterReadingOutboxRow')
class MeterReadingOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  TextColumn get userId => text()();
  TextColumn get equipmentId => text()();
  TextColumn get meterUnit => text()();
  RealColumn get value => real()();
  DateTimeColumn get readAt => dateTime()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get state => text().withDefault(const Constant('pending'))();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Preoperacionales tomados en campo y todavía sin confirmar por el servidor.
/// Misma idea que `MeterReadingOutbox`: `id` propio (idempotencia), `state`
/// `pending` o `rejected`, y `userId` para atribuir en un teléfono compartido.
/// `itemsJson` guarda las respuestas `[{item_id, ok, note}]`. Añadida en
/// `schemaVersion` 11.
@DataClassName('InspectionOutboxRow')
class InspectionOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  TextColumn get userId => text()();
  TextColumn get equipmentId => text()();
  DateTimeColumn get capturedAt => dateTime()();
  TextColumn get meterUnit => text().nullable()();
  RealColumn get meterValue => real().nullable()();
  TextColumn get itemsJson => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get state => text().withDefault(const Constant('pending'))();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Catálogo de combustible (estaciones y tanques propios) tal como llegó de
/// `GET /v1/fuel/catalog`, para elegir el origen de un tanqueo sin red. Una
/// sola fila (`id = 0`). Añadida en `schemaVersion` 12.
@DataClassName('FuelCatalogRow')
class FuelCatalogCache extends Table {
  IntColumn get id => integer().clientDefault(() => 0)();
  TextColumn get orgId => text()();
  TextColumn get version => text()();
  TextColumn get dataJson => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tanqueos tomados en campo y todavía sin confirmar por el servidor. Misma
/// idea que `MeterReadingOutbox`: `id` propio (idempotencia), `state`
/// `pending` o `rejected`, y `userId` para atribuir en un teléfono compartido.
/// Añadida en `schemaVersion` 12.
@DataClassName('FuelFillOutboxRow')
class FuelFillOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  TextColumn get userId => text()();
  TextColumn get equipmentId => text()();
  TextColumn get source => text()();
  TextColumn get stationId => text().nullable()();
  TextColumn get storeId => text().nullable()();
  TextColumn get fuelType => text().withDefault(const Constant('acpm'))();
  TextColumn get voucherNumber => text()();
  DateTimeColumn get filledAt => dateTime()();
  RealColumn get gallons => real()();
  TextColumn get meterUnit => text().nullable()();
  RealColumn get meterValue => real().nullable()();
  TextColumn get workFront => text().withDefault(const Constant(''))();
  TextColumn get driverName => text().withDefault(const Constant(''))();
  TextColumn get driverDocument => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get state => text().withDefault(const Constant('pending'))();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Catálogo de transporte (tramos, materiales, vehículos de terceros y
/// personas) tal como llegó de `GET /v1/transport/catalog`. Una sola fila
/// (`id = 0`). Añadida en `schemaVersion` 13.
@DataClassName('TransportCatalogRow')
class TransportCatalogCache extends Table {
  IntColumn get id => integer().clientDefault(() => 0)();
  TextColumn get orgId => text()();
  TextColumn get version => text()();
  TextColumn get dataJson => text()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Viajes tomados en campo y todavía sin confirmar por el servidor. Misma idea
/// que las demás colas: `id` propio (idempotencia), `state` `pending` o
/// `rejected`, y `userId` para atribuir en un teléfono compartido. Lleva un
/// equipo propio o un vehículo de terceros, nunca los dos. Añadida en
/// `schemaVersion` 13.
@DataClassName('TripOutboxRow')
class TripOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  TextColumn get userId => text()();
  TextColumn get equipmentId => text().nullable()();
  TextColumn get vehicleId => text().nullable()();
  TextColumn get routeId => text()();
  TextColumn get materialId => text()();
  RealColumn get volumeM3 => real()();
  DateTimeColumn get recordedAt => dateTime()();
  TextColumn get requestedBy => text()();
  TextColumn get dispatchedBy => text()();
  TextColumn get receivedBy => text()();
  TextColumn get driverName => text().withDefault(const Constant(''))();
  TextColumn get driverDocument => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get state => text().withDefault(const Constant('pending'))();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Reportes de uso de un equipo tomados en campo y todavía sin confirmar por el
/// servidor. Misma idea que las demás colas: `id` propio (idempotencia),
/// `state` `pending` o `rejected`, y `userId` para atribuir en un teléfono
/// compartido. La fecha va como `AAAA-MM-DD` y las horas como minutos desde la
/// medianoche (son hora local de quien trabajó, no instantes). Añadida en
/// `schemaVersion` 14.
@DataClassName('UsageReportOutboxRow')
class UsageReportOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get orgId => text()();
  TextColumn get userId => text()();
  TextColumn get equipmentId => text()();
  TextColumn get projectId => text()();
  TextColumn get usageDate => text()();
  IntColumn get startMinutes => integer()();
  IntColumn get endMinutes => integer()();
  TextColumn get activity => text()();
  TextColumn get location => text().withDefault(const Constant(''))();
  RealColumn get startMeter => real().nullable()();
  RealColumn get endMeter => real().nullable()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get state => text().withDefault(const Constant('pending'))();
  TextColumn get lastError => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
