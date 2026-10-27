import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:archive/archive.dart';

import '../../models/profile_pet.dart';
import '../models/companion.dart';
import '../models/companion_animation_state.dart';
import 'companion_error_codes.dart';
import 'companion_manifest_parser.dart';

/// Error de importación de una mascota custom local.
///
/// Lleva un [CompanionErrorCode] estable, nunca texto de interfaz: la pantalla
/// lo traduce con `localizedCompanionError`.
class CompanionImportException implements CompanionCodedError {
  @override
  final CompanionErrorCode code;

  CompanionImportException(this.code);

  /// Identificador estable del fallo (el `name` del código).
  String get message => code.name;

  @override
  String toString() => 'CompanionImportException: ${code.name}';
}

/// Importa una mascota custom **local** desde un ZIP (`pet.json` +
/// `spritesheet.webp`/`.png`) al almacenamiento de la app.
///
/// Es deliberadamente **puro y offline**: recibe los bytes del ZIP y un
/// directorio de almacenamiento ya resuelto. No usa red, ni `file_picker`, ni
/// `path_provider`, ni ejecuta nada — solo valida y copia ficheros. La capa de
/// UI resuelve los bytes (selector de archivos) y el directorio (sandbox) y
/// delega aquí, de modo que toda la lógica de validación es testeable con
/// fixtures.
///
/// Garantías de seguridad:
/// - rechaza ZIPs/manifiestos/imágenes que excedan los límites de tamaño;
/// - rechaza rutas peligrosas en el ZIP (`..`, absolutas, separadores en el
///   nombre del spritesheet) → evita *zip slip*;
/// - valida el `pet.json` con el schema completo de Fase A (grid/fps/states+idle);
/// - valida que el spritesheet es un WebP o PNG real (magic bytes);
/// - nunca sobrescribe una mascota base (slug protegido);
/// - escritura **atómica**: escribe en un dir temporal y solo al final hace
///   `rename` al destino; ante cualquier fallo limpia el temporal (sin dejar
///   instalaciones parciales).
class CompanionImportService {
  const CompanionImportService({
    this.maxZipBytes = 12 * 1024 * 1024,
    this.maxSpritesheetBytes = 8 * 1024 * 1024,
    this.maxManifestBytes = 64 * 1024,
  });

  final int maxZipBytes;
  final int maxSpritesheetBytes;
  final int maxManifestBytes;

  static final RegExp _slugPattern = RegExp(r'^[a-z0-9-]+$');
  static const int _maxRemoteBase64Chars = 11184812;
  static const int _maxAtlasDimension = 4096;
  static const int _maxFrameDimension = 2048;
  static const int _maxGridAxis = 64;

  /// Materializa el atlas oficial de `pet.info` mediante la misma validación y
  /// escritura atómica que las mascotas locales. [storageRoot] debe ser una
  /// carpeta de caché ya scopeada/revisionada por el repositorio.
  Future<Companion> materializeProfilePet(
    ProfilePetInfo info, {
    required Directory storageRoot,
  }) async {
    if (!info.hasPet || info.spritesheetRevision.isEmpty) {
      throw CompanionImportException(CompanionErrorCode.remoteIdentity);
    }
    final encoded = info.spritesheetBase64;
    if (encoded == null ||
        encoded.isEmpty ||
        encoded.length > _maxRemoteBase64Chars) {
      throw CompanionImportException(CompanionErrorCode.remoteAtlasMissing);
    }
    if (encoded.startsWith('data:')) {
      throw CompanionImportException(CompanionErrorCode.remoteAtlasDataUri);
    }

    final Uint8List spriteBytes;
    try {
      spriteBytes = base64Decode(encoded);
    } on FormatException {
      throw CompanionImportException(CompanionErrorCode.remoteAtlasNotBase64);
    }
    if (spriteBytes.isEmpty || spriteBytes.length > maxSpritesheetBytes) {
      throw CompanionImportException(CompanionErrorCode.remoteAtlasTooLarge);
    }

    final isPng = _isPng(spriteBytes);
    final isWebp = _isWebp(spriteBytes);
    if (!isPng && !isWebp) {
      throw CompanionImportException(CompanionErrorCode.remoteAtlasFormat);
    }
    final detectedMime = isPng ? 'image/png' : 'image/webp';
    final declaredMime = info.mime.trim().toLowerCase();
    if (declaredMime.isNotEmpty && declaredMime != detectedMime) {
      throw CompanionImportException(CompanionErrorCode.remoteMimeMismatch);
    }

    final frameW = info.frameW;
    final frameH = info.frameH;
    if (frameW == null ||
        frameH == null ||
        frameW > _maxFrameDimension ||
        frameH > _maxFrameDimension) {
      throw CompanionImportException(CompanionErrorCode.remoteFrameGeometry);
    }

    final decodedDimensions = await _decodedImageDimensions(spriteBytes);
    final headerDimensions = _imageDimensions(spriteBytes);
    if (decodedDimensions == null ||
        headerDimensions == null ||
        decodedDimensions != headerDimensions) {
      throw CompanionImportException(CompanionErrorCode.remoteAtlasUnreadable);
    }
    final (width, height) = decodedDimensions;
    if (width > _maxAtlasDimension ||
        height > _maxAtlasDimension ||
        width * height > _maxAtlasDimension * _maxAtlasDimension ||
        width % frameW != 0 ||
        height % frameH != 0) {
      throw CompanionImportException(CompanionErrorCode.remoteAtlasDimensions);
    }
    final cols = width ~/ frameW;
    final rows = height ~/ frameH;
    if (cols < 1 || rows < 1 || cols > _maxGridAxis || rows > _maxGridAxis) {
      throw CompanionImportException(CompanionErrorCode.remoteAtlasGrid);
    }

    final rowNames = info.stateRows;
    if (rowNames.length != rows || rowNames.length > _maxGridAxis) {
      throw CompanionImportException(CompanionErrorCode.remoteRowTaxonomy);
    }
    final seenRows = <String>{};
    for (final row in rowNames) {
      if (row.length > 64 || !seenRows.add(row)) {
        throw CompanionImportException(CompanionErrorCode.remoteRowTaxonomyInvalid);
      }
    }

    int? countFor(String state, int row, String rowName) {
      final count =
          info.framesByState[state] ??
          info.framesByRow[rowName] ??
          info.framesByRow['$row'] ??
          info.framesPerState;
      return count != null && count > 0 && count <= cols ? count : null;
    }

    const aliases = <CompanionAnimationState, List<String>>{
      CompanionAnimationState.idle: ['idle'],
      CompanionAnimationState.run: ['run', 'running'],
      CompanionAnimationState.review: ['review'],
      CompanionAnimationState.waiting: ['waiting'],
      CompanionAnimationState.wave: ['wave', 'waving'],
      CompanionAnimationState.jump: ['jump', 'jumping'],
      CompanionAnimationState.failed: ['failed'],
    };
    final states = <String, dynamic>{};
    final usedRows = <int>{};
    for (final entry in aliases.entries) {
      int row = -1;
      for (final alias in entry.value) {
        row = rowNames.indexOf(alias);
        if (row >= 0) break;
      }
      if (row < 0) continue;
      final count = countFor(entry.key.name, row, rowNames[row]);
      if (count == null) {
        throw CompanionImportException(CompanionErrorCode.remoteFrameCount);
      }
      usedRows.add(row);
      states[entry.key.name] = {
        'row': row,
        'frameCount': count,
        'loop': entry.key.loopsByDefault,
      };
    }
    if (!states.containsKey(CompanionAnimationState.idle.name)) {
      throw CompanionImportException(CompanionErrorCode.remoteNoIdle);
    }

    final extraRows = <Map<String, dynamic>>[];
    for (var row = 0; row < rows; row++) {
      if (usedRows.contains(row)) continue;
      final count = countFor(rowNames[row], row, rowNames[row]);
      if (count != null) {
        extraRows.add({
          'row': row,
          'frameCount': count,
          'loop': false,
          'label': rowNames[row],
        });
      }
    }

    final loopMs = info.loopMs ?? 1000;
    final referenceFrames =
        info.framesPerState ??
        (states[CompanionAnimationState.idle.name] as Map)['frameCount'] as int;
    final fps = (referenceFrames * 1000 / loopMs).clamp(1.0, 60.0);
    final extension = isPng ? 'png' : 'webp';
    final manifest = <String, dynamic>{
      'slug': info.slug,
      'name': info.displayName.isEmpty ? info.slug : info.displayName,
      'author': 'Hermes Agent',
      'license': 'remote profile asset',
      'origin': CompanionOrigin.remote.name,
      'remoteRevision': info.spritesheetRevision,
      'spritesheet': 'spritesheet.$extension',
      'fps': fps,
      'grid': {
        'frameWidth': frameW,
        'frameHeight': frameH,
        'cols': cols,
        'rows': rows,
      },
      'states': states,
      if (extraRows.isNotEmpty) 'extraRows': extraRows,
    };
    return writePack(
      manifestJson: jsonEncode(manifest),
      spriteFileName: 'spritesheet.$extension',
      spriteBytes: spriteBytes,
      storageRoot: storageRoot,
      origin: CompanionOrigin.remote,
    );
  }

  Future<(int, int)?> _decodedImageDimensions(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final result = (image.width, image.height);
      image.dispose();
      codec.dispose();
      return result;
    } catch (_) {
      return null;
    }
  }

  /// Revalida un atlas remoto ya materializado antes de anunciar su revisión
  /// como cacheada. El manifest por sí solo no basta: el fichero puede haber
  /// desaparecido o haberse quedado truncado tras un cierre inesperado.
  Future<bool> validateMaterializedProfilePet(Companion companion) async {
    if (!companion.isRemote || !companion.isValid) return false;
    final sprite = File(companion.spritesheetAsset);
    try {
      if (!await sprite.exists()) return false;
      final bytes = await sprite.readAsBytes();
      if (bytes.isEmpty || bytes.length > maxSpritesheetBytes) return false;
      if (!_isPng(bytes) && !_isWebp(bytes)) return false;
      final dimensions = await _decodedImageDimensions(bytes);
      return dimensions != null &&
          dimensions.$1 == companion.frameWidth * companion.cols &&
          dimensions.$2 == companion.frameHeight * companion.rows;
    } catch (_) {
      return false;
    }
  }

  /// Importa la mascota contenida en [zipBytes] a [storageRoot]. Devuelve la
  /// [Companion] resultante (origin `imported`, spritesheet apuntando al fichero
  /// ya copiado). [protectedSlugs] son slugs que no pueden sobrescribirse (las
  /// mascotas base). Lanza [CompanionImportException] ante cualquier problema.
  Future<Companion> importFromZipBytes(
    Uint8List zipBytes, {
    required Directory storageRoot,
    Set<String> protectedSlugs = const {},
    String? authorOverride,
  }) async {
    if (zipBytes.isEmpty) {
      throw CompanionImportException(CompanionErrorCode.zipEmpty);
    }
    if (zipBytes.length > maxZipBytes) {
      throw CompanionImportException(CompanionErrorCode.zipTooLarge);
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      debugPrint(
        '[companion-import] excepción silenciada (se relanza como error propio): $e',
      );
      throw CompanionImportException(CompanionErrorCode.zipInvalid);
    }

    // 1) Localiza pet.json (top-level) y rechaza rutas peligrosas.
    ArchiveFile? manifestEntry;
    final byBasename = <String, ArchiveFile>{};
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final name = entry.name;
      if (name.contains('..') || name.startsWith('/') || name.contains('\\')) {
        throw CompanionImportException(CompanionErrorCode.zipUnsafePath);
      }
      final base = name.split('/').last;
      if (base == 'pet.json') manifestEntry = entry;
      byBasename.putIfAbsent(base, () => entry);
    }
    if (manifestEntry == null) {
      throw CompanionImportException(CompanionErrorCode.zipNoManifest);
    }

    final manifestBytes = manifestEntry.content as List<int>;
    if (manifestBytes.length > maxManifestBytes) {
      throw CompanionImportException(CompanionErrorCode.manifestTooLarge);
    }
    final String jsonString;
    try {
      jsonString = utf8.decode(manifestBytes);
    } catch (e) {
      debugPrint(
        '[companion-import] excepción silenciada (se relanza como error propio): $e',
      );
      throw CompanionImportException(CompanionErrorCode.manifestEncoding);
    }

    // 2) Decodifica el manifest.
    final Map<String, dynamic> rawMap;
    try {
      final decoded = json.decode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        throw CompanionImportException(CompanionErrorCode.manifestRootNotObject);
      }
      rawMap = decoded;
    } on FormatException {
      throw CompanionImportException(CompanionErrorCode.manifestInvalidJson);
    }

    // Nombre del spritesheet: Fase A usa "spritesheet"; Petdex usa
    // "spritesheetPath". Solo basename (sin separadores/".." → anti zip-slip).
    var spriteName =
        ((rawMap['spritesheet'] ?? rawMap['spritesheetPath']) as String?)
            ?.trim() ??
        '';
    if (spriteName.isEmpty ||
        spriteName.contains('/') ||
        spriteName.contains('\\') ||
        spriteName.contains('..')) {
      throw CompanionImportException(CompanionErrorCode.spriteNameInvalid);
    }
    final lower = spriteName.toLowerCase();
    if (!lower.endsWith('.webp') && !lower.endsWith('.png')) {
      throw CompanionImportException(CompanionErrorCode.spriteExtensionInvalid);
    }

    // 3) Localiza el fichero de spritesheet y valídalo. Algunos pet.json de
    // Petdex declaran un nombre (p.ej. "spritesheet-hq.webp") que NO viene en
    // el ZIP; en ese caso caemos al spritesheet realmente presente (.webp/.png),
    // prefiriendo "spritesheet.webp"/"spritesheet.png".
    var spriteEntry = byBasename[spriteName];
    if (spriteEntry == null) {
      final candidates =
          byBasename.keys.where((k) {
            final l = k.toLowerCase();
            return (l.endsWith('.webp') || l.endsWith('.png')) &&
                !k.startsWith('._'); // descarta AppleDouble (__MACOSX)
          }).toList()..sort((a, b) {
            int rank(String name) {
              final l = name.toLowerCase();
              if (l == 'spritesheet.webp' || l == 'spritesheet.png') return 0;
              if (l.startsWith('spritesheet')) return 1;
              return 2;
            }

            return rank(a).compareTo(rank(b));
          });
      if (candidates.isNotEmpty) {
        spriteName = candidates.first;
        spriteEntry = byBasename[spriteName];
      }
    }
    if (spriteEntry == null) {
      throw CompanionImportException(CompanionErrorCode.zipNoSpritesheet);
    }
    final spriteBytes = Uint8List.fromList(spriteEntry.content as List<int>);
    if (spriteBytes.isEmpty) {
      throw CompanionImportException(CompanionErrorCode.spriteEmpty);
    }
    if (spriteBytes.length > maxSpritesheetBytes) {
      throw CompanionImportException(CompanionErrorCode.spriteTooLarge);
    }
    if (!_isWebp(spriteBytes) && !_isPng(spriteBytes)) {
      throw CompanionImportException(CompanionErrorCode.spriteNotImage);
    }

    // 4) Normaliza al schema completo de Fase A. Si el pet.json ya trae "grid"
    //    + "states", se usa tal cual. Si es el formato MÍNIMO de Petdex
    //    (id/displayName/spritesheetPath, sin geometría), se sintetiza el
    //    manifiesto completo infiriendo rejilla y estados estándar a partir de
    //    las dimensiones reales del spritesheet (frame 192×208, igual que las
    //    mascotas base).
    final Map<String, dynamic> manifest;
    if (rawMap['grid'] is Map && rawMap['states'] is Map) {
      manifest = Map<String, dynamic>.from(rawMap);
      manifest['spritesheet'] = spriteName;
    } else {
      manifest = await _adaptPetdexManifest(
        rawMap,
        spriteName,
        spriteBytes,
        authorOverride,
      );
    }

    final slug = (manifest['slug'] as String?)?.trim() ?? '';
    if (slug.isEmpty || slug.length > 64 || !_slugPattern.hasMatch(slug)) {
      throw CompanionImportException(CompanionErrorCode.slugInvalid);
    }
    if (protectedSlugs.contains(slug)) {
      throw CompanionImportException(CompanionErrorCode.slugReserved);
    }

    final effectiveJson = json.encode(manifest);

    // 5) Escritura atómica (compartida con writePack).
    return _writeAtomic(
      slug: slug,
      manifestJson: effectiveJson,
      spriteName: spriteName,
      spriteBytes: spriteBytes,
      storageRoot: storageRoot,
      origin: CompanionOrigin.imported,
    );
  }

  /// Escribe una mascota **ya construida** (manifest JSON + bytes de spritesheet)
  /// en `[storageRoot]/<slug>`, reutilizando la validación + escritura atómica del
  /// import. La usa "Hatch" para materializar una mascota **generada** (estática)
  /// sin pasar por un ZIP. Valida nombre/magic bytes/tamaño del sprite, slug y
  /// protección de base; nunca sobrescribe una mascota base. El `pet.json` debe
  /// declarar `"origin": "generated"` (o el que corresponda) para que el
  /// repositorio la cargue con el origen correcto.
  Future<Companion> writePack({
    required String manifestJson,
    required String spriteFileName,
    required Uint8List spriteBytes,
    required Directory storageRoot,
    CompanionOrigin origin = CompanionOrigin.generated,
    Set<String> protectedSlugs = const {},
  }) async {
    final spriteName = spriteFileName.trim();
    if (spriteName.isEmpty ||
        spriteName.contains('/') ||
        spriteName.contains('\\') ||
        spriteName.contains('..')) {
      throw CompanionImportException(CompanionErrorCode.spriteNameInvalid);
    }
    final lower = spriteName.toLowerCase();
    if (!lower.endsWith('.webp') && !lower.endsWith('.png')) {
      throw CompanionImportException(CompanionErrorCode.spriteExtensionInvalid);
    }
    if (spriteBytes.isEmpty) {
      throw CompanionImportException(CompanionErrorCode.spriteEmpty);
    }
    if (spriteBytes.length > maxSpritesheetBytes) {
      throw CompanionImportException(CompanionErrorCode.spriteTooLarge);
    }
    if (!_isWebp(spriteBytes) && !_isPng(spriteBytes)) {
      throw CompanionImportException(CompanionErrorCode.spriteNotImage);
    }

    final Map<String, dynamic> map;
    try {
      final decoded = json.decode(manifestJson);
      if (decoded is! Map<String, dynamic>) {
        throw CompanionImportException(CompanionErrorCode.manifestRootNotObject);
      }
      map = decoded;
    } on FormatException {
      throw CompanionImportException(CompanionErrorCode.manifestInvalidJson);
    }
    // Fuerza coherencia: el spritesheet y el origen los fija el servicio.
    map['spritesheet'] = spriteName;
    map['origin'] = origin.name;

    final slug = (map['slug'] as String?)?.trim() ?? '';
    if (slug.isEmpty || slug.length > 64 || !_slugPattern.hasMatch(slug)) {
      throw CompanionImportException(CompanionErrorCode.slugInvalid);
    }
    if (protectedSlugs.contains(slug)) {
      throw CompanionImportException(CompanionErrorCode.slugReserved);
    }

    return _writeAtomic(
      slug: slug,
      manifestJson: json.encode(map),
      spriteName: spriteName,
      spriteBytes: spriteBytes,
      storageRoot: storageRoot,
      origin: origin,
    );
  }

  /// Escritura atómica común: escribe `pet.json` + spritesheet en un tmp,
  /// valida parseando con el schema completo, y solo entonces hace `rename` al
  /// destino. Limpia el tmp ante cualquier fallo (sin instalaciones parciales).
  Future<Companion> _writeAtomic({
    required String slug,
    required String manifestJson,
    required String spriteName,
    required Uint8List spriteBytes,
    required Directory storageRoot,
    required CompanionOrigin origin,
  }) async {
    final effectiveBytes = utf8.encode(manifestJson);
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final tmp = Directory('${storageRoot.path}/.import-$nonce');
    final target = Directory('${storageRoot.path}/$slug');
    final backup = Directory('${storageRoot.path}/.backup-$nonce');
    var previousMoved = false;
    try {
      await tmp.create(recursive: true);
      await File(
        '${tmp.path}/pet.json',
      ).writeAsBytes(effectiveBytes, flush: true);
      await File(
        '${tmp.path}/$spriteName',
      ).writeAsBytes(spriteBytes, flush: true);

      final Companion parsed;
      try {
        parsed = CompanionManifestParser.parse(
          manifestJson,
          assetDir: tmp.path,
          slug: slug,
          origin: origin,
        );
      } on CompanionManifestException catch (e) {
        throw CompanionImportException(e.code);
      }
      if (!parsed.isValid) {
        throw CompanionImportException(CompanionErrorCode.packNoIdle);
      }

      if (await target.exists()) {
        await target.rename(backup.path);
        previousMoved = true;
      }
      try {
        await tmp.rename(target.path);
      } catch (_) {
        if (await target.exists()) await target.delete(recursive: true);
        if (previousMoved && await backup.exists()) {
          await backup.rename(target.path);
          previousMoved = false;
        }
        rethrow;
      }
      if (previousMoved && await backup.exists()) {
        await backup.delete(recursive: true);
        previousMoved = false;
      }

      // Reparsea con el directorio final para que la ruta del spritesheet
      // apunte al fichero ya movido.
      return CompanionManifestParser.parse(
        manifestJson,
        assetDir: target.path,
        slug: slug,
        origin: origin,
      );
    } catch (e) {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
      if (previousMoved && await backup.exists() && !await target.exists()) {
        await backup.rename(target.path);
      }
      if (e is CompanionImportException) rethrow;
      debugPrint('[companion-import] fallo al escribir la mascota: $e');
      throw CompanionImportException(CompanionErrorCode.packWrite);
    }
  }

  /// Frame estándar de Petdex (idéntico al de las mascotas base de Fase A).
  static const int _petdexFrameW = 192;
  static const int _petdexFrameH = 208;

  /// Adapta un `pet.json` **mínimo de Petdex** (id/displayName/spritesheetPath,
  /// sin geometría) a un manifiesto completo de Fase A. Infiere la rejilla a
  /// partir de las dimensiones reales del spritesheet (frame 192×208) y aplica
  /// el mapa de estados estándar (idle/run/waiting/wave/failed) según las filas
  /// disponibles. Lanza [CompanionImportException] si el formato no encaja.
  Future<Map<String, dynamic>> _adaptPetdexManifest(
    Map<String, dynamic> raw,
    String spriteName,
    Uint8List spriteBytes,
    String? authorOverride,
  ) async {
    final rawId =
        (raw['id'] ?? raw['slug'] ?? raw['displayName'] ?? raw['name'])
            as String?;
    final slug = _sanitizeSlug(rawId ?? '');
    if (slug.isEmpty) {
      throw CompanionImportException(CompanionErrorCode.petdexManifestUnrecognized);
    }
    final name = ((raw['displayName'] ?? raw['name']) as String?)?.trim();

    final dims = _imageDimensions(spriteBytes);
    if (dims == null) {
      throw CompanionImportException(CompanionErrorCode.spriteDimensionsUnreadable);
    }
    final (width, height) = dims;
    if (width % _petdexFrameW != 0 || height % _petdexFrameH != 0) {
      throw CompanionImportException(CompanionErrorCode.spriteDimensionsUnexpected);
    }
    final cols = width ~/ _petdexFrameW;
    final rows = height ~/ _petdexFrameH;
    if (cols < 1 || rows < 1) {
      throw CompanionImportException(CompanionErrorCode.spriteGridInvalid);
    }

    // Detecta los frames REALES de cada fila (última columna no-transparente
    // + 1). Evita el parpadeo de pintar celdas vacías al final de la fila.
    // Si la decodificación falla, cae a `cols` (comportamiento anterior).
    final framesPerRow =
        await _detectFramesPerRow(spriteBytes, _petdexFrameW, _petdexFrameH) ??
        List<int>.filled(rows, cols);

    int frames(int row) {
      if (row < framesPerRow.length && framesPerRow[row] > 0) {
        return framesPerRow[row].clamp(1, cols);
      }
      return cols;
    }

    bool rowHasContent(int row) =>
        row < framesPerRow.length ? framesPerRow[row] > 0 : true;

    // Estados estándar Petdex/Fase A en las filas 0..4 (lo que usa el mascota
    // del Home según el estado del agente).
    const layout = [
      ('idle', 0, true),
      ('run', 1, true),
      ('waiting', 2, true),
      ('wave', 3, false),
      ('failed', 4, false),
    ];
    final states = <String, dynamic>{};
    for (final (id, row, loop) in layout) {
      if (row < rows && rowHasContent(row)) {
        states[id] = {'row': row, 'frameCount': frames(row), 'loop': loop};
      }
    }

    // Filas ADICIONALES con contenido (5..rows-1): animaciones extra que el pet
    // de Petdex trae y que el probador puede reproducir aunque no tengan un
    // estado nombrado.
    final extras = <Map<String, dynamic>>[];
    for (int row = layout.length; row < rows; row++) {
      if (rowHasContent(row)) {
        extras.add({'row': row, 'frameCount': frames(row), 'loop': false});
      }
    }

    return {
      'slug': slug,
      'name': (name != null && name.isNotEmpty) ? name : slug,
      'author': (authorOverride != null && authorOverride.trim().isNotEmpty)
          ? authorOverride.trim()
          : 'Petdex',
      'license': 'unknown (Petdex)',
      'spritesheet': spriteName,
      'fps': 8,
      'grid': {
        'frameWidth': _petdexFrameW,
        'frameHeight': _petdexFrameH,
        'cols': cols,
        'rows': rows,
      },
      'states': states,
      if (extras.isNotEmpty) 'extraRows': extras,
    };
  }

  /// Decodifica el spritesheet y devuelve, por cada fila del grid, el número de
  /// frames reales (índice de la última columna con algún pixel opaco + 1).
  /// Devuelve `null` si no puede decodificar (p. ej. fixtures de test sin
  /// imagen real) para que el llamante use un valor por defecto.
  Future<List<int>?> _detectFramesPerRow(
    Uint8List spriteBytes,
    int frameW,
    int frameH,
  ) async {
    try {
      final codec = await ui.instantiateImageCodec(spriteBytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = image.width, h = image.height;
      image.dispose();
      if (data == null) return null;
      return framesPerRowFromRgba(
        data.buffer.asUint8List(),
        w,
        h,
        frameW,
        frameH,
      );
    } catch (e) {
      debugPrint(
        '[companion-import] excepción silenciada (se devuelve null): $e',
      );
      return null;
    }
  }

  /// Puro y testeable: dado un buffer RGBA y la rejilla, cuenta los frames
  /// reales de cada fila (última columna con algún pixel de alfa significativo
  /// + 1; 0 si la fila está vacía).
  static List<int> framesPerRowFromRgba(
    Uint8List rgba,
    int width,
    int height,
    int frameW,
    int frameH,
  ) {
    final cols = width ~/ frameW;
    final rows = height ~/ frameH;
    final counts = <int>[];
    for (int r = 0; r < rows; r++) {
      int last = -1;
      for (int c = 0; c < cols; c++) {
        if (_cellHasContent(
          rgba,
          width,
          c * frameW,
          r * frameH,
          frameW,
          frameH,
        )) {
          last = c;
        }
      }
      counts.add(last + 1);
    }
    return counts;
  }

  static bool _cellHasContent(
    Uint8List rgba,
    int width,
    int x0,
    int y0,
    int fw,
    int fh,
  ) {
    const step = 4; // submuestreo para abaratar el escaneo
    for (int y = y0; y < y0 + fh; y += step) {
      final rowOff = y * width * 4;
      for (int x = x0; x < x0 + fw; x += step) {
        final idx = rowOff + x * 4 + 3; // canal alfa
        if (idx < rgba.length && rgba[idx] > 16) return true;
      }
    }
    return false;
  }

  /// Normaliza un identificador a un slug seguro (`^[a-z0-9-]+$`, ≤64).
  String _sanitizeSlug(String raw) {
    var s = raw.toLowerCase().trim();
    s = s.replaceAll(RegExp(r'[^a-z0-9-]+'), '-');
    s = s.replaceAll(RegExp(r'-+'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.length > 64) s = s.substring(0, 64);
    return s;
  }

  /// Lee el ancho/alto de un PNG o WebP (VP8L/VP8X/VP8) **de la cabecera**, sin
  /// decodificar la imagen. Devuelve `null` si no puede determinarlas.
  (int, int)? _imageDimensions(Uint8List b) {
    // PNG: ancho/alto big-endian en el chunk IHDR (bytes 16..23).
    if (_isPng(b) && b.length >= 24) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      if (w > 0 && h > 0) return (w, h);
    }
    if (_isWebp(b) && b.length >= 16) {
      final fourcc = String.fromCharCodes(b.sublist(12, 16));
      if (fourcc == 'VP8L' && b.length >= 25) {
        final b21 = b[21], b22 = b[22], b23 = b[23], b24 = b[24];
        final w = (((b22 & 0x3F) << 8) | b21) + 1;
        final h = (((b24 & 0x0F) << 10) | (b23 << 2) | ((b22 & 0xC0) >> 6)) + 1;
        return (w, h);
      } else if (fourcc == 'VP8X' && b.length >= 30) {
        final w = (b[24] | (b[25] << 8) | (b[26] << 16)) + 1;
        final h = (b[27] | (b[28] << 8) | (b[29] << 16)) + 1;
        return (w, h);
      } else if (fourcc == 'VP8 ' && b.length >= 30) {
        final w = (b[26] | (b[27] << 8)) & 0x3FFF;
        final h = (b[28] | (b[29] << 8)) & 0x3FFF;
        if (w > 0 && h > 0) return (w, h);
      }
    }
    return null;
  }

  bool _isWebp(Uint8List b) =>
      b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 && // RIFF
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50; // WEBP

  bool _isPng(Uint8List b) =>
      b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47 &&
      b[4] == 0x0D &&
      b[5] == 0x0A &&
      b[6] == 0x1A &&
      b[7] == 0x0A;
}
