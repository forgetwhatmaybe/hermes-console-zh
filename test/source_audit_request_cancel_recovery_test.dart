import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

class AuditDashboard extends DashboardClient {
  AuditDashboard()
    : super(host: '127.0.0.1', port: 1, manualToken: 'audit-placeholder');
  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'audit-placeholder',
      );
}

Future<void> waitFor(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!condition() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: 'test event barrier');
}

void main() {
  for (final recovered in [false, true]) {
    test(
      '${recovered ? 'snapshot release' : 'normal live'} translates cancelled clarify and closes its registration',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        WebSocket? socket;
        final requests = <Map<String, dynamic>>[];
        server.listen((request) async {
          final peer = await WebSocketTransformer.upgrade(request);
          socket = peer;
          peer.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'method': 'event',
              'params': {
                'type': 'gateway.ready',
                'payload': {'replay_epoch': 'audit-epoch'},
              },
            }),
          );
          await for (final raw in peer) {
            final frame = jsonDecode(raw as String) as Map<String, dynamic>;
            requests.add(frame);
            if (frame['method'] == null) continue;
            peer.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': frame['id'],
                'result': {'status': 'ok'},
              }),
            );
          }
        });
        final client = TuiGatewayClient(
          SavedConnection(
            id: 'audit-connection',
            label: 'Audit',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'audit-placeholder',
            dashboardUrl: 'http://127.0.0.1:${server.port}',
          ),
          dashboard: AuditDashboard(),
        );
        final events = <TuiGatewayEvent>[];
        final subscription = client.events.listen(
          events.add,
          onError: (Object _) {},
        );
        addTearDown(() async {
          await subscription.cancel();
          await client.close();
          await server.close(force: true);
        });
        await client.connect();
        void pushEvent(String type, int seq, Map<String, dynamic> payload) =>
            socket!.add(
              jsonEncode({
                'jsonrpc': '2.0',
                'method': 'event',
                'params': {
                  'type': type,
                  'session_id': 'audit-runtime',
                  'seq': seq,
                  'payload': payload,
                },
              }),
            );
        void pushQuestion(String id) => socket!.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'method': 'clarify',
            'params': {
              'session_id': 'audit-runtime',
              'question': 'Synthetic audit question',
            },
          }),
        );
        pushEvent('message.start', 1, {});
        await waitFor(() => events.any((e) => e.type == 'message.start'));
        if (recovered) {
          pushEvent('message.delta', 3, {
            'text': 'snapshot covered synthetic text',
          }); // seq2 lost => quarantine
        }
        pushQuestion('srq-auditquestion');
        await waitFor(
          () => events.any(
            (e) =>
                e.type == 'clarify.request' &&
                e.payload['request_id'] == 'srq-auditquestion',
          ),
        );
        pushEvent('request.cancel', recovered ? 4 : 2, {
          'id': 'srq-auditquestion',
          'method': 'clarify',
          'reason': 'timeout',
        });
        pushQuestion('srq-auditbarrier');
        await waitFor(
          () =>
              events.any((e) => e.payload['request_id'] == 'srq-auditbarrier'),
        );
        if (recovered) {
          expect(
            client.adoptViewerSnapshotBoundary(
              runtimeSessionId: 'audit-runtime',
              baseline: 3,
              replayEpoch: 'audit-epoch',
            ),
            isTrue,
          );
          await waitFor(
            () => events.any(
              (e) => e.type == 'request.cancel' || e.type == 'clarify.expire',
            ),
          );
        }
        await client.respondToClarify(
          'srq-auditquestion',
          'synthetic late answer',
        );
        await waitFor(
          () => requests.any(
            (f) =>
                f['method'] == 'request.answer' ||
                f['id'] == 'srq-auditquestion',
          ),
        );
        final orphanResponse = requests.any(
          (f) => f['id'] == 'srq-auditquestion' && f['method'] == null,
        );
        expect(
          events.where((e) => e.type == 'clarify.expire'),
          hasLength(1),
          reason:
              'all dispatch paths must translate the cancel to clear the UI',
        );
        expect(events.where((e) => e.type == 'request.cancel'), isEmpty);
        expect(
          orphanResponse,
          isFalse,
          reason:
              'cancelled request must leave registry, late answer must use request.answer',
        );
      },
    );
  }
}
