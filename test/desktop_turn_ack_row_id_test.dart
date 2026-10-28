import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

/// The submit ack may carry the durable transcript row the server wrote for
/// this prompt. It is what lets an edit address the row directly instead of
/// guessing by message text — see `resolveDurableUserRowId`.
///
/// It is optional by contract (absent on queued/steered/redirected deliveries
/// and whenever persistence is not yet proven), so every shape here must be
/// tolerated without failing the submit.
void main() {
  Map<String, dynamic> ack({
    Object? userRowId = _absent,
    String clientTurnId = 'turn-1',
  }) {
    final json = <String, dynamic>{
      'accepted': true,
      'client_turn_id': clientTurnId,
      'server_turn_id': 'srv-1',
      'state': 'running',
      'duplicate': false,
    };
    if (!identical(userRowId, _absent)) json['user_row_id'] = userRowId;
    return json;
  }

  test('a usable user_row_id is parsed through to the ack', () {
    final parsed = DesktopTurnAck.fromJson(
      ack(userRowId: 4242),
      expectedClientTurnId: 'turn-1',
    );
    expect(parsed.userRowId, 4242);
  });

  test('a missing user_row_id is null, not an error', () {
    final parsed = DesktopTurnAck.fromJson(
      ack(),
      expectedClientTurnId: 'turn-1',
    );
    expect(parsed.userRowId, isNull);
    expect(parsed.accepted, isTrue);
  });

  test('junk user_row_id values degrade to null instead of failing the submit',
      () {
    for (final junk in <Object?>[null, '', '4242', 0, -7, 4.2, true]) {
      final parsed = DesktopTurnAck.fromJson(
        ack(userRowId: junk),
        expectedClientTurnId: 'turn-1',
      );
      expect(
        parsed.userRowId,
        isNull,
        reason: 'user_row_id=$junk must not be accepted and must not throw',
      );
    }
  });

  test('a constant constructor keeps the legacy positional call sites valid',
      () {
    const legacy = DesktopTurnAck(
      accepted: true,
      clientTurnId: 'turn-1',
      serverTurnId: 'srv-1',
      state: DesktopTurnState.running,
      duplicate: false,
    );
    expect(legacy.userRowId, isNull);
  });
}

const Object _absent = Object();
