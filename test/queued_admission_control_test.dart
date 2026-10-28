import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/rpc_frame_helpers.dart';

class _TicketDashboardClient extends DashboardClient {
  _TicketDashboardClient()
    : super(host: '127.0.0.1', port: 1, manualToken: 'unused');

  @override
  Future<DashboardWebSocketAuth> webSocketAuth() async =>
      const DashboardWebSocketAuth(
        queryName: 'ticket',
        credential: 'queued-admission-ticket',
      );
}

/// A real loopback gateway that records every JSON-RPC frame it receives.
///
/// The client is exercised over a real socket on purpose: the point of these
/// tests is the wire shape the server validates, which a mocked channel would
/// let us fake.
class _Gateway {
  _Gateway._(this.client, this.requests);

  final TuiGatewayClient client;
  final List<Map<String, dynamic>> requests;

  static Future<_Gateway> start({
    required Map<String, dynamic> Function() onPromptSubmit,
  }) async {
    final requests = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'event',
          'params': {'type': 'gateway.ready', 'payload': <String, dynamic>{}},
        }),
      );
      await for (final raw in socket) {
        final frame = jsonDecode(raw as String) as Map<String, dynamic>;
        if (isClientCapabilitiesFrame(frame)) continue;
        requests.add(frame);
        final result = switch (frame['method'] as String) {
          'gateway.capabilities' => {'per_session_exclusive_submit': true},
          'prompt.submit' => onPromptSubmit(),
          // AdmissionStatus, the reply both queued-control methods answer with.
          _ => {'admission_id': 'adm-current', 'state': 'queued'},
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }
    });
    final client = TuiGatewayClient(
      SavedConnection(
        id: 'queued-admission-control',
        label: 'Queued admission control',
        host: '127.0.0.1',
        port: 8642,
        apiKey: 'unused',
        dashboardUrl: 'http://127.0.0.1:${server.port}',
      ),
      dashboard: _TicketDashboardClient(),
    );
    addTearDown(() async {
      await client.close();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    return _Gateway._(client, requests);
  }

  /// The frame that carried [method], which must have been sent exactly once.
  Map<String, dynamic> paramsFor(String method) {
    final frames = requests.where((frame) => frame['method'] == method);
    expect(frames, hasLength(1), reason: 'expected one $method frame');
    return Map<String, dynamic>.from(frames.single['params'] as Map);
  }
}

void main() {
  test('a queued submit hands back the admission_id it was admitted with', () async {
    final gateway = await _Gateway.start(
      onPromptSubmit: () => {
        'status': 'queued',
        'admission_id': 'adm-42',
        'forwarded': true,
      },
    );
    await gateway.client.connect();

    final admissionId = await gateway.client.submitQueuedPrompt('rt', 'later');

    expect(admissionId, 'adm-42');
    expect(gateway.paramsFor('prompt.submit'), {
      'session_id': 'rt',
      'text': 'later',
      'queued': true,
    });
  });

  test('a queued reply without a usable admission_id answers null, not an error', () async {
    // Every shape a server can legitimately answer: the key absent (non-FIFO),
    // null, a non-string, and an empty string. None of them is a failed send.
    final replies = <Map<String, dynamic>>[
      {'status': 'queued'},
      {'status': 'queued', 'admission_id': null},
      {'status': 'queued', 'admission_id': 42},
      {'status': 'queued', 'admission_id': ''},
    ];
    final gateway = await _Gateway.start(
      onPromptSubmit: () => replies.removeAt(0),
    );
    await gateway.client.connect();

    for (var index = 0; index < 4; index++) {
      await expectLater(
        gateway.client.submitQueuedPrompt('rt', 'later-$index'),
        completion(isNull),
      );
    }
    expect(replies, isEmpty);
  });

  test('prompt.steer_queued sends exactly the contract params', () async {
    final gateway = await _Gateway.start(
      onPromptSubmit: () => const <String, dynamic>{},
    );
    await gateway.client.connect();

    final status = await gateway.client.steerQueuedPrompt('rt', 'adm-7');

    expect(status['admission_id'], 'adm-current');
    final params = gateway.paramsFor('prompt.steer_queued');
    // Key set, not just values: an extra key or a renamed one is a server-side
    // validation failure, and the contract names only these two.
    expect(params.keys.toSet(), {'session_id', 'admission_id'});
    expect(params, {'session_id': 'rt', 'admission_id': 'adm-7'});
    // Steer is not a submit: it must never ride the exclusive submit channel.
    expect(
      gateway.requests.map((frame) => frame['method']),
      isNot(contains('prompt.submit')),
    );
  });

  test('prompt.replace_queued sends exactly the contract params', () async {
    final gateway = await _Gateway.start(
      onPromptSubmit: () => const <String, dynamic>{},
    );
    await gateway.client.connect();

    await gateway.client.replaceQueuedPrompt(
      'rt',
      admissionId: 'adm-7',
      submissionId: 'sub-9',
      text: 'edited text',
    );

    final params = gateway.paramsFor('prompt.replace_queued');
    expect(params.keys.toSet(), {
      'session_id',
      'admission_id',
      'submission_id',
      'text',
    });
    expect(params, {
      'session_id': 'rt',
      'admission_id': 'adm-7',
      'submission_id': 'sub-9',
      'text': 'edited text',
    });
    expect(
      gateway.requests.map((frame) => frame['method']),
      isNot(contains('prompt.submit')),
    );
  });
}
