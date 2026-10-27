import '../../../l10n/app_localizations.dart';

/// Preset histórico de tamaño de la mascota "Companion" (Fase B / US2).
///
/// Se conserva para migrar preferencias S/M/L y compatibilidad con versiones
/// anteriores. La UI actual persiste un multiplicador continuo acotado.
enum CompanionScale {
  small,
  medium,
  large;

  /// Factor aplicado al `size` base. Acotado a un rango seguro.
  double get multiplier {
    switch (this) {
      case CompanionScale.small:
        return 0.8;
      case CompanionScale.medium:
        return 1.0;
      case CompanionScale.large:
        return 1.25;
    }
  }

  /// Identificador estable para persistencia (== nombre del enum).
  String get id => name;

  /// Etiqueta corta para la UI (selector S/M/L).
  String get shortLabel {
    switch (this) {
      case CompanionScale.small:
        return 'S';
      case CompanionScale.medium:
        return 'M';
      case CompanionScale.large:
        return 'L';
    }
  }

  /// Etiqueta legible para accesibilidad/semántica en el idioma activo.
  String labelFor(Strings strings) {
    switch (this) {
      case CompanionScale.small:
        return strings.petSizeSmall;
      case CompanionScale.medium:
        return strings.petSizeMedium;
      case CompanionScale.large:
        return strings.petSizeLarge;
    }
  }

  /// Default seguro cuando la preferencia está ausente o es inválida.
  static const CompanionScale fallback = CompanionScale.medium;

  /// Parseo tolerante desde el identificador persistido. Cualquier valor
  /// desconocido/nulo cae a [fallback] (`medium`).
  static CompanionScale fromId(String? id) {
    for (final scale in values) {
      if (scale.name == id) return scale;
    }
    return fallback;
  }
}
