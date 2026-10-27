import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/voice/voice_response_policy.dart';
import 'package:hermes_android/core/services/voice/voice_service.dart';

void main() {
  group('VoiceResponsePolicy — qué se puede leer en voz', () {
    test('lee prosa normal', () {
      final v = VoiceResponsePolicy.evaluate(
        'He revisado el servidor y todo bien.',
      );
      expect(v.hasSpeakable, isTrue);
      expect(v.skippedTechnicalContent, isFalse);
      expect(
        VoiceResponsePolicy.speakable('Resumen: tres cambios aplicados.'),
        isTrue,
      );
    });

    test('descarta bloque de código (code fence)', () {
      final v = VoiceResponsePolicy.evaluate('```dart\nvoid main() {}\n```');
      expect(v.hasSpeakable, isFalse);
      expect(v.skippedTechnicalContent, isTrue);
      expect(v.reason, 'code-fence');
    });

    test('descarta JSON volcado (no gasta créditos de nube)', () {
      final v = VoiceResponsePolicy.evaluate(
        '{"status": "ok", "items": 3, "name": "x"}',
      );
      expect(v.skippedTechnicalContent, isTrue);
      expect(v.reason, 'json');
    });

    test('descarta stack trace / logs', () {
      const log =
          'ERROR algo falló\n'
          '  at Foo.bar (file.dart:42)\n'
          '  at Baz.qux (file.dart:7)';
      final v = VoiceResponsePolicy.evaluate(log);
      expect(v.skippedTechnicalContent, isTrue);
      expect(v.reason, 'log');
    });

    test('descarta tabla densa (saltos + símbolos)', () {
      const table = '| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |';
      expect(VoiceResponsePolicy.speakable(table), isFalse);
      expect(
        VoiceResponsePolicy.evaluate(table).skippedTechnicalContent,
        isTrue,
      );
    });

    test('NO confunde prosa con dos puntos/comillas', () {
      expect(
        VoiceResponsePolicy.speakable('Te dije: "lo miro" y lo hice.'),
        isTrue,
      );
    });
  });

  group('VoiceResponsePolicy.wantsFullReading — leer entero vs resumir', () {
    test('peticiones de contar/leer algo → lectura completa', () {
      for (final q in const [
        'cuéntale un cuento a mi hija',
        'cuéntame un cuento',
        'léeme este artículo en voz alta',
        'recítame un poema',
        'cuéntame un chiste',
        'cántame una canción',
        'nárrame una historia para dormir',
      ]) {
        expect(VoiceResponsePolicy.wantsFullReading(q), isTrue, reason: q);
      }
    });

    test('búsquedas/consultas/datos → resumen (no lectura completa)', () {
      for (final q in const [
        'búscame las noticias de hoy',
        'cuéntame qué pasó en el mundo',
        'cuéntame las noticias',
        'resume el informe',
        'qué tiempo hace mañana',
        '¿cuánto es 2 más 2?',
      ]) {
        expect(VoiceResponsePolicy.wantsFullReading(q), isFalse, reason: q);
      }
    });

    test('insensible a acentos y mayúsculas', () {
      expect(
        VoiceResponsePolicy.wantsFullReading('CUENTALE UN CUENTO'),
        isTrue,
      );
      expect(VoiceResponsePolicy.wantsFullReading(''), isFalse);
    });
  });

  group('VoiceResponsePolicy.isLikelySttHallucination', () {
    test('frases-outro típicas de Whisper se descartan', () {
      const hallucinations = [
        'Suscríbete al canal',
        'Please subscribe to the channel',
        'Gracias por ver el vídeo',
        'Gracias por ver el video',
        'Thanks for watching!',
        'Thank you for watching.',
        'Subtítulos realizados por la comunidad de Amara.org',
        // Etiquetas no verbales emitidas por STT sobre audio ambiente.
        '[Music]',
        '[Música]',
        '**[Música]**',
        '(noise)',
        '[Silence…]',
        '[Laughter]',
        '[Aplausos]',
      ];
      for (final h in hallucinations) {
        expect(
          VoiceResponsePolicy.isLikelySttHallucination(h),
          isTrue,
          reason: 'debería marcar como alucinación: "$h"',
        );
      }
    });

    test('cadena vacía o de ruido se descarta', () {
      expect(VoiceResponsePolicy.isLikelySttHallucination(''), isTrue);
      expect(VoiceResponsePolicy.isLikelySttHallucination('   '), isTrue);
      expect(VoiceResponsePolicy.isLikelySttHallucination('...'), isTrue);
    });

    test('entrada real del usuario NO se descarta', () {
      const real = [
        'Reinicia el agente por favor',
        'Gracias, ahora créame un archivo de notas',
        '¿Puedes buscar los habitantes de Madrid?',
        'Cuéntame un cuento sobre dragones',
        'Apaga la luz del salón y dame las gracias',
        'Quiero suscribirme al boletín de noticias del proyecto',
        'Suscríbeme al boletín',
        'Suscríbete',
        'Suscríbete, gracias',
        'Please subscribe',
        'Pon música tranquila',
        'Hay mucho ruido en la calle',
        'Escucho risas al fondo',
        // Sin confianza acústica, una cortesía o despedida breve es voz válida.
        'Gracias',
        'gracias.',
        'Muchas gracias',
        'Gracias por ver',
        'Gracias por su atención',
        'Thank you',
        'Thanks',
        'you',
        'Adiós',
        'Hasta luego',
        'Bye',
        'Amén',
      ];
      for (final r in real) {
        expect(
          VoiceResponsePolicy.isLikelySttHallucination(r),
          isFalse,
          reason: 'NO debería marcar entrada real: "$r"',
        );
      }
    });

    test('transcripciones chinas NO se descartan (CJK es texto válido)', () {
      const real = [
        '你好',
        '什麼情況?',
        '啥情況 你聽得到嗎',
        '你好,这是手机语音链录测试。',
        '请帮我查一下明天的天气',
        '谢谢',
        '混合中文 and English 123',
      ];
      for (final r in real) {
        expect(
          VoiceResponsePolicy.isLikelySttHallucination(r),
          isFalse,
          reason: 'NO debería marcar entrada china como alucinación: "$r"',
        );
      }
      // Punctuation-only CJK noise is still noise: the check is about real
      // letters (any script), not about letting everything through.
      expect(VoiceResponsePolicy.isLikelySttHallucination('。。。。。'), isTrue);
      expect(VoiceResponsePolicy.isLikelySttHallucination('，！？'), isTrue);
      // Símbolos y emoji no son letras: ruido puro se descarta igual.
      expect(VoiceResponsePolicy.isLikelySttHallucination('×÷'), isTrue);
      expect(VoiceResponsePolicy.isLikelySttHallucination('🎵🎶'), isTrue);
      expect(VoiceResponsePolicy.isLikelySttHallucination('・・・'), isTrue);
      // Dígitos no ASCII cuentan como contenido (árabe-índico).
      expect(VoiceResponsePolicy.isLikelySttHallucination('٣٢١'), isFalse);
    });
  });

  group('VoiceService.speakOrFallback — FallbackTts', () {
    test('respuesta OK: usa el motor primario, sin fallback', () async {
      final calls = <String>[];
      final ok = await VoiceService.speakOrFallback(
        text: 'hola',
        isLocal: false,
        primary: (t) async => calls.add('primary'),
        fallback: (t) async => calls.add('fallback'),
      );
      expect(ok, isTrue);
      expect(calls, ['primary']);
    });

    test(
      'respuesta: si el primario (ElevenLabs) falla, cae al sistema',
      () async {
        final calls = <String>[];
        final ok = await VoiceService.speakOrFallback(
          text: 'hola',
          isLocal: false,
          primary: (t) async {
            calls.add('primary');
            throw Exception('ElevenLabs 401');
          },
          fallback: (t) async => calls.add('fallback'),
        );
        expect(ok, isTrue);
        expect(calls, ['primary', 'fallback']);
      },
    );

    test('relleno local: si falla, NO insiste con fallback', () async {
      final calls = <String>[];
      final ok = await VoiceService.speakOrFallback(
        text: 'vale',
        isLocal: true,
        primary: (t) async {
          calls.add('primary');
          throw Exception('motor local caído');
        },
        fallback: (t) async => calls.add('fallback'),
      );
      expect(ok, isFalse);
      expect(calls, ['primary']);
    });

    test('ruta Hermes estricta no cambia a un motor local si falla', () async {
      final calls = <String>[];
      final ok = await VoiceService.speakOrFallback(
        text: 'hola',
        isLocal: false,
        allowFallback: false,
        primary: (t) async {
          calls.add('server');
          throw Exception('servidor no disponible');
        },
        fallback: (t) async => calls.add('local'),
      );
      expect(ok, isFalse);
      expect(calls, ['server']);
    });

    test('respuesta: si fallan ambos, devuelve false sin crash', () async {
      final ok = await VoiceService.speakOrFallback(
        text: 'hola',
        isLocal: false,
        primary: (t) async => throw Exception('premium caído'),
        fallback: (t) async => throw Exception('sistema caído'),
      );
      expect(ok, isFalse);
    });
  });
}
