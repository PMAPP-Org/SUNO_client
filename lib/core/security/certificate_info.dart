// `CertificateInfo` — lo que el usuario necesita ver de un certificado para
// decidir si confía en él (Paso 16, ADR-009), y lo que `TrustStore` necesita
// para fijarlo: la huella SHA-256 de su clave pública (SPKI).
//
// Se lee del DER del certificado con un lector ASN.1 mínimo, en vez de añadir
// un paquete X.509 (otra dependencia en el módulo más sensible del cliente,
// OWASP A03): solo se recorren las estructuras que hacen falta —
// `tbsCertificate` → `subjectPublicKeyInfo` y la extensión `subjectAltName`.
// Un DER que no se entiende no se "adivina": `fromDer` lanza
// `FormatException` y quien llama lo trata como certificado rechazado.
//
// Por qué la huella de la **clave pública** y no la del certificado: el pin
// sobrevive a la renovación del certificado si el servidor conserva su clave
// (lo habitual con Let's Encrypt/Caddy), y es lo que el estándar de pinning
// (RFC 7469) fija. La huella del certificado completo también se muestra,
// porque es la que un administrador compara con `openssl x509 -fingerprint`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class CertificateInfo {
  const CertificateInfo({
    required this.spkiSha256,
    required this.sha256Fingerprint,
    required this.subject,
    required this.issuer,
    required this.subjectAltNames,
    required this.notBefore,
    required this.notAfter,
  });

  /// Lee un certificado X.509 en DER. `subject`/`issuer`/validez vienen ya
  /// decodificados por `dart:io` (`X509Certificate`), así que se reciben
  /// aparte; del DER solo hace falta lo que `dart:io` no expone.
  factory CertificateInfo.fromDer(
    Uint8List der, {
    required String subject,
    required String issuer,
    required DateTime notBefore,
    required DateTime notAfter,
  }) {
    final parsed = _parse(der);
    return CertificateInfo(
      spkiSha256: base64.encode(sha256.convert(parsed.spki).bytes),
      sha256Fingerprint: _hexColon(sha256.convert(der).bytes),
      subject: subject,
      issuer: issuer,
      subjectAltNames: parsed.altNames,
      notBefore: notBefore.toUtc(),
      notAfter: notAfter.toUtc(),
    );
  }

  /// Pin: SHA-256 del `SubjectPublicKeyInfo` en DER, en base64 (formato de
  /// RFC 7469 y de `openssl ... | openssl dgst -sha256 -binary | base64`).
  final String spkiSha256;

  /// SHA-256 del certificado completo, en hexadecimal `AB:CD:...`.
  final String sha256Fingerprint;

  final String subject;
  final String issuer;

  /// DNS e IP del `subjectAltName`, en el orden del certificado.
  final List<String> subjectAltNames;
  final DateTime notBefore;
  final DateTime notAfter;

  /// El `CN=` del sujeto, o el sujeto entero si no tiene CN.
  String get commonName => _rdn(subject, 'CN') ?? subject;

  bool isValidAt(DateTime now) =>
      !now.isBefore(notBefore) && !now.isAfter(notAfter);
}

String? _rdn(String dn, String attribute) {
  // `dart:io` entrega el DN como `/C=CO/O=Org/CN=host` (estilo OpenSSL).
  for (final part in dn.split('/')) {
    final eq = part.indexOf('=');
    if (eq > 0 && part.substring(0, eq).trim().toUpperCase() == attribute) {
      return part.substring(eq + 1).trim();
    }
  }
  return null;
}

String _hexColon(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');

// --- Lector DER mínimo -------------------------------------------------------

class _Tlv {
  _Tlv(this.tag, this.start, this.contentStart, this.end);

  final int tag;
  final int start; // primer byte del TLV completo (el tag)
  final int contentStart;
  final int end; // exclusivo

  bool get isConstructed => tag & 0x20 != 0;
}

_Tlv _read(Uint8List der, int offset, int limit) {
  if (offset + 2 > limit) throw const FormatException('DER truncado');
  final tag = der[offset];
  if (tag & 0x1f == 0x1f) {
    throw const FormatException('tag DER de varios bytes no admitido');
  }
  var pos = offset + 1;
  var length = der[pos++];
  if (length & 0x80 != 0) {
    final count = length & 0x7f;
    if (count == 0 || count > 4 || pos + count > limit) {
      throw const FormatException('longitud DER no admitida');
    }
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | der[pos++];
    }
  }
  final end = pos + length;
  if (end > limit) throw const FormatException('DER truncado');
  return _Tlv(tag, offset, pos, end);
}

List<_Tlv> _children(Uint8List der, _Tlv parent) {
  if (!parent.isConstructed) {
    throw const FormatException('se esperaba un elemento construido');
  }
  final children = <_Tlv>[];
  var pos = parent.contentStart;
  while (pos < parent.end) {
    final child = _read(der, pos, parent.end);
    children.add(child);
    pos = child.end;
  }
  return children;
}

/// OID 2.5.29.17 (subjectAltName) en DER.
const _sanOid = [0x55, 0x1d, 0x11];

({Uint8List spki, List<String> altNames}) _parse(Uint8List der) {
  final certificate = _read(der, 0, der.length);
  if (certificate.tag != 0x30) {
    throw const FormatException('no es un certificado X.509');
  }
  final tbs = _children(der, certificate).first;
  final fields = _children(der, tbs);

  // tbsCertificate: [0] version (opcional), serial, signature, issuer,
  // validity, subject, subjectPublicKeyInfo, ... [3] extensions.
  var index = fields.isNotEmpty && fields.first.tag == 0xa0 ? 1 : 0;
  index += 5; // serial, signature, issuer, validity, subject
  if (index >= fields.length) {
    throw const FormatException('tbsCertificate incompleto');
  }
  final spkiTlv = fields[index];
  if (spkiTlv.tag != 0x30) {
    throw const FormatException('subjectPublicKeyInfo no encontrado');
  }
  final spki = Uint8List.sublistView(der, spkiTlv.start, spkiTlv.end);

  final altNames = <String>[];
  for (final field in fields.skip(index + 1)) {
    if (field.tag != 0xa3) continue; // [3] extensions
    final extensions = _children(der, _children(der, field).single);
    for (final extension in extensions) {
      final parts = _children(der, extension);
      final oid = der.sublist(parts.first.contentStart, parts.first.end);
      if (!_listEquals(oid, _sanOid)) continue;
      final value = parts.last; // OCTET STRING con el GeneralNames dentro
      final names = _read(der, value.contentStart, value.end);
      for (final name in _children(der, names)) {
        final content = der.sublist(name.contentStart, name.end);
        switch (name.tag) {
          case 0x82: // dNSName
            altNames.add(ascii.decode(content, allowInvalid: true));
          case 0x87: // iPAddress
            altNames.add(_ip(content));
        }
      }
    }
  }
  return (spki: spki, altNames: altNames);
}

String _ip(List<int> bytes) {
  if (bytes.length == 4) return bytes.join('.');
  final groups = <String>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    groups.add(((bytes[i] << 8) | bytes[i + 1]).toRadixString(16));
  }
  return groups.join(':');
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
