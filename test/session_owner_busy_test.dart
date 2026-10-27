import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

TuiGatewayRpcError _error(String? reason) => TuiGatewayRpcError(
  'prompt.submit',
  'gateway refused',
  code: 4090,
  data: reason == null ? const {} : {'reason': reason},
);

void main() {
  test('SESSION_OWNER_BUSY: texto propio, pero sigue siendo ambiguo', () {
    final error = _error('SESSION_OWNER_BUSY');
    expect(
      activeChatPromptFailureUiMessage(error),
      contains('no quedó confirmada'),
    );
    // El forwarder puede responder éxito sin admission_id y aun así acabar en
    // BUSY (owner_forward.OwnerUnavailable). No se puede afirmar "no entregado":
    // la clasificación se queda ambigua hasta que el servidor lo distinga.
    expect(activeChatPromptWasRejectedBeforeAcceptance(error), isFalse);
  });

  test('SESSION_OWNER_UNCONFIRMED: puede estar en cola, no es rechazo', () {
    final error = _error('SESSION_OWNER_UNCONFIRMED');
    expect(
      activeChatPromptFailureUiMessage(error),
      contains('puede que ya esté en su cola'),
    );
    expect(activeChatPromptWasRejectedBeforeAcceptance(error), isFalse);
  });

  test('SESSION_NOT_OWNED conserva su texto y sigue siendo rechazo', () {
    final error = _error('SESSION_NOT_OWNED');
    expect(
      activeChatPromptFailureUiMessage(error),
      contains('pertenece a otro gateway'),
    );
    expect(activeChatPromptWasRejectedBeforeAcceptance(error), isTrue);
  });
}
