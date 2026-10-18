// Mapas base offline (Fase B): solo se activa lo verificado por sha256, lo
// retirado se borra, y sin red no se toca nada.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:visitacampo/core/basemaps/basemap_manager.dart';

import 'fake_basemap_transport.dart';

void main() {
  late Directory dir;
  late FakeBasemapTransport transport;
  late BasemapManager manager;
  final bytes = List<int>.generate(4096, (i) => i % 251);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('basemaps-test');
    transport = FakeBasemapTransport();
    manager = BasemapManager(transport: transport, directory: dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('descarga, verifica y lo deja disponible offline', () async {
    final a = info('a', bytes);
    transport
      ..offered = [a]
      ..contents['a'] = bytes;

    expect((await manager.refresh()).entries.single.downloaded, isFalse);
    expect(await manager.download(a), isA<BasemapDownloaded>());

    final local = await manager.downloaded();
    expect(local.single.info.id, 'a');
    expect(File(local.single.localPath!).lengthSync(), bytes.length);
  });

  test('un archivo que no coincide con su sha256 se descarta', () async {
    final a = info('a', bytes, sha: 'f' * 64);
    transport
      ..offered = [a]
      ..contents['a'] = bytes;

    expect(await manager.download(a), isA<BasemapCorrupted>());
    expect(await manager.downloaded(), isEmpty);
    expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.part')), isEmpty);
  });

  test('sin red: no se descarga y lo descargado sigue', () async {
    final a = info('a', bytes);
    transport
      ..offered = [a]
      ..contents['a'] = bytes;
    await manager.download(a);

    transport
      ..offered = null
      ..failFetch = true;
    final result = await manager.refresh();
    expect(result.online, isFalse);
    expect(result.entries.single.downloaded, isTrue);
  });

  test('un fallo a mitad de descarga no deja nada a medias', () async {
    final a = info('a', bytes);
    transport
      ..offered = [a]
      ..contents['a'] = bytes
      ..failFetch = true;
    expect(await manager.download(a), isA<BasemapUnavailable>());
    expect(await manager.downloaded(), isEmpty);
  });

  test('lo que el servidor retiró se borra del teléfono', () async {
    final a = info('a', bytes);
    transport
      ..offered = [a]
      ..contents['a'] = bytes;
    await manager.download(a);
    final path = (await manager.downloaded()).single.localPath!;

    transport.offered = [];
    await manager.refresh();
    expect(await manager.downloaded(), isEmpty);
    expect(File(path).existsSync(), isFalse);
  });

  test('si el paquete cambió de contenido, lo local cuenta como no descargado', () async {
    final a = info('a', bytes);
    transport
      ..offered = [a]
      ..contents['a'] = bytes;
    await manager.download(a);

    final changed = [...bytes, 1, 2, 3];
    transport.offered = [info('a', changed)];
    expect((await manager.refresh()).entries.single.downloaded, isFalse);
  });

  test('un sha256 que no es hexadecimal no se convierte en ruta', () async {
    final evil = info('x', bytes, sha: '../../etc/passwd');
    transport.contents['x'] = bytes;
    await expectLater(manager.download(evil), throwsArgumentError);
  });

  group('descarga automática (syncAll)', () {
    test('baja todo lo que ofrece la organización sin que el agente lo pida', () async {
      final otros = List<int>.generate(1000, (i) => (i * 7) % 256);
      transport
        ..offered = [info('a', bytes), info('b', otros)]
        ..contents['a'] = bytes
        ..contents['b'] = otros;
      final seen = <String>[];
      manager.progress.addListener(() {
        final value = manager.progress.value;
        if (value != null && !seen.contains(value.name)) seen.add(value.name);
      });

      await manager.syncAll();
      expect((await manager.downloaded()).map((e) => e.info.id), unorderedEquals(['a', 'b']));
      expect(seen, ['Mapa a', 'Mapa b'], reason: 'el aviso de inicio muestra cuál baja');
      expect(manager.progress.value, isNull, reason: 'al terminar, sin aviso');
    });

    test('dos llamadas a la vez no descargan dos veces', () async {
      transport
        ..offered = [info('a', bytes)]
        ..contents['a'] = bytes;
      await Future.wait([manager.syncAll(), manager.syncAll()]);
      expect(transport.fetches, 1);
    });

    test('un paquete corrupto no se reintenta en bucle en la misma sesión', () async {
      transport
        ..offered = [info('a', bytes, sha: 'e' * 64)]
        ..contents['a'] = bytes;
      await manager.syncAll();
      await manager.syncAll();
      expect(transport.fetches, 1);
      expect(await manager.downloaded(), isEmpty);
    });

    test('sin red no hace nada', () async {
      transport.offered = null;
      await manager.syncAll();
      expect(transport.fetches, 0);
    });
  });

  group('descarga reanudable', () {
    test('si la red se corta, el siguiente intento continúa donde quedó', () async {
      final a = info('a', bytes);
      transport
        ..offered = [a]
        ..contents['a'] = bytes
        ..cutAfter = 1000;

      expect(await manager.download(a), isA<BasemapUnavailable>());
      expect(await manager.download(a), isA<BasemapUnavailable>(), reason: 'otro corte');
      transport.cutAfter = null;
      expect(await manager.download(a), isA<BasemapDownloaded>());

      expect(transport.froms, [0, 1000, 2000], reason: 'nunca vuelve a empezar de cero');
      expect(File((await manager.downloaded()).single.localPath!).readAsBytesSync(), bytes);
    });

    test('una parte ya completa solo se verifica, sin volver a bajar nada', () async {
      final a = info('a', bytes);
      transport
        ..offered = [a]
        ..contents['a'] = bytes;
      File('${dir.path}/${a.sha256}.mbtiles.part').writeAsBytesSync(bytes);

      expect(await manager.download(a), isA<BasemapDownloaded>());
      expect(transport.fetches, 0);
    });

    test('una parte más grande que el paquete se descarta y empieza de cero', () async {
      final a = info('a', bytes);
      transport
        ..offered = [a]
        ..contents['a'] = bytes;
      File('${dir.path}/${a.sha256}.mbtiles.part').writeAsBytesSync([...bytes, 1, 2]);

      expect(await manager.download(a), isA<BasemapDownloaded>());
      expect(transport.froms, [0]);
    });
  });
}
