import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:hermes_android/core/utils/chat_turn.dart';

/// Gateway idempotente mínimo que sólo responde al `prompt.submit` moderno.
///
/// El ACK es el objeto bajo prueba: la lógica de ActiveChat escribe
/// `ack.userRowId` en la fila user optimista, así que el fake debe poder
/// devolverlo (o no) tal cual, y opcionalmente retener la respuesta para que el
/// test observe el transcript en mitad del submit.
class _AckGateway implements HermesDesktopGateway, HermesDesktopIdempotentGateway {
  _AckGateway({required this.userRowId});

  final int? userRowId;
  final _events = StreamController<TuiGatewayEvent>.broadcast();
  final List<(String, String, String)> idempotentSubmissions = [];
  final List<String> legacySubmissions = [];

  /// Cuando está presente, `submitPromptIdempotent` espera antes de devolver el
  /// ACK: así el test puede tocar la fila optimista justo antes de que el ACK
  /// llegue y comprobar que no la pisa.
  Completer<void>? ackGate;
  final Completer<void> ackEntered = Completer<void>();

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect() async {}

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-ack',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    legacySubmissions.add(text);
  }

  @override
  Future<void> steer(String runtimeSessionId, String text) async {}

  @override
  Future<void> interrupt(String runtimeSessionId) async {}

  @override
  Future<void> resolveApproval(
    String runtimeSessionId,
    String choice, {
    bool resolveAll = false,
    String? requestId,
  }) async {}

  @override
  Future<void> close() => _events.close();

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    idempotentSubmissions.add((runtimeSessionId, text, clientTurnId));
    if (!ackEntered.isCompleted) ackEntered.complete();
    await ackGate?.future;
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: 'server-turn-1',
      state: DesktopTurnState.accepted,
      duplicate: false,
      userRowId: userRowId,
    );
  }

  @override
  Future<bool> supportsTurnIdempotency() async => true;

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  ) async => DesktopTurnStatus(known: false, clientTurnId: clientTurnId);
}

class _MemoryOutbox implements TurnOutboxPersistence {
  @override
  Future<void> save(PreparedTurn turn) async {}

  @override
  Future<void> delete(PreparedTurn turn) async {}
}

({ActiveChat chat, ActiveTurnDelivery delivery}) _fixture(
  _AckGateway gateway,
) {
  final connection = SavedConnection(
    id: 'conn-ack',
    label: 'Ack',
    host: 'example.invalid',
    port: 443,
    apiKey: 'test-only',
    useHttps: true,
  );
  final chat = ActiveChat(
    connection: connection,
    sessionId: 'session-ack',
    sessionTitle: 'Ack',
    notifications: null,
    onTerminal: () {},
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'test-only',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
    allowUnownedDesktopSnapshotForTesting: true,
    turnIdempotencyCapability: () async => true,
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  final delivery = ActiveTurnDelivery(
    prepared: PreparedTurn(
      connectionId: connection.id,
      sessionId: 'session-ack',
      clientTurnId: 'client-turn-ack',
      createdAtMs: now,
      updatedAtMs: now,
      text: 'mensaje con ack',
      attachments: const [],
      model: 'hermes-agent',
      profile: '',
    ),
    store: _MemoryOutbox(),
  );
  return (chat: chat, delivery: delivery);
}

/// La fila user que el ACK debe direccionar: el primer turno real contando desde
/// el frente, porque `_messages` está ordenado del más nuevo al más viejo.
Map<String, dynamic> _boundUserRow(ActiveChat chat) => chat
    .internalMessagesForTesting
    .firstWhere((message) => isRealUserTurn(message));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ack carrying user_row_id stamps the durable row on the prompt', () async {
    final gateway = _AckGateway(userRowId: 77);
    final fixture = _fixture(gateway);
    addTearDown(fixture.chat.dispose);

    final accepted = await fixture.chat.send(
      fullText: 'mensaje con ack',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isTrue);
    expect(gateway.idempotentSubmissions, hasLength(1));
    final row = _boundUserRow(fixture.chat);
    expect(row['content'], 'mensaje con ack');
    expect(row['_desktopRowId'], 77);
    expect(canonicalTranscriptRowId(row), 77);
  });

  test('ack carrying user_row_id does not overwrite an existing row id', () async {
    final gateway = _AckGateway(userRowId: 77)..ackGate = Completer<void>();
    final fixture = _fixture(gateway);
    addTearDown(fixture.chat.dispose);

    final send = fixture.chat.send(
      fullText: 'mensaje con ack',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );
    await gateway.ackEntered.future;

    // La fila optimista ya existe y ya sabe su row: el ACK sólo debe rellenar
    // huecos, nunca reemplazar una identidad durable que ya era correcta.
    final row = _boundUserRow(fixture.chat);
    row['_desktopRowId'] = 11;

    gateway.ackGate!.complete();
    expect(await send, isTrue);

    expect(_boundUserRow(fixture.chat)['_desktopRowId'], 11);
  });

  test('wire ack parses user_row_id into the field the service reads', () {
    // Cierra el eslabón servidor → modelo: la clave `user_row_id` del JSON es
    // la única fuente de `DesktopTurnAck.userRowId`, que es lo que consume el
    // servicio. Sin esto el primer test sólo probaría el fake.
    final ack = DesktopTurnAck.fromJson(const {
      'accepted': true,
      'client_turn_id': 'client-turn-1',
      'server_turn_id': 'server-turn-1',
      'state': 'accepted',
      'duplicate': false,
      'user_row_id': 77,
    }, expectedClientTurnId: 'client-turn-1');

    expect(ack.userRowId, 77);
  });

  test('ack without user_row_id leaves the prompt unaddressed and still succeeds', () async {
    final gateway = _AckGateway(userRowId: null);
    final fixture = _fixture(gateway);
    addTearDown(fixture.chat.dispose);

    final accepted = await fixture.chat.send(
      fullText: 'mensaje con ack',
      model: 'hermes-agent',
      history: const [],
      delivery: fixture.delivery,
    );

    expect(accepted, isTrue);
    final row = _boundUserRow(fixture.chat);
    expect(row['content'], 'mensaje con ack');
    expect(row.containsKey('_desktopRowId'), isFalse);
    expect(canonicalTranscriptRowId(row), isNull);
  });
}
