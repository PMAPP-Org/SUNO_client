// Base de datos local (Paso 11, ADR-002): SQLite vía Drift + SQLCipher,
// modo WAL, `synchronous=NORMAL`, un único executor de escritura.
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:meta/meta.dart';

import 'tables.dart';

part 'database.g.dart';

/// **Escritor único (RD-04, corrige H-04)**: QField desactivaba su
/// protección de concurrencia con un `#if 0` — la app terminaba con dos
/// rutas de código escribiendo la misma BD sin serializar entre sí. La
/// mitigación aquí no es solo disciplina: `AppDatabase.open()` lanza si se
/// llama una segunda vez en el mismo proceso, así que **no puede existir**
/// una segunda conexión de escritura al mismo archivo por error de
/// integración. Cualquier repositorio que necesite la BD recibe esta misma
/// instancia (inyectada vía Riverpod desde el Paso 22 en adelante) — nunca
/// construye la suya propia.
@DriftDatabase(
  tables: [
    Records,
    OutboxOps,
    AttachmentQueue,
    SyncCursor,
    FormTemplateVersions,
    RecordAttachments,
    Assignments,
    ScheduleTasks,
    ScheduleTaskState,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase._(super.executor);

  static bool _instanceOpened = false;

  /// La única forma válida de abrir la BD real de la app. `executor` ya
  /// debe tener la clave de cifrado fijada (`createEncryptedExecutor`) —
  /// esta clase no sabe nada de SQLCipher, solo aplica la regla de "una
  /// sola instancia por proceso".
  factory AppDatabase.open(QueryExecutor executor) {
    if (_instanceOpened) {
      throw StateError(
        'AppDatabase ya tiene una instancia abierta en este proceso. '
        'RD-04 (doc 08 ADR-002) exige un único executor de escritura: '
        'una segunda instancia sobre el mismo archivo reintroduciría '
        'exactamente la clase de bug de concurrencia que QField tenía '
        'desactivada con un `#if 0` (hallazgo H-04). Reutiliza la '
        'instancia inyectada en vez de crear una nueva.',
      );
    }
    _instanceOpened = true;
    return AppDatabase._(executor);
  }

  /// Bypasea la guarda de instancia única — **solo para tests**, donde cada
  /// caso necesita su propia BD aislada (típicamente en memoria). Nunca usar
  /// en código de la app.
  @visibleForTesting
  factory AppDatabase.forTesting(QueryExecutor executor) => AppDatabase._(executor);

  @override
  int get schemaVersion => 1;

  // La app `com.suno.app` empieza en el esquema 1: ningún teléfono actualiza desde
  // la base de la app anterior (otro applicationId). El historial de migraciones
  // v1–v9 se reinició con el renombre al concepto "registro"; el próximo cambio
  // de esquema añade aquí su `onUpgrade` y su test de migración.
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => migrator.createAll(),
  );

  /// `null`: el dispositivo nunca hizo un pull/bootstrap exitoso todavía —
  /// `SyncEngine.pull()` lo trata como "usa `CURSOR_ZERO`" (equivalente a
  /// pedir todo desde el principio).
  Future<String?> readCursor() async {
    final row = await (select(syncCursor)..where((t) => t.id.equals(0))).getSingleOrNull();
    return row?.cursor;
  }

  Future<void> writeCursor(String cursor, {required DateTime now}) {
    return into(
      syncCursor,
    ).insertOnConflictUpdate(SyncCursorCompanion.insert(cursor: cursor, updatedAt: now));
  }

  /// Olvida el cursor: el siguiente pull pide todo desde el principio. Lo usa
  /// la caché de plantillas cuando encuentra una fila corrupta (Paso 21): los
  /// upserts del pull son idempotentes, así que repetirlo solo cuesta datos.
  Future<void> resetCursor() => (delete(syncCursor)..where((t) => t.id.equals(0))).go();

  /// La versión de la última lista de tareas del cronograma, si hay.
  Future<ScheduleTaskListState?> readScheduleTaskState() =>
      (select(scheduleTaskState)..where((t) => t.id.equals(0))).getSingleOrNull();

  /// Reemplaza la lista de tareas del cronograma y su versión (costos, etapa
  /// 1) en una sola transacción: nunca queda media lista.
  Future<void> replaceScheduleTasks({
    required String orgId,
    required String userId,
    required String version,
    required List<ScheduleTasksCompanion> rows,
    required DateTime now,
  }) {
    return transaction(() async {
      await delete(scheduleTasks).go();
      await batch((b) => b.insertAll(scheduleTasks, rows));
      await into(scheduleTaskState).insertOnConflictUpdate(
        ScheduleTaskStateCompanion.insert(orgId: orgId, userId: userId, version: version, updatedAt: now),
      );
    });
  }

  /// El outbox es una tabla más del mismo esquema (ADR-002): "guardar
  /// registro + encolar operación" es una única transacción SQLite, no dos
  /// pasos con riesgo de divergencia si el proceso muere entre medias.
  /// `test/data/local/database_test.dart` verifica la atomicidad real
  /// forzando un fallo a mitad de una transacción equivalente.
  Future<void> saveRecordWithOutboxOp({
    required RecordsCompanion record,
    required OutboxOpsCompanion outboxOp,
  }) {
    return transaction(() async {
      await into(records).insertOnConflictUpdate(record);
      await into(outboxOps).insertOnConflictUpdate(outboxOp);
    });
  }

  /// Guarda un registro capturado **entera** en una sola transacción (Paso 22,
  /// tarea 5): la fila del registro, sus adjuntos, las operaciones de outbox
  /// (la del registro primero; ver `SyncEngine.drainOutbox` sobre el orden) y
  /// las entradas de la cola de subida. Si algo falla, no queda nada a medias:
  /// ni un registro sin sus fotos ni una foto encolada sin registro.
  ///
  /// La cola de subida usa `insertOrIgnore`: si ese mismo contenido ya estaba
  /// encolado o subido (otro registro con la misma foto), no se reinicia su
  /// estado ni se sube dos veces.
  Future<void> saveRecordCapture({
    required RecordsCompanion record,
    required List<RecordAttachmentsCompanion> attachments,
    required List<OutboxOpsCompanion> outboxOps,
    required List<AttachmentQueueCompanion> uploads,
  }) {
    return transaction(() async {
      await into(records).insert(record);
      for (final attachment in attachments) {
        await into(recordAttachments).insert(attachment);
      }
      for (final op in outboxOps) {
        await into(this.outboxOps).insert(op);
      }
      for (final upload in uploads) {
        await into(attachmentQueue).insert(upload, mode: InsertMode.insertOrIgnore);
      }
    });
  }
}

/// El executor de la BD real de la app: SQLCipher (vía el hook `source:
/// sqlcipher` de `pubspec.yaml` — `sqlcipher_flutter_libs` está
/// descontinuado desde `sqlite3` v3.x) + modo WAL + `synchronous=NORMAL`.
///
/// **Orden de las pragmas, no es arbitrario**: `PRAGMA key` tiene que ir
/// primero — es lo que le dice a SQLCipher cómo descifrar el archivo, y
/// ninguna otra sentencia (ni siquiera leer el `journal_mode` actual) puede
/// ejecutarse antes sin fallar contra un archivo cifrado ya existente.
///
/// **Por qué interpolar `encryptionKey` directamente en el SQL es seguro
/// aquí y no en ningún otro sitio del código**: SQLite no permite
/// parametrizar el valor de un `PRAGMA` (no es una sentencia DML), así que
/// la alternativa sería escribir un escapador de comillas a mano — más
/// superficie de bug que la que resuelve. Es seguro porque `encryptionKey`
/// **nunca** viene de fuera del dispositivo: la genera
/// `EncryptionKeyStore` con un alfabeto base64url que no contiene comillas
/// ni backslash. Si esta función alguna vez recibe una clave de otro
/// origen, esa garantía deja de sostenerse y hay que revisar esto primero.
QueryExecutor createEncryptedExecutor({required File file, required String encryptionKey}) {
  return NativeDatabase.createInBackground(
    file,
    setup: (rawDb) {
      rawDb.execute("PRAGMA key = '$encryptionKey';");
      rawDb.execute('PRAGMA journal_mode=WAL;');
      rawDb.execute('PRAGMA synchronous=NORMAL;');
    },
  );
}
