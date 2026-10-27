import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'companion_error_codes.dart';

/// Una mascota listada en el manifest remoto de Petdex (feature 006 / Petdex
/// remoto). Solo datos de catálogo; el arte se descarga bajo demanda.
class PetdexRemotePet {
  final String slug;
  final String displayName;
  final String submittedBy;

  /// Categoría del manifest: `character`, `creature` u `object` (u otra futura).
  final String kind;
  final Uri spritesheetUrl;
  final Uri petJsonUrl;
  final Uri zipUrl;

  const PetdexRemotePet({
    required this.slug,
    required this.displayName,
    required this.submittedBy,
    required this.kind,
    required this.spritesheetUrl,
    required this.petJsonUrl,
    required this.zipUrl,
  });

  /// Autor mostrable (cae a "Petdex" si el manifest no lo trae).
  String get author => submittedBy.trim().isEmpty ? 'Petdex' : submittedBy.trim();
}

/// Error de catálogo/descarga remota de Petdex. La UI lo captura y muestra un
/// aviso claro; **nunca** debe propagar un crash.
class PetdexRemoteException implements CompanionCodedError {
  /// Identificador estable del fallo, o texto libre de un doble de test.
  final String message;

  @override
  final CompanionErrorCode? code;

  /// Petdex no se pudo alcanzar (sin red, DNS, TLS), frente a una respuesta
  /// que llegó pero no sirve.
  final bool offline;
  PetdexRemoteException(this.message, {this.offline = false, this.code});

  /// Fallo propio del servicio: el mensaje es el código estable, sin texto de
  /// interfaz.
  PetdexRemoteException.coded(CompanionErrorCode code, {bool offline = false})
    : this(code.name, offline: offline, code: code);

  @override
  String toString() => 'PetdexRemoteException: $message';
}

/// Acceso **read-only** y seguro al catálogo remoto de Petdex.
///
/// Contrato verificado (2026-06-26): `GET https://petdex.dev/api/manifest`
/// redirige (307) a `https://assets.petdex.dev/manifests/petdex-v1.json`, un
/// manifest **estable y versionado** con `{generatedAt, total, pets:[{slug,
/// displayName, submittedBy, spritesheetUrl, petJsonUrl, zipUrl}]}`. El
/// `zip.zip` de cada mascota contiene `pet.json` + `spritesheet.webp` y se
/// instala con el **mismo pipeline validado** que la importación local
/// (`CompanionImportService.importFromZipBytes`), que infiere la geometría
/// 192×208 y escribe de forma atómica.
///
/// Seguridad: solo HTTPS, solo host [_allowedHost] (allowlist), con límites de
/// tamaño y timeouts; sin ejecutar nada, sin scraping de HTML, sin CLI/npx.
class PetdexRemoteService {
  PetdexRemoteService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Único host permitido para catálogo y assets (Cloudflare R2 de Petdex).
  static const String _allowedHost = 'assets.petdex.dev';

  /// URL canónica del manifest versionado (destino del 307 de /api/manifest).
  static final Uri manifestUrl =
      Uri.parse('https://$_allowedHost/manifests/petdex-v1.json');

  static const Duration _manifestTimeout = Duration(seconds: 20);
  static const Duration _zipTimeout = Duration(seconds: 45);

  /// Cap del manifest (es ~1 MB; margen amplio pero acotado).
  static const int _maxManifestBytes = 24 * 1024 * 1024;

  /// Cap de un ZIP de mascota (el import service vuelve a validar el tamaño).
  static const int _maxZipBytes = 32 * 1024 * 1024;

  bool _isAllowed(Uri uri) =>
      uri.scheme == 'https' && uri.host == _allowedHost;

  /// Descarga y parsea el manifest. Entradas malformadas o con URLs fuera de la
  /// allowlist se **descartan** (no rompen la lista). Lanza
  /// [PetdexRemoteException] si la red/JSON global falla.
  Future<List<PetdexRemotePet>> fetchManifest() async {
    final bytes = await _getCapped(manifestUrl, _maxManifestBytes, _manifestTimeout);
    final Object? root;
    try {
      root = jsonDecode(utf8.decode(bytes));
    } catch (e) {
      debugPrint('[petdex] excepción silenciada (se relanza como error propio): $e');
      throw PetdexRemoteException.coded(
        CompanionErrorCode.petdexManifestInvalid,
      );
    }
    if (root is! Map || root['pets'] is! List) {
      throw PetdexRemoteException.coded(
        CompanionErrorCode.petdexManifestFormat,
      );
    }
    final out = <PetdexRemotePet>[];
    for (final raw in (root['pets'] as List)) {
      final pet = _parsePet(raw);
      if (pet != null) out.add(pet);
    }
    if (out.isEmpty) {
      throw PetdexRemoteException.coded(
        CompanionErrorCode.petdexManifestEmpty,
      );
    }
    return out;
  }

  PetdexRemotePet? _parsePet(Object? raw) {
    if (raw is! Map) return null;
    final slug = (raw['slug'] ?? '').toString().trim();
    final displayName = (raw['displayName'] ?? '').toString().trim();
    final spritesheet = Uri.tryParse((raw['spritesheetUrl'] ?? '').toString());
    final petJson = Uri.tryParse((raw['petJsonUrl'] ?? '').toString());
    final zip = Uri.tryParse((raw['zipUrl'] ?? '').toString());
    if (slug.isEmpty ||
        spritesheet == null ||
        petJson == null ||
        zip == null ||
        !_isAllowed(spritesheet) ||
        !_isAllowed(petJson) ||
        !_isAllowed(zip)) {
      return null;
    }
    return PetdexRemotePet(
      slug: slug,
      displayName: displayName.isEmpty ? slug : displayName,
      submittedBy: (raw['submittedBy'] ?? '').toString(),
      kind: (raw['kind'] ?? '').toString().trim().toLowerCase(),
      spritesheetUrl: spritesheet,
      petJsonUrl: petJson,
      zipUrl: zip,
    );
  }

  /// Descarga el `zip.zip` de [pet] (validado por allowlist). Devuelve los bytes
  /// para entregárselos a `CompanionImportService.importFromZipBytes`.
  Future<Uint8List> downloadPetZip(PetdexRemotePet pet) async {
    if (!_isAllowed(pet.zipUrl)) {
      throw PetdexRemoteException.coded(CompanionErrorCode.petdexOrigin);
    }
    return _getCapped(pet.zipUrl, _maxZipBytes, _zipTimeout);
  }

  /// GET con allowlist, timeout y **tope de tamaño durante la descarga**
  /// (lee el stream y aborta si supera [maxBytes]).
  Future<Uint8List> _getCapped(Uri uri, int maxBytes, Duration timeout) async {
    if (!_isAllowed(uri)) {
      throw PetdexRemoteException.coded(CompanionErrorCode.petdexOrigin);
    }
    try {
      final req = http.Request('GET', uri);
      final res = await _client.send(req).timeout(timeout);
      if (res.statusCode != 200) {
        debugPrint('[petdex] respuesta HTTP ${res.statusCode}');
        throw PetdexRemoteException.coded(CompanionErrorCode.petdexHttp);
      }
      final declared = res.contentLength;
      if (declared != null && declared > maxBytes) {
        throw PetdexRemoteException.coded(CompanionErrorCode.petdexTooLarge);
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res.stream.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw PetdexRemoteException.coded(CompanionErrorCode.petdexTooLarge);
        }
      }
      return builder.takeBytes();
    } on PetdexRemoteException {
      rethrow;
    } on TimeoutException {
      throw PetdexRemoteException.coded(CompanionErrorCode.petdexTimeout);
    } catch (e) {
      debugPrint('[petdex] fallo de red: $e');
      throw PetdexRemoteException.coded(
        CompanionErrorCode.petdexNetwork,
        offline: true,
      );
    }
  }

  void dispose() => _client.close();
}
