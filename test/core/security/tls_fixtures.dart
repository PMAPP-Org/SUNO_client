// Servidores HTTPS reales en loopback y certificados generados con openssl
// para las pruebas de `TrustStore` (Paso 16).
//
// Nada de `.pem` versionados (`.gitignore` los excluye y una llave privada en
// un repo público dispara los escáneres de secretos; ver también
// `test/core/auth/tls_default_rejects_invalid_cert_test.dart`). `openssl`
// está en los runners de CI y en Git for Windows; si falta, las pruebas
// **fallan**, nunca se saltan: son la prueba de H-01.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class Pem {
  Pem({required this.cert, required this.key});

  final String cert;
  final String key;
}

class CertFactory {
  CertFactory._(this.dir);

  final Directory dir;
  var _n = 0;

  static Future<CertFactory> create() async {
    final dir = await Directory.systemTemp.createTemp('visitacampo_trust_');
    addTearDown(() => dir.delete(recursive: true));
    return CertFactory._(dir);
  }

  String _path(String name) => p.join(dir.path, name);

  Future<void> _openssl(List<String> args) async {
    final result = await Process.run('openssl', args);
    if (result.exitCode != 0) {
      throw StateError('openssl ${args.first} falló: ${result.stderr}');
    }
  }

  /// Certificado autofirmado para `localhost` (con SAN).
  Future<Pem> selfSigned({String cn = 'localhost'}) async {
    final n = _n++;
    final pem = Pem(cert: _path('self$n.pem'), key: _path('self$n.key'));
    await _openssl([
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', //
      '-keyout', pem.key, '-out', pem.cert, '-days', '1',
      '-subj',
      '/CN=$cn',
      '-addext',
      'subjectAltName=DNS:localhost,IP:127.0.0.1',
    ]);
    return pem;
  }

  /// Una CA propia.
  Future<Pem> ca({String cn = 'VisitaCampo Test CA'}) async {
    final n = _n++;
    final pem = Pem(cert: _path('ca$n.pem'), key: _path('ca$n.key'));
    await _openssl([
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', //
      '-keyout', pem.key, '-out', pem.cert, '-days', '1', '-subj', '/CN=$cn',
      '-addext', 'basicConstraints=critical,CA:TRUE',
      '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
    ]);
    return pem;
  }

  /// Certificado de servidor para `localhost` firmado por [ca]. Con
  /// [withChain], el `.pem` incluye también la CA (cadena completa).
  Future<Pem> signedBy(Pem ca, {bool withChain = false}) async {
    final n = _n++;
    final leaf = Pem(cert: _path('leaf$n.pem'), key: _path('leaf$n.key'));
    final csr = _path('leaf$n.csr');
    final ext = _path('leaf$n.ext');
    await File(
      ext,
    ).writeAsString('subjectAltName=DNS:localhost,IP:127.0.0.1\n');
    await _openssl([
      'req', '-new', '-newkey', 'rsa:2048', '-nodes', //
      '-keyout', leaf.key, '-out', csr, '-subj', '/CN=localhost',
    ]);
    await _openssl([
      'x509', '-req', '-in', csr, '-CA', ca.cert, '-CAkey', ca.key, //
      '-CAcreateserial', '-out', leaf.cert, '-days', '1', '-extfile', ext,
    ]);
    if (withChain) {
      final chain =
          await File(leaf.cert).readAsString() +
          await File(ca.cert).readAsString();
      await File(leaf.cert).writeAsString(chain);
    }
    return leaf;
  }

  /// Pin SPKI calculado por openssl (no por el código bajo prueba).
  Future<String> spkiPin(Pem pem) async {
    final pub = _path('pub${_n++}.der');
    await _openssl([
      'x509',
      '-in',
      pem.cert,
      '-pubkey',
      '-noout',
      '-out',
      '$pub.pem',
    ]);
    await _openssl([
      'pkey',
      '-pubin',
      '-in',
      '$pub.pem',
      '-outform',
      'der',
      '-out',
      pub,
    ]);
    final bytes = await File(pub).readAsBytes();
    final digest = await Process.run('openssl', [
      'dgst',
      '-sha256',
      '-binary',
      pub,
    ], stdoutEncoding: null);
    if (digest.exitCode != 0) throw StateError('openssl dgst falló');
    expect(bytes, isNotEmpty);
    return base64.encode(digest.stdout as List<int>);
  }
}

/// Servidor HTTPS que cuenta las peticiones que **le llegan**: con un pin
/// incorrecto tiene que quedarse en cero (nada se envía antes de verificar).
class TlsServer {
  TlsServer._(this._server);

  final HttpServer _server;
  int requests = 0;

  int get port => _server.port;
  String get baseUrl => 'https://localhost:$port';

  static Future<TlsServer> start(Pem pem, {int port = 0}) async {
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain(pem.cert)
      ..usePrivateKey(pem.key);
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      port,
      context,
    );
    final tls = TlsServer._(server);
    unawaited(
      server.forEach((request) {
        tls.requests++;
        request.response
          ..statusCode = 200
          ..write('{"ok":true}')
          ..close();
      }),
    );
    addTearDown(tls.close);
    return tls;
  }

  Future<void> close() => _server.close(force: true);
}

/// Contexto de cliente que solo confía en [ca] (en vez de las CA del sistema).
SecurityContext trusting(Pem ca) =>
    SecurityContext(withTrustedRoots: false)..setTrustedCertificates(ca.cert);
