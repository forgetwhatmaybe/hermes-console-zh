import 'dart:io' show FileSystemException;

import '../../l10n/app_localizations.dart';

/// Causas que los gestores de modelos escriben en español y que
/// `voice_settings_screen` pinta dentro de una frase ya localizada.
/// Sólo se traducen estas constantes: cualquier otro texto se sustituye por un
/// consejo localizado, nunca se muestra en español ni se reescribe a mano.
const _inProgress = 'La descarga de esta voz ya está en curso.';
const _sizeMismatch = 'El tamaño publicado del modelo TTS no coincide.';
const _truncated = 'La descarga del modelo TTS está truncada.';
const _corruptBzip = 'El archivo BZip2 del modelo TTS está dañado.';
const _corruptBzipStt = 'El archivo BZip2 del modelo está dañado.';
const _checksum = 'Checksum del tar TTS inválido.';
const _checksumStt = 'Checksum del tar STT inválido.';
const _extractorClosed = 'El extractor TTS ya está cerrado.';
const _extractorClosedStt = 'El extractor STT ya está cerrado.';
const _emptyAudio = 'El servidor devolvió audio vacío.';
const _tarTruncated = 'El tar del modelo TTS está truncado.';
const _tarTruncatedStt = 'El tar del modelo STT está truncado.';
const _tarFieldPrefix = 'Campo tar ';

/// Texto de la causa sin el envoltorio que Dart añade al imprimir.
///
/// La descarga lanza `FormatException` (tamaño, truncado, BZip2, tar) y
/// `StateError` (descarga en curso): se lee `.message` para no depender del
/// prefijo impreso, que cambia entre versiones del SDK.
String _bare(Object error) {
  if (error is FormatException) return error.message.trim();
  if (error is StateError) return error.message.toString().trim();
  var text = error.toString().trim();
  for (final prefix in const [
    'FormatException: ',
    'Bad state: ',
    'Exception: ',
    'Error: ',
  ]) {
    if (text.startsWith(prefix)) {
      text = text.substring(prefix.length).trimLeft();
      break;
    }
  }
  return text;
}

/// Traduce la causa de un fallo de descarga de voz a la cadena activa.
String localizedVoiceDownloadCause(Object error, Strings strings) {
  final text = _bare(error);
  switch (text) {
    case _inProgress:
      return strings.voiceCauseInProgress;
    case _sizeMismatch:
      return strings.voiceCauseSizeMismatch;
    case _truncated:
    case _tarTruncated:
    case _tarTruncatedStt:
      return strings.voiceCauseTruncated;
    case _corruptBzip:
    case _corruptBzipStt:
      return strings.voiceCauseCorruptArchive;
    case _checksum:
    case _checksumStt:
      return strings.voiceCauseChecksum;
    case _extractorClosed:
    case _extractorClosedStt:
      return strings.voiceCauseExtractorClosed;
    case _emptyAudio:
      return strings.voiceCauseEmptyAudio;
  }
  if (text.startsWith(_tarFieldPrefix)) {
    return strings.voiceCauseCorruptArchive;
  }
  if (error is FileSystemException ||
      text.contains('MissingPlatformDirectoryException') ||
      text.contains('platform directory')) {
    return strings.voiceCauseStorage;
  }
  final http = RegExp(r'(?:HTTP\s+(\d{3})|failed \((\d{3})\))').firstMatch(text);
  if (http != null) {
    return strings.voiceCauseHttp(http.group(1) ?? http.group(2)!);
  }
  return strings.voiceCauseUnknown;
}
