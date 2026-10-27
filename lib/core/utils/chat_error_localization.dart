import '../../l10n/app_localizations.dart';

/// Constantes que `active_chat_service` escribe en la fila `assistant_error`.
/// Se comparan enteras (o por prefijo exacto) para no reescribir texto libre.
const _recoveryTurn = 'No se pudo recuperar el turno. Inténtalo de nuevo.';
const _responseIncomplete =
    'No se pudo completar la respuesta. Inténtalo de nuevo.';
const _responseCausePrefix = 'No se pudo completar la respuesta: ';
const _connectionLost =
    'Se perdió la conexión con Hermes. El mensaje no se confirmó; '
    'revisa el borrador y reintenta.';
const _ownershipConflict =
    'No se puede continuar esta conversación en directo. '
    'El historial se conserva y puedes iniciar un chat nuevo.';
const _turnNotKept = 'No se pudo conservar el turno antes de enviarlo.';
const _attachmentUnreadable = 'No se pudo leer un adjunto local.';
const _sendAuthLost = 'El envío perdió su autorización antes de entregarse.';
const _sendFailed = 'No se pudo enviar el mensaje. Inténtalo de nuevo.';
const _ownerBusy =
    'El gateway está ejecutando un turno en este chat: la entrega no quedó '
    'confirmada. Vuelve a enviarlo cuando termine.';
const _ownerUnconfirmed =
    'El gateway no confirmó este mensaje; puede que ya esté en su cola. '
    'Revisa el chat antes de enviarlo otra vez.';
const _notOwned =
    'No se puede continuar en directo porque esta conversación pertenece a '
    'otro gateway o proceso. El historial se conserva y puedes iniciar un '
    'chat nuevo.';
const _maxSessions =
    'Hermes alcanzó el límite configurado de sesiones activas. Espera a que '
    'termine una sesión o ajusta el límite.';
const _coordUnavailable =
    'Hermes no pudo reservar esta conversación con seguridad. Revisa el '
    'servidor y vuelve a intentarlo.';

/// Traduce en el borde de pintado las constantes de error del servicio.
///
/// El servicio no tiene `BuildContext` y escribe sus mensajes en español; esta
/// función los sustituye por la cadena del idioma activo. Cualquier otro texto
/// (causa remota, mensaje libre) se devuelve intacto: nunca se reescribe prosa.
String localizedChatError(String raw, Strings strings) {
  // `left` conserva los bytes del original: la causa remota se corta de aquí,
  // no de una copia recortada, para no perder espacios ni saltos de línea.
  final left = raw.trimLeft();
  switch (left.trim()) {
    case _recoveryTurn:
      return strings.errRecoveryTurn;
    case _responseIncomplete:
      return strings.errResponseIncomplete;
    case _connectionLost:
      return strings.errConnectionLost;
    case _ownershipConflict:
      return strings.errOwnershipConflict;
    case _turnNotKept:
      return strings.errTurnNotKept;
    case _attachmentUnreadable:
      return strings.errAttachmentUnreadable;
    case _sendAuthLost:
      return strings.errSendAuthLost;
    case _sendFailed:
      return strings.errSendFailed;
    case _ownerBusy:
      return strings.errSessionOwnerBusy;
    case _ownerUnconfirmed:
      return strings.errSessionOwnerUnconfirmed;
    case _notOwned:
      return strings.errSessionNotOwned;
    case _maxSessions:
      return strings.errMaxConcurrentSessions;
    case _coordUnavailable:
      return strings.errSessionCoordUnavailable;
  }
  if (left.startsWith(_responseCausePrefix)) {
    final cause = left.substring(_responseCausePrefix.length);
    if (cause.trim().isEmpty) return strings.errResponseIncomplete;
    return strings.errResponseIncompleteCause(cause);
  }
  return raw;
}
