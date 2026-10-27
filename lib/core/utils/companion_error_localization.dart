import '../../l10n/app_localizations.dart';
import '../companion/data/companion_error_codes.dart';

/// Traduce en el borde de pintado el error del subsistema de mascotas.
///
/// Los servicios lanzan excepciones con un [CompanionErrorCode]; esta función
/// devuelve la cadena del idioma activo. Un error sin código conocido (texto
/// libre de un doble de test, excepción de otra capa) cae al mensaje genérico
/// localizado: nunca se muestra el texto original ni el código en crudo.
String localizedCompanionError(Object error, Strings strings) =>
    companionErrorText(error is CompanionCodedError ? error.code : null, strings);

/// Texto localizado de [code]; `null` → mensaje genérico de reserva.
String companionErrorText(CompanionErrorCode? code, Strings strings) {
  switch (code) {
    case CompanionErrorCode.remoteIdentity:
      return strings.petErrRemoteIdentity;
    case CompanionErrorCode.remoteAtlasMissing:
    case CompanionErrorCode.remoteAtlasDataUri:
    case CompanionErrorCode.remoteAtlasNotBase64:
    case CompanionErrorCode.remoteAtlasTooLarge:
    case CompanionErrorCode.remoteAtlasFormat:
    case CompanionErrorCode.remoteMimeMismatch:
    case CompanionErrorCode.remoteFrameGeometry:
    case CompanionErrorCode.remoteAtlasUnreadable:
    case CompanionErrorCode.remoteAtlasDimensions:
    case CompanionErrorCode.remoteAtlasGrid:
    case CompanionErrorCode.remoteRowTaxonomy:
    case CompanionErrorCode.remoteRowTaxonomyInvalid:
    case CompanionErrorCode.remoteFrameCount:
    case CompanionErrorCode.remoteNoIdle:
      return strings.petErrRemoteAtlas;
    case CompanionErrorCode.remoteAtlasNotCached:
    case CompanionErrorCode.remoteCacheUnavailable:
      return strings.petErrRemoteCache;
    case CompanionErrorCode.remoteMaterializedInvalid:
      return strings.petErrRemoteMaterialized;
    case CompanionErrorCode.remoteRevisionUnvalidated:
      return strings.petErrRemoteRevision;

    case CompanionErrorCode.zipEmpty:
      return strings.petErrZipEmpty;
    case CompanionErrorCode.zipTooLarge:
      return strings.petErrZipTooLarge;
    case CompanionErrorCode.zipInvalid:
      return strings.petErrZipInvalid;
    case CompanionErrorCode.zipUnsafePath:
      return strings.petErrZipUnsafePath;
    case CompanionErrorCode.zipNoManifest:
      return strings.petErrZipNoManifest;
    case CompanionErrorCode.manifestTooLarge:
      return strings.petErrManifestTooLarge;
    case CompanionErrorCode.manifestEncoding:
      return strings.petErrManifestEncoding;
    case CompanionErrorCode.manifestMissingSlug:
    case CompanionErrorCode.manifestSlugChars:
    case CompanionErrorCode.manifestSlugMismatch:
      return strings.petErrManifestSlug;
    case CompanionErrorCode.manifestRootNotObject:
    case CompanionErrorCode.manifestInvalidJson:
    case CompanionErrorCode.manifestMissingGrid:
    case CompanionErrorCode.manifestGridInvalid:
    case CompanionErrorCode.manifestFpsInvalid:
    case CompanionErrorCode.manifestMissingSpritesheet:
    case CompanionErrorCode.manifestMissingStates:
    case CompanionErrorCode.manifestStateNotObject:
    case CompanionErrorCode.manifestStateRowRange:
    case CompanionErrorCode.manifestStateFrameRange:
    case CompanionErrorCode.manifestMissingIdle:
    case CompanionErrorCode.manifestFieldNotInteger:
    case CompanionErrorCode.manifestFieldNotNumeric:
    case CompanionErrorCode.petdexManifestUnrecognized:
    case CompanionErrorCode.packNoIdle:
      return strings.petErrManifestStructure;
    case CompanionErrorCode.spriteNameInvalid:
      return strings.petErrSpriteName;
    case CompanionErrorCode.spriteExtensionInvalid:
    case CompanionErrorCode.spriteNotImage:
      return strings.petErrSpriteFormat;
    case CompanionErrorCode.zipNoSpritesheet:
      return strings.petErrZipNoSprite;
    case CompanionErrorCode.spriteEmpty:
      return strings.petErrSpriteEmpty;
    case CompanionErrorCode.spriteTooLarge:
      return strings.petErrSpriteTooLarge;
    case CompanionErrorCode.spriteDimensionsUnreadable:
    case CompanionErrorCode.spriteDimensionsUnexpected:
    case CompanionErrorCode.spriteGridInvalid:
      return strings.petErrSpriteDimensions;
    case CompanionErrorCode.slugInvalid:
      return strings.petErrSlugInvalid;
    case CompanionErrorCode.slugReserved:
      return strings.petErrSlugReserved;
    case CompanionErrorCode.packWrite:
      return strings.petErrPackWrite;
    case CompanionErrorCode.importUnavailable:
      return strings.petErrImportUnavailable;

    case CompanionErrorCode.petdexManifestInvalid:
    case CompanionErrorCode.petdexManifestFormat:
    case CompanionErrorCode.petdexManifestEmpty:
      return strings.petErrPetdexManifest;
    case CompanionErrorCode.petdexOrigin:
      return strings.petErrPetdexOrigin;
    case CompanionErrorCode.petdexHttp:
      return strings.petErrPetdexHttp;
    case CompanionErrorCode.petdexTooLarge:
      return strings.petErrPetdexTooLarge;
    case CompanionErrorCode.petdexTimeout:
      return strings.petErrPetdexTimeout;
    case CompanionErrorCode.petdexNetwork:
      return strings.petErrPetdexNetwork;

    case CompanionErrorCode.hatchUnavailable:
      return strings.petErrHatchUnavailable;
    case CompanionErrorCode.hatchGatewayUnsupported:
      return strings.petErrHatchUnsupported;
    case CompanionErrorCode.hatchStorage:
      return strings.petErrHatchStorage;
    case CompanionErrorCode.hatchProbe:
      return strings.petErrHatchProbe;
    case CompanionErrorCode.hatchImageInvalid:
    case CompanionErrorCode.hatchImageDimensions:
    case CompanionErrorCode.hatchEmptyImage:
      return strings.petErrHatchImage;
    case CompanionErrorCode.hatchGeneration:
      return strings.petErrHatchGeneration;

    case CompanionErrorCode.promptEmpty:
      return strings.petErrPromptEmpty;
    case CompanionErrorCode.promptTooLong:
      return strings.petErrPromptTooLong;
    case CompanionErrorCode.promptNotAllowed:
      return strings.petErrPromptNotAllowed;

    case null:
      return strings.petErrUnknown;
  }
}
