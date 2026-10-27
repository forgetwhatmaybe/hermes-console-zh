import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_error_codes.dart';
import 'package:hermes_android/core/companion/data/companion_import_service.dart';
import 'package:hermes_android/core/companion/data/companion_manifest_parser.dart';
import 'package:hermes_android/core/companion/data/petdex_remote_service.dart';
import 'package:hermes_android/core/companion/hatch/hatch_provider.dart';
import 'package:hermes_android/core/companion/hatch/prompt_safety.dart';
import 'package:hermes_android/core/utils/companion_error_localization.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Future<Strings> _load(Locale locale) => Strings.delegate.load(locale);

/// Texto que debe producir cada código. Una entrada por valor del enum: si se
/// añade un código sin texto, el test de cobertura falla.
final Map<CompanionErrorCode, String Function(Strings)> _expected = {
  // Perfil remoto.
  CompanionErrorCode.remoteIdentity: (s) => s.petErrRemoteIdentity,
  CompanionErrorCode.remoteAtlasMissing: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteAtlasDataUri: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteAtlasNotBase64: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteAtlasTooLarge: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteAtlasFormat: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteMimeMismatch: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteFrameGeometry: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteAtlasUnreadable: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteAtlasDimensions: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteAtlasGrid: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteRowTaxonomy: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteRowTaxonomyInvalid: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteFrameCount: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteNoIdle: (s) => s.petErrRemoteAtlas,
  CompanionErrorCode.remoteAtlasNotCached: (s) => s.petErrRemoteCache,
  CompanionErrorCode.remoteCacheUnavailable: (s) => s.petErrRemoteCache,
  CompanionErrorCode.remoteMaterializedInvalid: (s) => s.petErrRemoteMaterialized,
  CompanionErrorCode.remoteRevisionUnvalidated: (s) => s.petErrRemoteRevision,
  // Importación local.
  CompanionErrorCode.zipEmpty: (s) => s.petErrZipEmpty,
  CompanionErrorCode.zipTooLarge: (s) => s.petErrZipTooLarge,
  CompanionErrorCode.zipInvalid: (s) => s.petErrZipInvalid,
  CompanionErrorCode.zipUnsafePath: (s) => s.petErrZipUnsafePath,
  CompanionErrorCode.zipNoManifest: (s) => s.petErrZipNoManifest,
  CompanionErrorCode.manifestTooLarge: (s) => s.petErrManifestTooLarge,
  CompanionErrorCode.manifestEncoding: (s) => s.petErrManifestEncoding,
  CompanionErrorCode.manifestRootNotObject: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestInvalidJson: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestMissingSlug: (s) => s.petErrManifestSlug,
  CompanionErrorCode.manifestSlugChars: (s) => s.petErrManifestSlug,
  CompanionErrorCode.manifestSlugMismatch: (s) => s.petErrManifestSlug,
  CompanionErrorCode.manifestMissingGrid: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestGridInvalid: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestFpsInvalid: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestMissingSpritesheet: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestMissingStates: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestStateNotObject: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestStateRowRange: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestStateFrameRange: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestMissingIdle: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestFieldNotInteger: (s) => s.petErrManifestStructure,
  CompanionErrorCode.manifestFieldNotNumeric: (s) => s.petErrManifestStructure,
  CompanionErrorCode.spriteNameInvalid: (s) => s.petErrSpriteName,
  CompanionErrorCode.spriteExtensionInvalid: (s) => s.petErrSpriteFormat,
  CompanionErrorCode.zipNoSpritesheet: (s) => s.petErrZipNoSprite,
  CompanionErrorCode.spriteEmpty: (s) => s.petErrSpriteEmpty,
  CompanionErrorCode.spriteTooLarge: (s) => s.petErrSpriteTooLarge,
  CompanionErrorCode.spriteNotImage: (s) => s.petErrSpriteFormat,
  CompanionErrorCode.slugInvalid: (s) => s.petErrSlugInvalid,
  CompanionErrorCode.slugReserved: (s) => s.petErrSlugReserved,
  CompanionErrorCode.petdexManifestUnrecognized: (s) => s.petErrManifestStructure,
  CompanionErrorCode.spriteDimensionsUnreadable: (s) => s.petErrSpriteDimensions,
  CompanionErrorCode.spriteDimensionsUnexpected: (s) => s.petErrSpriteDimensions,
  CompanionErrorCode.spriteGridInvalid: (s) => s.petErrSpriteDimensions,
  CompanionErrorCode.packNoIdle: (s) => s.petErrManifestStructure,
  CompanionErrorCode.packWrite: (s) => s.petErrPackWrite,
  CompanionErrorCode.importUnavailable: (s) => s.petErrImportUnavailable,
  // Catálogo de Petdex.
  CompanionErrorCode.petdexManifestInvalid: (s) => s.petErrPetdexManifest,
  CompanionErrorCode.petdexManifestFormat: (s) => s.petErrPetdexManifest,
  CompanionErrorCode.petdexManifestEmpty: (s) => s.petErrPetdexManifest,
  CompanionErrorCode.petdexOrigin: (s) => s.petErrPetdexOrigin,
  CompanionErrorCode.petdexHttp: (s) => s.petErrPetdexHttp,
  CompanionErrorCode.petdexTooLarge: (s) => s.petErrPetdexTooLarge,
  CompanionErrorCode.petdexTimeout: (s) => s.petErrPetdexTimeout,
  CompanionErrorCode.petdexNetwork: (s) => s.petErrPetdexNetwork,
  // Hatch.
  CompanionErrorCode.hatchUnavailable: (s) => s.petErrHatchUnavailable,
  CompanionErrorCode.hatchGatewayUnsupported: (s) => s.petErrHatchUnsupported,
  CompanionErrorCode.hatchStorage: (s) => s.petErrHatchStorage,
  CompanionErrorCode.hatchProbe: (s) => s.petErrHatchProbe,
  CompanionErrorCode.hatchImageInvalid: (s) => s.petErrHatchImage,
  CompanionErrorCode.hatchImageDimensions: (s) => s.petErrHatchImage,
  CompanionErrorCode.hatchEmptyImage: (s) => s.petErrHatchImage,
  CompanionErrorCode.hatchGeneration: (s) => s.petErrHatchGeneration,
  // Moderación del prompt.
  CompanionErrorCode.promptEmpty: (s) => s.petErrPromptEmpty,
  CompanionErrorCode.promptTooLong: (s) => s.petErrPromptTooLong,
  CompanionErrorCode.promptNotAllowed: (s) => s.petErrPromptNotAllowed,
};

/// Marcas que delatan texto en español: ningún idioma distinto de `es` puede
/// contenerlas.
final RegExp _spanish = RegExp(
  r'se pudo|inválid|demasiado|mascota|archivo|permitid|revisión|está |no hay ',
);

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, data) {
    archive.addFile(ArchiveFile(name, data.length, data));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  late Strings zh;
  late Strings en;
  late Strings es;

  setUpAll(() async {
    zh = await _load(const Locale('zh'));
    en = await _load(const Locale('en'));
    es = await _load(const Locale('es'));
  });

  test('la tabla cubre todos los códigos del enum', () {
    expect(_expected.keys.toSet(), CompanionErrorCode.values.toSet());
  });

  test('cada código se traduce en zh, en y es', () {
    for (final code in CompanionErrorCode.values) {
      final expected = _expected[code]!;
      final zhText = companionErrorText(code, zh);
      final enText = companionErrorText(code, en);
      final esText = companionErrorText(code, es);

      expect(zhText, expected(zh), reason: 'zh $code');
      expect(enText, expected(en), reason: 'en $code');
      expect(esText, expected(es), reason: 'es $code');

      for (final (locale, text) in [('zh', zhText), ('en', enText), ('es', esText)]) {
        expect(text.trim(), isNotEmpty, reason: '$locale $code vacío');
        expect(text, isNot(code.name), reason: '$locale $code filtra el código');
      }
      expect(zhText, isNot(enText), reason: 'zh y en deben diferir: $code');
      expect(zhText, isNot(esText), reason: 'zh y es deben diferir: $code');
      expect(zhText, isNot(matches(_spanish)), reason: 'zh filtra español: $code');
      expect(enText, isNot(matches(_spanish)), reason: 'en filtra español: $code');
    }
  });

  test('las excepciones reales del subsistema llevan código estable', () async {
    final errors = <CompanionCodedError>[
      CompanionImportException(CompanionErrorCode.zipEmpty),
      CompanionManifestException(CompanionErrorCode.manifestMissingGrid),
      PetdexRemoteException.coded(CompanionErrorCode.petdexTimeout),
      HatchException.code(CompanionErrorCode.hatchStorage),
      PromptRejectedException(CompanionErrorCode.promptTooLong),
    ];
    final expected = <CompanionErrorCode>[
      CompanionErrorCode.zipEmpty,
      CompanionErrorCode.manifestMissingGrid,
      CompanionErrorCode.petdexTimeout,
      CompanionErrorCode.hatchStorage,
      CompanionErrorCode.promptTooLong,
    ];
    for (var i = 0; i < errors.length; i++) {
      expect(errors[i].code, expected[i]);
      expect(
        localizedCompanionError(errors[i], zh),
        _expected[expected[i]]!(zh),
      );
      expect(localizedCompanionError(errors[i], en), _expected[expected[i]]!(en));
    }
  });

  test('un error sin código cae al mensaje genérico sin filtrar el original', () {
    // Texto libre, como el que usan los dobles de test que simulan fallos.
    final free = PetdexRemoteException('fallo de red', offline: true);
    expect(free.code, isNull);
    expect(free.offline, isTrue);
    final zhText = localizedCompanionError(free, zh);
    final enText = localizedCompanionError(free, en);
    expect(zhText, zh.petErrUnknown);
    expect(enText, en.petErrUnknown);
    expect(zhText, isNot(contains('fallo de red')));
    expect(enText, isNot(contains('fallo de red')));
    expect(zhText, isNot(matches(_spanish)));
    expect(enText, isNot(matches(_spanish)));

    // Un error de otra capa tampoco se reescribe: cae al mismo genérico.
    final foreign = StateError('la mascota remota no es válida');
    expect(localizedCompanionError(foreign, zh), zh.petErrUnknown);
    expect(localizedCompanionError(foreign, zh), isNot(contains('válida')));
  });

  test('el servicio lanza códigos estables ante ZIP vacío o sin pet.json', () async {
    const service = CompanionImportService();
    final root = Directory.systemTemp;

    await expectLater(
      service.importFromZipBytes(Uint8List(0), storageRoot: root),
      throwsA(
        isA<CompanionImportException>().having(
          (e) => e.code,
          'code',
          CompanionErrorCode.zipEmpty,
        ),
      ),
    );

    final noManifest = _zip({'readme.txt': utf8.encode('hola')});
    await expectLater(
      service.importFromZipBytes(noManifest, storageRoot: root),
      throwsA(
        isA<CompanionImportException>().having(
          (e) => e.code,
          'code',
          CompanionErrorCode.zipNoManifest,
        ),
      ),
    );

    final badJson = _zip({'pet.json': utf8.encode('{')});
    await expectLater(
      service.importFromZipBytes(badJson, storageRoot: root),
      throwsA(
        isA<CompanionImportException>().having(
          (e) => e.code,
          'code',
          CompanionErrorCode.manifestInvalidJson,
        ),
      ),
    );
  });

  test('el parser y la moderación lanzan códigos reales', () {
    expect(
      () => CompanionManifestParser.parse(
        '{',
        assetDir: 'assets/companions/x',
        slug: 'x',
      ),
      throwsA(
        isA<CompanionManifestException>().having(
          (e) => e.code,
          'code',
          CompanionErrorCode.manifestInvalidJson,
        ),
      ),
    );
    expect(
      () => CompanionManifestParser.parse(
        json.encode({'slug': 'x'}),
        assetDir: 'assets/companions/x',
        slug: 'x',
      ),
      throwsA(
        isA<CompanionManifestException>().having(
          (e) => e.code,
          'code',
          CompanionErrorCode.manifestMissingGrid,
        ),
      ),
    );
    const safety = PromptSafety();
    expect(
      () => safety.sanitize('   '),
      throwsA(
        isA<PromptRejectedException>().having(
          (e) => e.code,
          'code',
          CompanionErrorCode.promptEmpty,
        ),
      ),
    );
    expect(
      () => safety.sanitize('a' * (PromptSafety.maxLength + 1)),
      throwsA(
        isA<PromptRejectedException>().having(
          (e) => e.code,
          'code',
          CompanionErrorCode.promptTooLong,
        ),
      ),
    );
  });
}
