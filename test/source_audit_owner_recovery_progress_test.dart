import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'source_audit_request_cancel_recovery_test.dart'
    show AuditDashboard, waitFor;
import 'support/in_memory_compression_restore_storage.dart';

class _Outbox implements TurnOutboxPersistence {
  @override
  Future<void> save(PreparedTurn turn) async {}
  @override
  Future<void> delete(PreparedTurn turn) async {}
}

class _ObservedClient extends TuiGatewayClient {
  _ObservedClient(super.connection) : super(dashboard: AuditDashboard());
  final proofs = <RecoveryProof>[];
  @override
  RecoveryProof recoveryProofForSnapshot(
    DesktopSessionSnapshot snapshot, {
    required String connectionId,
    required String profile,
    required int bindGeneration,
    required int sessionGeneration,
    required int turnGeneration,
    required Set<RecoveryDomain> coverage,
    int? postSnapshotSequence,
  }) {
    final proof = super.recoveryProofForSnapshot(
      snapshot,
      connectionId: connectionId,
      profile: profile,
      bindGeneration: bindGeneration,
      sessionGeneration: sessionGeneration,
      turnGeneration: turnGeneration,
      coverage: coverage,
      postSnapshotSequence: postSnapshotSequence,
    );
    proofs.add(proof);
    return proof;
  }
}

void main() {
  test(
    'real own-turn recovery waits on empty coverage then converges from terminal status and durable answer',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      var terminal = false;
      var statusCalls = 0;
      var submits = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'event',
            'params': {
              'type': 'gateway.ready',
              'payload': {'replay_epoch': 'owner-epoch'},
            },
          }),
        );
        await for (final raw in socket) {
          final frame = jsonDecode(raw as String) as Map<String, dynamic>;
          final method = frame['method'];
          if (method == null) continue;
          final params = frame['params'] as Map<String, dynamic>? ?? {};
          if (method == 'prompt.submit') submits++;
          if (method == 'turn.status') statusCalls++;
          final result = switch (method) {
            'gateway.capabilities' => {'per_session_exclusive_submit': true},
            'session.create' => {
              'session_id': 'runtime-owner',
              'stored_session_id': 'stored-owner',
              'messages': <dynamic>[],
              'running': false,
              'status': 'idle',
            },
            'session.resume' => {
              'session_id': 'runtime-owner',
              'stored_session_id': 'stored-owner',
              'messages': <dynamic>[],
              'running': !terminal,
              'last_sequence': 4,
              'replay_epoch': 'owner-epoch',
              'inflight': terminal
                  ? null
                  : {'assistant': 'partial recovery text', 'streaming': true},
              'status': terminal ? 'completed' : 'running',
            },
            'prompt.submit' => {
              'accepted': true,
              'client_turn_id': params['client_turn_id'],
              'server_turn_id': 'server-owner',
              'state': 'running',
              'duplicate': false,
            },
            'turn.status' => {
              'known': true,
              'client_turn_id': params['client_turn_id'],
              'server_turn_id': 'server-owner',
              'state': terminal ? 'terminal' : 'running',
            },
            'session.events.since' => {
              'epoch': 'owner-epoch',
              'truncated': true,
              'latest_seq': 4,
              'events': <dynamic>[],
            },
            _ => <String, dynamic>{},
          };
          if (socket.readyState != WebSocket.open) break;
          socket.add(
            jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
          );
        }
      });
      final connection = SavedConnection(
        id: 'owner-audit',
        label: 'Owner audit',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'synthetic-placeholder',
        kind: InstanceKind.vps,
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      );
      final gateway = _ObservedClient(connection);
      final events = <TuiGatewayEvent>[];
      final sub = gateway.events.listen(events.add, onError: (Object _) {});
      final chat = ActiveChat(
        compressionRestoreStore: testCompressionRestoreStore(),
        connection: connection,
        sessionId: 'mob-owner-audit',
        sessionTitle: 'Owner audit',
        notifications: null,
        onTerminal: () {},
        desktopGateway: gateway,
        turnIdempotencyCapability: () async => true,
        desktopRecoveryBackoff: const [Duration(milliseconds: 20)],
        desktopRecoveryRandom: () => 1,
        terminalReconcileBudget: const Duration(seconds: 1),
        api: ApiClient(
          baseUrl: 'http://127.0.0.1:1',
          apiKey: 'synthetic-placeholder',
          httpClient: MockClient((_) async => http.Response('not found', 404)),
        ),
        storedMessageLoader: (_, _) async => terminal
            ? [
                {
                  'message_id': 'owner-user',
                  'role': 'user',
                  'content': 'synthetic owner prompt',
                },
                {
                  'message_id': 'owner-final',
                  'role': 'assistant',
                  'content': 'Durable owner final',
                },
              ]
            : [],
      );
      addTearDown(() async {
        chat.dispose();
        await sub.cancel();
        await gateway.close();
        await server.close(force: true);
      });
      await chat.send(
        fullText: 'synthetic owner prompt',
        model: 'hermes-agent',
        history: const [],
        delivery: ActiveTurnDelivery(
          prepared: PreparedTurn(
            connectionId: 'owner-audit',
            sessionId: 'mob-owner-audit',
            clientTurnId: 'turn-owner',
            createdAtMs: 1,
            updatedAtMs: 1,
            text: 'synthetic owner prompt',
            attachments: const [],
            model: 'hermes-agent',
            profile: '',
          ),
          store: _Outbox(),
        ),
      );
      expect(submits, 1);
      void event(String type, int seq) => sockets.last.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {
            'type': type,
            'session_id': 'runtime-owner',
            'seq': seq,
            'payload': {},
          },
        }),
      );
      event('message.start', 1);
      await waitFor(() => events.any((e) => e.type == 'message.start'));
      event('message.delta', 3);
      event('tool.start', 4);
      sockets.last.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'srq-ownerbarrier',
          'method': 'clarify',
          'params': {
            'session_id': 'runtime-owner',
            'question': 'Synthetic barrier',
          },
        }),
      );
      await waitFor(
        () => events.any((e) => e.payload['request_id'] == 'srq-ownerbarrier'),
      );
      expect(events.where((e) => e.type == 'tool.start'), isEmpty);
      await sockets.last.close(WebSocketStatus.goingAway, 'synthetic recovery');
      await waitFor(() => gateway.proofs.length >= 3);
      expect(statusCalls, greaterThanOrEqualTo(3));
      expect(gateway.proofs.every((proof) => proof.coverage.isEmpty), isTrue);
      expect(chat.state, ChatPipelineState.connecting);
      expect(
        chat.messages.where((row) => row['role'] == 'assistant_error'),
        isEmpty,
      );
      expect(submits, 1);
      terminal = true;
      chat.requestImmediateTransportRecovery();
      await waitFor(() => chat.state == ChatPipelineState.completed);
      await waitFor(
        () =>
            chat.messages.any((row) => row['content'] == 'Durable owner final'),
      );
      expect(
        chat.messages.where((row) => row['role'] == 'assistant_error'),
        isEmpty,
      );
      expect(submits, 1);
    },
  );
}
