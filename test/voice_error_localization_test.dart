import 'dart:io' show FileSystemException;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/voice_error_localization.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Future<Strings> _load(Locale locale) => Strings.delegate.load(locale);

/// Tipo real con el que cada causa llega desde los gestores de modelos.
Object _truncated() =>
    const FormatException('La descarga del modelo TTS está truncada.');
Object _sizeMismatch() =>
    const FormatException('El tamaño publicado del modelo TTS no coincide.');
Object _bzip() =>
    const FormatException('El archivo BZip2 del modelo TTS está dañado.');
Object _checksum() => const FormatException('Checksum del tar TTS inválido.');
Object _tarField() => const FormatException('Campo tar size inválido.');
Object _inProgress() =>
    StateError('La descarga de esta voz ya está en curso.');
Object _extractor() => StateError('El extractor TTS ya está cerrado.');
Object _emptyAudio() => Exception('El servidor devolvió audio vacío.');

/// Las 8 causas reales: el mapa debe cubrir toda la tabla de causas.
final Map<String, Object Function()> _causes = {
  'truncated': _truncated,
  'sizeMismatch': _sizeMismatch,
  'bzip': _bzip,
  'checksum': _checksum,
  'tarField': _tarField,
  'inProgress': _inProgress,
  'extractor': _extractor,
  'emptyAudio': _emptyAudio,
};

void main() {
  test('las 8 causas reales se traducen en zh con valores exactos', () async {
    final zh = await _load(const Locale('zh'));
    expect(localizedVoiceDownloadCause(_truncated(), zh), '模型下载被截断。');
    expect(localizedVoiceDownloadCause(_sizeMismatch(), zh), '模型大小与发布值不一致。');
    expect(localizedVoiceDownloadCause(_bzip(), zh), '模型压缩包已损坏。');
    expect(localizedVoiceDownloadCause(_checksum(), zh), '模型校验和不匹配。');
    expect(localizedVoiceDownloadCause(_tarField(), zh), '模型压缩包已损坏。');
    expect(localizedVoiceDownloadCause(_inProgress(), zh), '该音色正在下载中。');
    expect(localizedVoiceDownloadCause(_extractor(), zh), '解包器已关闭。');
    expect(localizedVoiceDownloadCause(_emptyAudio(), zh), '服务器返回了空音频。');
  });

  test('en y es tienen valores exactos para las 8 causas', () async {
    final en = await _load(const Locale('en'));
    final es = await _load(const Locale('es'));
    final zh = await _load(const Locale('zh'));
    for (final entry in _causes.entries) {
      final error = entry.value();
      final zhText = localizedVoiceDownloadCause(error, zh);
      final enText = localizedVoiceDownloadCause(error, en);
      final esText = localizedVoiceDownloadCause(error, es);
      expect(enText, isNotEmpty, reason: '${entry.key}: en vacío');
      expect(esText, isNotEmpty, reason: '${entry.key}: es vacío');
      expect(enText, isNot(zhText), reason: '${entry.key}: en == zh');
      expect(esText, isNot(zhText), reason: '${entry.key}: es == zh');
      expect(enText, isNot(esText), reason: '${entry.key}: en == es');
      expect(enText, endsWith('.'), reason: '${entry.key}: en sin punto final');
      expect(esText, endsWith('.'), reason: '${entry.key}: es sin punto final');
    }
  });

  test('almacenamiento y HTTP conservan el diagnóstico sin rutas', () async {
    final zh = await _load(const Locale('zh'));
    final en = await _load(const Locale('en'));
    final storage = FileSystemException('No space left on device', '/data');
    expect(localizedVoiceDownloadCause(storage, zh), '设备存储不可用或空间不足。');
    expect(
      localizedVoiceDownloadCause(storage, en),
      'Device storage is unavailable or full.',
    );
    // Forma real de voice_service: sin prefijo HTTP.
    final whisper404 = Exception('Model download failed (404).');
    expect(localizedVoiceDownloadCause(whisper404, zh), '服务器返回错误（HTTP 404）。');
    expect(
      localizedVoiceDownloadCause(whisper404, en),
      'The server returned an error (HTTP 404).',
    );
    final http503 = Exception('HTTP 503 upstream');
    expect(localizedVoiceDownloadCause(http503, zh), '服务器返回错误（HTTP 503）。');
    // path_provider sin plataforma: diagnóstico de almacenamiento, no genérico.
    final platformDir = Exception(
      'MissingPlatformDirectoryException(download)',
    );
    expect(localizedVoiceDownloadCause(platformDir, zh), '设备存储不可用或空间不足。');
  });

  test('una causa desconocida no filtra español ni inglés', () async {
    final zh = await _load(const Locale('zh'));
    final en = await _load(const Locale('en'));
    final text = localizedVoiceDownloadCause(
      StateError('Algo raro pasó en el disco.'),
      zh,
    );
    expect(text, '请重试；若仍然失败，请重新下载该模型。');
    expect(RegExp(r'[A-Za-zÁÉÍÓÚáéíóúñÑ]').hasMatch(text), isFalse);
    expect(
      localizedVoiceDownloadCause(
        StateError('Algo raro pasó en el disco.'),
        en,
      ),
      'Try again; if it keeps failing, download the model again.',
    );
  });
}
