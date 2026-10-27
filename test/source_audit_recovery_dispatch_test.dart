import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'source_audit_request_cancel_recovery_test.dart'
    show AuditDashboard, waitFor;

class _Gateway {
  final HttpServer server;
  late WebSocket socket;
  late TuiGatewayClient client;
  late StreamSubscription<TuiGatewayEvent> subscription;
  final frames = <Map<String, dynamic>>[];
  final events = <TuiGatewayEvent>[];
  DateTime now = DateTime.utc(2026, 1, 1);

  _Gateway(this.server);

  static Future<_Gateway> start() async {
    final gateway = _Gateway(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    gateway.server.listen((request) async {
      gateway.socket = await WebSocketTransformer.upgrade(request);
      gateway.push({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {
          'type': 'gateway.ready',
          'payload': {'replay_epoch': 'audit-epoch'},
        },
      });
      await for (final raw in gateway.socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        gateway.frames.add(frame);
        if (frame['method'] == null) continue;
        gateway.push({
          'jsonrpc': '2.0',
          'id': frame['id'],
          'result': {'status': 'ok', 'resolved': 0},
        });
      }
    });
    gateway.client = TuiGatewayClient(
      SavedConnection(
        id: 'audit-connection',
        label: 'Audit',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'audit-placeholder',
        dashboardUrl: 'http://127.0.0.1:${gateway.server.port}',
      ),
      dashboard: AuditDashboard(),
      now: () => gateway.now,
      fanoutInactivityDeadline: const Duration(seconds: 5),
    );
    gateway.subscription = gateway.client.events.listen(
      gateway.events.add,
      onError: (Object _) {},
    );
    addTearDown(() async {
      await gateway.subscription.cancel();
      await gateway.client.close();
      await gateway.server.close(force: true);
    });
    await gateway.client.connect();
    gateway.event('message.start', 1, {});
    await waitFor(() => gateway.events.any((e) => e.type == 'message.start'));
    gateway.event('message.delta', 3, {'text': 'snapshot text'});
    return gateway;
  }

  void push(Map<String, dynamic> frame) => socket.add(jsonEncode(frame));
  void event(String type, int seq, Map<String, dynamic> payload) => push({
    'jsonrpc': '2.0',
    'method': 'event',
    'params': {
      'type': type,
      'session_id': 'audit-runtime',
      'seq': seq,
      'payload': payload,
    },
  });
  void request(
    String id,
    String method, [
    Map<String, dynamic> params = const {},
  ]) => push({
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': {'session_id': 'audit-runtime', ...params},
  });
  Future<void> barrier() async {
    request('srq-auditbarrier', 'clarify');
    await waitFor(
      () => events.any((e) => e.payload['request_id'] == 'srq-auditbarrier'),
    );
  }

  void adopt() => expect(
    client.adoptViewerSnapshotBoundary(
      runtimeSessionId: 'audit-runtime',
      baseline: 3,
      replayEpoch: 'audit-epoch',
    ),
    isTrue,
  );
}

void main() {
  test(
    'recovered approval preserves business ID and removes cancellation mappings',
    () async {
      final gateway = await _Gateway.start();
      gateway.request('srq-auditapproval', 'approval', {
        'request_id': 'apr-audit',
        'command': 'synthetic',
      });
      gateway.event('request.cancel', 4, {
        'id': 'srq-auditapproval',
        'method': 'approval',
        'reason': 'timeout',
      });
      await gateway.barrier();
      gateway.adopt();
      await waitFor(() => gateway.events.any((e) => e.sequence == 4));
      final event = gateway.events.singleWhere((e) => e.sequence == 4);
      expect(event.type, 'approval.responded');
      expect(event.payload['request_id'], 'apr-audit');
      final live = gateway.events.first;
      expect(event.transportGeneration, live.transportGeneration);
      expect(identical(event.producerChannel, live.producerChannel), isTrue);
      await gateway.client.resolveApprovalChecked(
        'audit-runtime',
        'deny',
        requestId: 'apr-audit',
      );
      expect(
        gateway.frames.where((f) => f['id'] == 'srq-auditapproval'),
        isEmpty,
      );
      expect(
        gateway.frames.where((f) => f['method'] == 'approval.respond'),
        hasLength(1),
      );
      // A duplicate cancellation must no longer find the business-ID mapping.
      gateway.event('request.cancel', 5, {
        'id': 'srq-auditapproval',
        'method': 'approval',
        'reason': 'timeout',
      });
      await waitFor(() => gateway.events.any((e) => e.sequence == 5));
      expect(
        gateway.events
            .singleWhere((e) => e.sequence == 5)
            .payload['request_id'],
        'srq-auditapproval',
      );
    },
  );

  const cancelledTypes = {
    'sudo': 'sudo.expire',
    'secret': 'secret.expire',
    'terminal.read': 'terminal.read.expire',
    'vault.unlock_prompt': 'vault.unlock.expire',
    'vault.save_login': 'vault.save_login.expire',
    'vault.code': 'vault.code.expire',
  };
  for (final entry in cancelledTypes.entries) {
    test('recovered ${entry.key} uses the normal cancel adapter', () async {
      final gateway = await _Gateway.start();
      gateway.request('srq-auditcancel', entry.key);
      gateway.event('request.cancel', 4, {
        'id': 'srq-auditcancel',
        'method': entry.key,
        'reason': 'timeout',
      });
      await gateway.barrier();
      gateway.adopt();
      await waitFor(() => gateway.events.any((e) => e.sequence == 4));
      final event = gateway.events.singleWhere((e) => e.sequence == 4);
      expect(event.type, entry.value);
      expect(event.payload['request_id'], 'srq-auditcancel');
      expect(event.payload['reason'], 'timeout');
    });
  }

  test(
    'recovered terminal ends the busy watchdog before its next probe',
    () async {
      final gateway = await _Gateway.start();
      gateway.event('message.complete', 4, {});
      await gateway.barrier();
      // Recovery arms the runtime before publishing committed held events.
      gateway.client.debugMarkRuntimeBusy('audit-runtime');
      gateway.adopt();
      await waitFor(
        () => gateway.events.any((e) => e.type == 'message.complete'),
      );
      gateway.now = gateway.now.add(const Duration(seconds: 6));
      await gateway.client.debugProbeSilentFanout();
      expect(
        gateway.frames.where((f) => f['method'] == 'session.events.since'),
        isEmpty,
      );
      // Positive control: the same watchdog still probes a new busy turn.
      gateway.client.debugMarkRuntimeBusy('audit-runtime');
      gateway.now = gateway.now.add(const Duration(seconds: 6));
      await gateway.client.debugProbeSilentFanout();
      expect(
        gateway.frames.where((f) => f['method'] == 'session.events.since'),
        hasLength(1),
      );
    },
  );
}
