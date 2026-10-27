import 'dart:convert';

import '../models/companion.dart';
import '../models/companion_animation_state.dart';
import 'companion_error_codes.dart';

/// Error de validación de un `pet.json`.
///
/// Lleva un [CompanionErrorCode] estable, nunca texto de interfaz.
class CompanionManifestException implements CompanionCodedError {
  @override
  final CompanionErrorCode code;

  CompanionManifestException(this.code);

  /// Identificador estable del fallo (el `name` del código).
  String get message => code.name;

  @override
  String toString() => 'CompanionManifestException: ${code.name}';
}

/// Parsea y valida un `pet.json` (contenido) a un [Companion].
///
/// Contrato: docs/PETDEX_CONTRACT.md.
/// Lanza [CompanionManifestException] ante cualquier inconsistencia; quien
/// llama (el repositorio) hace fallback a la cara del perfil (FR-012).
class CompanionManifestParser {
  static final RegExp _slugPattern = RegExp(r'^[a-z0-9-]+$');

  /// [assetDir] es el directorio del asset (p. ej. `assets/companions/boba`).
  /// [slug] es el nombre de la carpeta, que debe coincidir con el manifest.
  static Companion parse(
    String jsonString, {
    required String assetDir,
    required String slug,
    CompanionOrigin origin = CompanionOrigin.base,
  }) {
    final Map<String, dynamic> map;
    try {
      final decoded = json.decode(jsonString);
      if (decoded is! Map<String, dynamic>) {
        throw CompanionManifestException(CompanionErrorCode.manifestRootNotObject);
      }
      map = decoded;
    } on FormatException {
      throw CompanionManifestException(CompanionErrorCode.manifestInvalidJson);
    }

    final manifestSlug = (map['slug'] as String?)?.trim() ?? '';
    if (manifestSlug.isEmpty) {
      throw CompanionManifestException(CompanionErrorCode.manifestMissingSlug);
    }
    if (!_slugPattern.hasMatch(manifestSlug)) {
      throw CompanionManifestException(CompanionErrorCode.manifestSlugChars);
    }
    if (manifestSlug != slug) {
      throw CompanionManifestException(CompanionErrorCode.manifestSlugMismatch);
    }

    final grid = map['grid'];
    if (grid is! Map<String, dynamic>) {
      throw CompanionManifestException(CompanionErrorCode.manifestMissingGrid);
    }
    final frameWidth = _int(grid['frameWidth']);
    final frameHeight = _int(grid['frameHeight']);
    final cols = _int(grid['cols']);
    final rows = _int(grid['rows']);
    if (frameWidth <= 0 || frameHeight <= 0 || cols <= 0 || rows <= 0) {
      throw CompanionManifestException(CompanionErrorCode.manifestGridInvalid);
    }

    final fps = _num(map['fps']).toDouble();
    if (fps <= 0) {
      throw CompanionManifestException(CompanionErrorCode.manifestFpsInvalid);
    }

    final spritesheet = (map['spritesheet'] as String?)?.trim();
    if (spritesheet == null || spritesheet.isEmpty) {
      throw CompanionManifestException(CompanionErrorCode.manifestMissingSpritesheet);
    }

    final statesRaw = map['states'];
    if (statesRaw is! Map<String, dynamic>) {
      throw CompanionManifestException(CompanionErrorCode.manifestMissingStates);
    }
    final states = <CompanionAnimationState, RowSpec>{};
    statesRaw.forEach((key, value) {
      final state = companionStateFromId(key);
      if (state == null) return; // ignora estados desconocidos (tolerante)
      if (value is! Map<String, dynamic>) {
        throw CompanionManifestException(CompanionErrorCode.manifestStateNotObject);
      }
      final row = _int(value['row']);
      final frameCount = _int(value['frameCount']);
      final loop = value['loop'] as bool? ?? state.loopsByDefault;
      if (row < 0 || row >= rows) {
        throw CompanionManifestException(CompanionErrorCode.manifestStateRowRange);
      }
      if (frameCount <= 0 || frameCount > cols) {
        throw CompanionManifestException(
            CompanionErrorCode.manifestStateFrameRange);
      }
      states[state] = RowSpec(row: row, frameCount: frameCount, loop: loop);
    });

    if (!states.containsKey(CompanionAnimationState.idle)) {
      throw CompanionManifestException(CompanionErrorCode.manifestMissingIdle);
    }

    // Filas de animación extra (opcional): animaciones sin estado nombrado.
    // Tolerante: una entrada inválida se ignora (no rompe la mascota).
    final extraRows = <RowSpec>[];
    final extraRaw = map['extraRows'];
    if (extraRaw is List) {
      for (final item in extraRaw) {
        if (item is! Map<String, dynamic>) continue;
        final row = item['row'];
        final frameCount = item['frameCount'];
        if (row is! int || frameCount is! int) continue;
        if (row < 0 || row >= rows || frameCount <= 0 || frameCount > cols) {
          continue;
        }
        final rawLabel =
            (item['name'] as String?)?.trim() ?? (item['label'] as String?)?.trim();
        extraRows.add(RowSpec(
          row: row,
          frameCount: frameCount,
          loop: item['loop'] as bool? ?? false,
          label: (rawLabel != null && rawLabel.isNotEmpty) ? rawLabel : null,
        ));
      }
    }

    final name = (map['name'] as String?)?.trim();
    // Un `pet.json` del sandbox puede declarar su origen (`generated` vs
    // `imported`); si lo hace, tiene prioridad sobre el [origin] por defecto.
    final effectiveOrigin =
        companionOriginFromId(map['origin'] as String?) ?? origin;
    return Companion(
      slug: manifestSlug,
      name: (name != null && name.isNotEmpty) ? name : manifestSlug,
      author: (map['author'] as String?)?.trim() ?? 'unknown',
      license: (map['license'] as String?)?.trim() ?? 'unknown',
      spritesheetAsset: '$assetDir/$spritesheet',
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      cols: cols,
      rows: rows,
      fps: fps,
      states: states,
      extraRows: extraRows,
      origin: effectiveOrigin,
    );
  }

  static int _int(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw CompanionManifestException(CompanionErrorCode.manifestFieldNotInteger);
  }

  static num _num(dynamic value) {
    if (value is num) return value;
    throw CompanionManifestException(CompanionErrorCode.manifestFieldNotNumeric);
  }
}
