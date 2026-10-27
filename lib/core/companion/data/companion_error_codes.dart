/// Códigos estables de error del subsistema de mascotas.
///
/// Ningún servicio de este subsistema tiene `BuildContext`, así que no escriben
/// texto de interfaz: lanzan una excepción con uno de estos códigos y la capa de
/// pintado lo traduce con `localizedCompanionError`
/// (`lib/core/utils/companion_error_localization.dart`). El `name` del enum es
/// el contrato estable: renombrar un valor rompe la localización y los tests.
enum CompanionErrorCode {
  // Perfil remoto (`pet.info` del gateway).
  remoteIdentity,
  remoteAtlasMissing,
  remoteAtlasDataUri,
  remoteAtlasNotBase64,
  remoteAtlasTooLarge,
  remoteAtlasFormat,
  remoteMimeMismatch,
  remoteFrameGeometry,
  remoteAtlasUnreadable,
  remoteAtlasDimensions,
  remoteAtlasGrid,
  remoteRowTaxonomy,
  remoteRowTaxonomyInvalid,
  remoteFrameCount,
  remoteNoIdle,
  remoteAtlasNotCached,
  remoteCacheUnavailable,
  remoteMaterializedInvalid,
  remoteRevisionUnvalidated,

  // Importación local (ZIP + `pet.json` + spritesheet).
  zipEmpty,
  zipTooLarge,
  zipInvalid,
  zipUnsafePath,
  zipNoManifest,
  manifestTooLarge,
  manifestEncoding,
  manifestRootNotObject,
  manifestInvalidJson,
  manifestMissingSlug,
  manifestSlugChars,
  manifestSlugMismatch,
  manifestMissingGrid,
  manifestGridInvalid,
  manifestFpsInvalid,
  manifestMissingSpritesheet,
  manifestMissingStates,
  manifestStateNotObject,
  manifestStateRowRange,
  manifestStateFrameRange,
  manifestMissingIdle,
  manifestFieldNotInteger,
  manifestFieldNotNumeric,
  spriteNameInvalid,
  spriteExtensionInvalid,
  zipNoSpritesheet,
  spriteEmpty,
  spriteTooLarge,
  spriteNotImage,
  slugInvalid,
  slugReserved,
  petdexManifestUnrecognized,
  spriteDimensionsUnreadable,
  spriteDimensionsUnexpected,
  spriteGridInvalid,
  packNoIdle,
  packWrite,
  importUnavailable,

  // Catálogo remoto de Petdex.
  petdexManifestInvalid,
  petdexManifestFormat,
  petdexManifestEmpty,
  petdexOrigin,
  petdexHttp,
  petdexTooLarge,
  petdexTimeout,
  petdexNetwork,

  // Hatch (generación de mascotas).
  hatchUnavailable,
  hatchGatewayUnsupported,
  hatchStorage,
  hatchProbe,
  hatchImageInvalid,
  hatchImageDimensions,
  hatchEmptyImage,
  hatchGeneration,

  // Moderación del prompt.
  promptEmpty,
  promptTooLong,
  promptNotAllowed,
}

/// Marca común de las excepciones de mascotas que llevan un código estable.
///
/// `code` es nulo solo en errores construidos con texto libre (dobles de test
/// que simulan fallos arbitrarios); la localización los trata como desconocidos
/// y nunca reescribe ese texto en pantalla.
abstract interface class CompanionCodedError implements Exception {
  CompanionErrorCode? get code;
}
