import 'dart:typed_data';

import '../data/companion_error_codes.dart';

/// Abstracción "de dónde sale la imagen" para incubar (Hatch) una mascota.
///
/// Desacopla la UI/servicio de la fuente de generación. En v1 hay dos
/// implementaciones: [MockHatchProvider] (tests/offline, sin red) y el
/// proveedor de la conexión Hermes existente (gated por probe/opt-in). NO hay
/// proveedores de pago ni credenciales nuevas en v1.
abstract class HatchProvider {
  /// Indica si el proveedor puede usarse AHORA (incluye el probe de
  /// capacidades). Nunca lanza: ante cualquier duda devuelve no disponible.
  Future<HatchAvailability> availability();

  /// Genera una imagen **estática** a partir del prompt. Lanza
  /// [HatchException] ante cualquier fallo (red, formato, timeout…).
  Future<HatchResult> generate(HatchRequest request);
}

/// Disponibilidad de un proveedor de generación.
class HatchAvailability {
  /// Si el proveedor puede generar ahora mismo.
  final bool available;

  /// Motivo cuando `!available`: el `name` de [code] (código estable, sin texto
  /// de interfaz) o el texto libre de un doble de test.
  final String reason;

  /// Código estable del motivo; `null` en textos libres de test.
  final CompanionErrorCode? code;

  /// `true` si generar enviará el prompt **fuera del dispositivo** (al gateway
  /// del usuario). La UI debe pedir consentimiento de privacidad antes.
  final bool requiresPrivacyConsent;

  const HatchAvailability({
    required this.available,
    this.reason = '',
    this.requiresPrivacyConsent = false,
    this.code,
  });

  const HatchAvailability.unavailable(String reason) : this(available: false, reason: reason);

  /// No disponible por un motivo propio del subsistema de mascotas.
  factory HatchAvailability.coded(CompanionErrorCode code) =>
      HatchAvailability(available: false, reason: code.name, code: code);
}

/// Petición de generación (prompt ya saneado por `prompt_safety`).
class HatchRequest {
  final String prompt;
  const HatchRequest(this.prompt);
}

/// Resultado de generación: bytes de una imagen estática (PNG/WEBP) + metadatos.
class HatchResult {
  final Uint8List imageBytes;

  /// Nombre de fichero sugerido (debe acabar en `.png` o `.webp`).
  final String fileName;

  /// Autor/fuente para el `pet.json` (p. ej. "Hatch (gateway)").
  final String? author;

  /// Nota opcional (p. ej. modelo usado).
  final String? note;

  const HatchResult({
    required this.imageBytes,
    this.fileName = 'spritesheet.png',
    this.author,
    this.note,
  });
}

/// Error de generación (la UI lo trata como error suave, sin dejar estado
/// colgado ni artefactos a medias).
class HatchException implements CompanionCodedError {
  /// Identificador estable del fallo, o texto libre de un doble de test.
  final String message;

  @override
  final CompanionErrorCode? code;

  HatchException(this.message, {this.code});

  /// Fallo propio del subsistema: el mensaje es el código estable, sin texto de
  /// interfaz.
  HatchException.code(CompanionErrorCode code) : this(code.name, code: code);

  @override
  String toString() => 'HatchException: $message';
}
