import 'dart:async';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';

import 'support/in_memory_compression_restore_storage.dart';

typedef _Adoption = ({String runtimeSessionId, int baseline, String epoch});

/// Desktop gateway double that reproduces the three capabilities Task 3 needs:
/// the transport surface, the replay boundary (epoch + adoption) and the
/// recovery-only resume that returns the authoritative snapshot.
class _TruncatedReplayGateway
    implements
        HermesDesktopGateway,
        HermesDesktopReplaySnapshotGateway,
        HermesDesktopRecoverySessionLifecycleGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();

  /// The snapshot `resumeExistingForRecovery` answers with.
  DesktopSessionSnapshot? recoverySnapshot;
  Object? recoveryError;

  /// Epoch this transport is reading its replay stream on.
  @override
  String currentReplayEpoch = 'e1';

  final coordinator = ReplayCoordinator();
  final newChannel = Object();
  _TruncatedReplayGateway() {
    final oldChannel = Object();
    coordinator.acceptLive(
      const SessionGatewayEvent('message.start', 'runtime-1', 1, {}),
    );
    coordinator.beginReconnect(generation: 1, channel: oldChannel, epoch: 'e1');
    coordinator.acceptLive(
      const SessionGatewayEvent('tool.start', 'runtime-1', 2, {}),
      socketGeneration: 1,
      channel: oldChannel,
      replayEpoch: 'e1',
    );
    coordinator.retireTransport(generation: 1, channel: oldChannel);
  }
  final List<bool> adoptionResults = [];
  final List<String> recoveryResumeCalls = [];
  final List<_Adoption> adoptions = [];
  final List<void Function(String, String)> _truncatedListeners = [];

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
  }) async => throw UnimplementedError('attach flow is not used here');

  @override
  Future<DesktopSessionSnapshot> resumeExistingForRecovery(
    String storedSessionId, {
    String profile = '',
  }) async {
    recoveryResumeCalls.add(storedSessionId);
    final error = recoveryError;
    if (error != null) throw error;
    final snapshot = recoverySnapshot;
    if (snapshot == null) {
      throw StateError('no recovery snapshot scripted');
    }
    return snapshot;
  }

  @override
  void commitRecoveryRuntime(String runtimeSessionId) {}

  @override
  void addTruncatedReplayListener(
    void Function(String runtimeSessionId, String replayEpoch) listener,
  ) => _truncatedListeners.add(listener);

  @override
  void removeTruncatedReplayListener(
    void Function(String runtimeSessionId, String replayEpoch) listener,
  ) => _truncatedListeners.remove(listener);

  @override
  bool adoptViewerSnapshotBoundary({
    required String runtimeSessionId,
    required int baseline,
    required String replayEpoch,
  }) {
    adoptions.add((
      runtimeSessionId: runtimeSessionId,
      baseline: baseline,
      epoch: replayEpoch,
    ));
    final adopted = coordinator.adoptSnapshotBoundary(
      runtime: runtimeSessionId,
      baseline: baseline,
      socketGeneration: 2,
      channel: newChannel,
      replayEpoch: replayEpoch,
    );
    adoptionResults.add(adopted);
    return adopted;
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {}

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
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }
}

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: id,
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-key',
  kind: InstanceKind.vps,
);

/// Mirrors the real viewer projection: a live, identity-less assistant row on
/// top of the durable prompt it answers (newest first).
List<Map<String, dynamic>> _viewerRows(String liveText) => [
  {'role': 'assistant', 'content': liveText},
  {'role': 'user', 'content': 'hola'},
];

ActiveChat _viewerChat(
  _TruncatedReplayGateway gateway, {
  List<Map<String, dynamic>> durableTranscript = const [
    {'role': 'user', 'content': 'hola'},
  ],
  void Function()? onTranscriptRead,
}) => ActiveChat(
  compressionRestoreStore: testCompressionRestoreStore(),
  connection: _connection('viewer-replay'),
  sessionId: 'session-viewer',
  sessionTitle: 'viewer',
  notifications: null,
  onTerminal: () {},
  api: ApiClient(
    baseUrl: 'http://127.0.0.1:1',
    apiKey: 'test-key',
    httpClient: MockClient((_) async => http.Response('not found', 404)),
  ),
  desktopGateway: gateway,
  allowUnownedDesktopSnapshotForTesting: true,
  storedMessageLoader: (_, _) async {
    onTranscriptRead?.call();
    return durableTranscript;
  },
);

DesktopSessionSnapshot _snapshot({
  String runtimeSessionId = 'runtime-1',
  String storedSessionId = 'session-viewer',
  int? lastSequence = 42,
  String? replayEpoch = 'e1',
  String assistant = 'Hola mundo',
  String? displayKind,
  bool running = true,
  bool withInflight = true,
}) => DesktopSessionSnapshot(
  runtimeSessionId: runtimeSessionId,
  storedSessionId: storedSessionId,
  created: false,
  running: running,
  lastSequence: lastSequence,
  replayEpoch: replayEpoch,
  inflight: withInflight
      ? DesktopInflightTurn(
          assistant: assistant,
          streaming: true,
          displayKind: displayKind,
        )
      : null,
);

String _liveAssistantText(ActiveChat chat) =>
    chat.messages.firstWhere((row) => row['role'] == 'assistant')['content']
        as String;

void main() {
  test(
    'retired viewer keeps snapshot text and converges to durable terminal despite refused live cut',
    () async {
      final gateway = _TruncatedReplayGateway()
        ..recoverySnapshot = _snapshot(assistant: 'Hola mundo completo');
      final durable = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'hola'},
      ];
      final chat = _viewerChat(gateway, durableTranscript: durable);
      addTearDown(chat.dispose);
      chat.debugSeedViewerTruncatedTurnForTesting(
        runtimeSessionId: 'runtime-1',
        storedSessionId: 'session-viewer',
        messagesNewestFirst: _viewerRows('Hola mundo'),
      );
      await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');
      expect(gateway.adoptionResults, [false]);
      expect(_liveAssistantText(chat), 'Hola mundo completo');
      expect(chat.isStreaming, isTrue);
      durable
        ..clear()
        ..addAll([
          {
            'role': 'assistant',
            'content': 'Durable final answer',
            'message_id': 'final-1',
          },
          {'role': 'user', 'content': 'hola', 'message_id': 'user-1'},
        ]);
      await chat.loadMessages(passiveOnly: true, observePassiveActivity: false);
      expect(
        chat.messages.where((row) => row['content'] == 'Durable final answer'),
        hasLength(1),
      );
      await chat.applyAuthoritativeActiveSessionList(
        const DesktopActiveSessionList(),
      );
      await chat.applyAuthoritativeActiveSessionList(
        const DesktopActiveSessionList(),
      );
      expect(chat.isStreaming, isFalse);
      expect(
        chat.messages.where((row) => row['content'] == 'Durable final answer'),
        hasLength(1),
      );
    },
  );
}
