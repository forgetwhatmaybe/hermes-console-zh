// Política de qué se puede leer en voz alta en el modo voz.
//
// Decide, frase a frase, qué parte de la respuesta del agente es PROSA apta para
// el TTS y qué es CONTENIDO TÉCNICO (bloques de código, JSON, logs, stack
// traces, tablas densas) que no debe leerse. Esto cumple dos objetivos:
//   1. UX: leer un bloque de código o un volcado JSON en voz alta es ruido; es
//      mejor dejarlo en pantalla y avisar una vez ("te lo he dejado en pantalla").
//   2. Coste/privacidad: el contenido técnico NUNCA debe enviarse al TTS premium
//      de nube (ElevenLabs) — gastaría créditos leyendo basura técnica. Esta
//      policy se aplica ANTES de encolar para hablar, así el contenido técnico no
//      llega a ningún motor (ni local ni de nube).
//
// Pura y sin estado: no depende de Flutter ni de servicios, por lo que es
// directamente testeable. Cualquier aviso visual derivado del veredicto lo
// decide quien la invoca, no esta policy.

/// Veredicto de [VoiceResponsePolicy.evaluate] sobre un trozo de respuesta.
class VoiceVerdict {
  /// Texto apto para leer en voz alta (vacío si se descartó por técnico).
  final String speakableText;

  /// true si se descartó leer porque era contenido técnico (código/JSON/logs…).
  final bool skippedTechnicalContent;

  /// Etiqueta corta del motivo del descarte (diagnóstico/tests). Null si se lee.
  final String? reason;

  const VoiceVerdict({
    required this.speakableText,
    this.skippedTechnicalContent = false,
    this.reason,
  });

  /// ¿Hay algo que leer en voz alta?
  bool get hasSpeakable => speakableText.isNotEmpty;
}

class VoiceResponsePolicy {
  /// Evalúa un trozo (ya segmentado en frase/línea) de la respuesta del agente.
  /// Devuelve la prosa apta para hablar o, si es técnico, un veredicto de
  /// descarte con el motivo. Conservador: ante la duda, prefiere leer prosa a
  /// silenciarla; solo descarta lo claramente técnico.
  static VoiceVerdict evaluate(String chunk) {
    final t = chunk.trim();
    if (t.isEmpty) {
      return const VoiceVerdict(speakableText: '');
    }
    // Bloque de código con vallas Markdown.
    if (t.startsWith('```')) {
      return const VoiceVerdict(
        speakableText: '',
        skippedTechnicalContent: true,
        reason: 'code-fence',
      );
    }
    // JSON / objeto / array volcado (incluso en una sola línea larga): empieza
    // por { o [ y tiene varias parejas "clave": — leerlo es ruido y caro.
    if ((t.startsWith('{') || t.startsWith('[')) &&
        RegExp(r'"\s*:\s*').allMatches(t).length >= 2) {
      return const VoiceVerdict(
        speakableText: '',
        skippedTechnicalContent: true,
        reason: 'json',
      );
    }
    // Stack trace / log estructurado: varias líneas que empiezan por "at ",
    // niveles de log o un patrón fichero:línea repetido.
    final lines = t.split('\n');
    if (lines.length >= 2) {
      final traceLines = lines.where((l) {
        final s = l.trimLeft();
        return s.startsWith('at ') ||
            RegExp(r'^(ERROR|WARN|INFO|DEBUG|TRACE|FATAL)\b').hasMatch(s) ||
            RegExp(r'\.\w+:\d+').hasMatch(s);
      }).length;
      if (traceLines >= 2) {
        return const VoiceVerdict(
          speakableText: '',
          skippedTechnicalContent: true,
          reason: 'log',
        );
      }
    }
    // Texto con mucho salto de línea + densidad de símbolos: tablas, listados de
    // rutas, salidas de herramienta. Heurística histórica (no romper).
    final newlines = '\n'.allMatches(t).length;
    final symbols = RegExp(
      r'[^\p{L}\p{N}\s.,;:¿?¡!…]',
      unicode: true,
    ).allMatches(t).length;
    if (newlines >= 3 && symbols > t.length * 0.20) {
      return const VoiceVerdict(
        speakableText: '',
        skippedTechnicalContent: true,
        reason: 'dense-symbols',
      );
    }
    return VoiceVerdict(speakableText: t);
  }

  /// Atajo: ¿este trozo es apto para leer en voz alta? (compat con el filtro
  /// anterior `_speakableChunk`).
  static bool speakable(String chunk) => evaluate(chunk).hasSpeakable;

  /// ¿La PETICIÓN del usuario pide algo para LEER ENTERO en voz alta (narrativa
  /// o creativa: un cuento, un relato, un poema, un chiste, una canción, "léeme
  /// esto"…)? En ese caso el modo voz NO recorta la respuesta con el presupuesto
  /// de resumen: el usuario quiere oírlo completo (p.ej. "cuéntale un cuento a mi
  /// hija"). Para todo lo demás (buscar, explicar, consultar datos) se mantiene
  /// el resumen hablado + "el resto en pantalla".
  ///
  /// Conservador a propósito: exige el sustantivo narrativo concreto para no
  /// confundir "cuéntame las noticias" o "cuéntame qué pasó" (que SÍ se resumen)
  /// con "cuéntame un cuento". Insensible a mayúsculas y acentos.
  static bool wantsFullReading(String userRequest) {
    final t = _normalize(userRequest);
    if (t.trim().isEmpty) return false;
    // Palabras sueltas con LÍMITE de palabra (`\b`): así "cuento" no salta dentro
    // de "descuento"/"recuento" ni "narra" dentro de otra palabra. El texto ya
    // está sin acentos, así que `\b` (ASCII) basta.
    if (_fullReadingWords.hasMatch(t)) return true;
    // Frases (varias palabras): substring directo, son inequívocas.
    const phrases = [
      'una historia',
      'historia para dormir',
      'lee en voz alta',
      'letra de',
    ];
    return phrases.any(t.contains);
  }

  /// ¿El transcript del STT es una ALUCINACIÓN típica de Whisper sobre
  /// silencio/ruido? Los modelos Whisper, cuando el audio es muy corto o no tiene
  /// voz real, "rellenan" con frases de cierre de vídeos de YouTube de su corpus
  /// ("¡Suscríbete!", "Gracias por ver el vídeo", "Thanks for watching",
  /// "Subtítulos por la comunidad de Amara.org"…). En el modo voz manos libres
  /// eso se ENVIABA al agente como si lo hubiera dicho el usuario. Aquí lo
  /// detectamos para descartarlo y volver a escuchar, sin mandar basura.
  ///
  /// MUY conservador para no tragarse entrada real: solo marca frases que un
  /// usuario no le diría a su asistente personal (marcadores inequívocos) o
  /// frases CORTAS que son únicamente una llamada a suscribirse/un cierre.
  /// Insensible a mayúsculas, acentos y puntuación.
  static bool isLikelySttHallucination(String transcript) {
    final raw = transcript.trim();
    // Algunos motores devuelven etiquetas no verbales en vez de una frase
    // (p. ej. "[Music]" sobre una televisión de fondo). En manos libres esas
    // etiquetas no son intención del usuario y jamás deben convertirse en un
    // turno del agente. La forma delimitada hace el filtro conservador:
    // "pon música" sigue siendo una petición válida.
    if (_nonSpeechLabel.hasMatch(_normalize(raw))) return true;
    var t = _normalize(transcript);
    // Quita todo salvo letras ASCII (ya sin acentos), dígitos, punto y espacio;
    // colapsa espacios. Conserva el punto para reconocer "amara.org".
    t = t
        .replaceAll(RegExp(r'[^a-z0-9. ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Sin letras ni dígitos (vacío, espacios o solo puntuación "…"): nada útil.
    // El test de "quedó algo escrito" es por ESCRIPT, no por alfabeto: un turno
    // chino/japonés/coreano sobrevive entero a la limpieza ASCII y no puede caer
    // aquí, o cada dictado CJK se descartaría como alucinación. Puntuación CJK
    // de ancho completo (，！？), símbolos (×÷) y emoji NO son \p{L}/\p{N}:
    // solo ruido de signos sigue descartándose.
    final keepsLettersOrDigits =
        _cjkOrOtherLetters.hasMatch(raw) ||
        _otherNumbers.hasMatch(raw) ||
        RegExp(r'[a-z0-9]').hasMatch(t);
    if (!keepsLettersOrDigits) return true;
    // Marcadores inequívocos de outro/subtítulos automáticos.
    const strongMarkers = [
      'amara.org',
      'subtitulos realizados por',
      'subtitulado por',
      'thanks for watching',
      'thanks watching',
      'thank you for watching',
      'thank you watching',
      'gracias por ver el video',
    ];
    for (final m in strongMarkers) {
      if (t.contains(m)) return true;
    }
    // Una cortesía o despedida breve también puede ser una orden real del
    // usuario. Sin confianza acústica no se debe borrar "gracias", "adiós",
    // "thanks", "bye", etc. Solo conserva el patrón inequívoco de outro que
    // menciona el canal; "suscríbete" o "suscríbeme al boletín" no coinciden.
    final tNoDot = t.replaceAll('.', '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final subscribeOutro = RegExp(
      r'^(?:(?:por favor )?(?:suscribete|suscribanse) al canal|'
      r'(?:please )?subscribe to the channel)(?: gracias)?$',
    );
    if (subscribeOutro.hasMatch(tNoDot)) return true;
    return false;
  }

  static final RegExp _fullReadingWords = RegExp(
    r'\b('
    r'cuento|cuentos|cuentito|cuentitos|relato|relatos|fabula|fabulas|'
    r'poema|poemas|poesia|poesias|chiste|chistes|adivinanza|adivinanzas|'
    r'trabalenguas|cancion|canciones|cantame|'
    r'recita|recitame|recitalo|recitanos|'
    r'leeme|leelo|leenos|narrame|narranos'
    r')\b',
  );

  static final RegExp _nonSpeechLabel = RegExp(
    r'^[*_~\s]*[\[\(\{<]\s*'
    r'(music|musica|noise|ruido|silence|silencio|'
    r'laughter|laughs?|risas?|applause|aplausos?|'
    r'inaudible|ininteligible)'
    r'\s*[.!…]*\s*[\]\)\}>][*_~\s.!…]*$',
    caseSensitive: false,
    unicode: true,
  );

  /// Letras FUERA del alfabeto ASCII (CJK y demás escrituras): su presencia
  /// tras la limpieza significa que el turno está escrito en otro idioma, no
  /// que sea rango. Categoría Unicode L* (letter) del motor ECMAScript: puntuación
  /// CJK de ancho completo (，！？ U+FF01..U+FF5E), símbolos (×÷) y emoji NO
  /// son letras y siguen contando como "nada útil".
  static final _cjkOrOtherLetters = RegExp(r'\p{L}', unicode: true);

  /// Dígitos no ASCII (árabe-índico, etc.): misma lógica que [a-z0-9] para el
  /// alfabeto latino, con la categoría Unicode N (número).
  static final _otherNumbers = RegExp(r'\p{N}', unicode: true);

  /// Minúsculas + sin acentos/ñ, para que la detección no dependa de cómo el STT
  /// transcriba los acentos.
  static String _normalize(String s) {
    var t = s.toLowerCase();
    const map = {
      'á': 'a',
      'é': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'ü': 'u',
      'ñ': 'n',
    };
    map.forEach((k, v) => t = t.replaceAll(k, v));
    return t;
  }
}
