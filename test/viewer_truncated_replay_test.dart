import 'dart:async';

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
    return true;
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
    'viewer applies the truncated-replay snapshot and adopts its boundary',
    () async {
      final gateway = _TruncatedReplayGateway()
        ..recoverySnapshot = _snapshot(
          assistant: 'Hola mundo, esto es la respuesta completa',
          displayKind: 'model_switch',
        );
      final chat = _viewerChat(gateway);
      addTearDown(chat.dispose);
      chat.debugSeedViewerTruncatedTurnForTesting(
        runtimeSessionId: 'runtime-1',
        storedSessionId: 'session-viewer',
        messagesNewestFirst: _viewerRows('Hola mundo'),
      );
      expect(chat.isStreaming, isTrue);

      await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

      expect(gateway.recoveryResumeCalls, ['session-viewer']);
      expect(_liveAssistantText(chat), 'Hola mundo, esto es la respuesta completa');
      final live = chat.messages.firstWhere((row) => row['role'] == 'assistant');
      expect(live['display_kind'], 'model_switch');
      expect(gateway.adoptions, <_Adoption>[
        (runtimeSessionId: 'runtime-1', baseline: 42, epoch: 'e1'),
      ]);
    },
  );

  test('snapshot with a foreign replay epoch is refused and not adopted', () async {
    final gateway = _TruncatedReplayGateway()
      ..currentReplayEpoch = 'e1'
      ..recoverySnapshot = _snapshot(replayEpoch: 'e2');
    final chat = _viewerChat(gateway);
    addTearDown(chat.dispose);
    chat.debugSeedViewerTruncatedTurnForTesting(
      runtimeSessionId: 'runtime-1',
      storedSessionId: 'session-viewer',
      messagesNewestFirst: _viewerRows('Hola mundo'),
    );

    await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

    expect(gateway.recoveryResumeCalls, ['session-viewer']);
    expect(_liveAssistantText(chat), 'Hola mundo');
    expect(gateway.adoptions, isEmpty);
  });

  test('snapshot for another runtime is refused and not adopted', () async {
    final gateway = _TruncatedReplayGateway()
      ..recoverySnapshot = _snapshot(runtimeSessionId: 'runtime-other');
    final chat = _viewerChat(gateway);
    addTearDown(chat.dispose);
    chat.debugSeedViewerTruncatedTurnForTesting(
      runtimeSessionId: 'runtime-1',
      storedSessionId: 'session-viewer',
      messagesNewestFirst: _viewerRows('Hola mundo'),
    );

    await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

    expect(gateway.recoveryResumeCalls, ['session-viewer']);
    expect(_liveAssistantText(chat), 'Hola mundo');
    expect(gateway.adoptions, isEmpty);
  });

  test('diverged snapshot text rejects the whole snapshot', () async {
    var transcriptReads = 0;
    final gateway = _TruncatedReplayGateway()
      ..recoverySnapshot = _snapshot(assistant: 'Adiós, otra respuesta');
    final chat = _viewerChat(
      gateway,
      onTranscriptRead: () => transcriptReads++,
    );
    addTearDown(chat.dispose);
    chat.debugSeedViewerTruncatedTurnForTesting(
      runtimeSessionId: 'runtime-1',
      storedSessionId: 'session-viewer',
      messagesNewestFirst: _viewerRows('Hola mundo'),
    );

    await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

    // Reaching the text fork is what the durable proof allows; the fork itself
    // must then refuse, not truncate or "keep streaming".
    expect(transcriptReads, 1);
    expect(gateway.recoveryResumeCalls, ['session-viewer']);
    expect(_liveAssistantText(chat), 'Hola mundo');
    expect(gateway.adoptions, isEmpty);
  });

  test(
    'legacy snapshot without lastSequence/replayEpoch is refused untouched',
    () async {
      final gateway = _TruncatedReplayGateway()
        ..recoverySnapshot = _snapshot(lastSequence: null, replayEpoch: null);
      final chat = _viewerChat(gateway);
      addTearDown(chat.dispose);
      chat.debugSeedViewerTruncatedTurnForTesting(
        runtimeSessionId: 'runtime-1',
        storedSessionId: 'session-viewer',
        messagesNewestFirst: _viewerRows('Hola mundo'),
      );

      await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

      expect(gateway.recoveryResumeCalls, ['session-viewer']);
      expect(_liveAssistantText(chat), 'Hola mundo');
      expect(gateway.adoptions, isEmpty);
    },
  );

  test(
    'truncated notification for another runtime never reads the snapshot',
    () async {
      final gateway = _TruncatedReplayGateway()..recoverySnapshot = _snapshot();
      final chat = _viewerChat(gateway);
      addTearDown(chat.dispose);
      chat.debugSeedViewerTruncatedTurnForTesting(
        runtimeSessionId: 'runtime-1',
        storedSessionId: 'session-viewer',
        messagesNewestFirst: _viewerRows('Hola mundo'),
      );

      chat.debugNotifyTruncatedReplay('runtime-other', 'e1');
      await Future<void>.delayed(Duration.zero);

      expect(gateway.recoveryResumeCalls, isEmpty);
      expect(gateway.adoptions, isEmpty);
      expect(_liveAssistantText(chat), 'Hola mundo');
    },
  );

  test(
    'a closed turn with the same prompt is never overwritten (consecutive '
    'turns)',
    () async {
      final gateway = _TruncatedReplayGateway()
        ..recoverySnapshot = _snapshot(
          assistant: 'Hola mundo, respuesta del turno B en curso',
        );
      final chat = _viewerChat(
        gateway,
        // Turn A already finished during the cut: its final answer carries a
        // durable id after the same prompt the inflight describes.
        durableTranscript: const [
          {'role': 'user', 'content': 'hola'},
          {
            'message_id': 'turn-a-final',
            'role': 'assistant',
            'content': 'Hola mundo, respuesta del turno A',
          },
        ],
      );
      addTearDown(chat.dispose);
      chat.debugSeedViewerTruncatedTurnForTesting(
        runtimeSessionId: 'runtime-1',
        storedSessionId: 'session-viewer',
        messagesNewestFirst: _viewerRows('Hola mundo'),
      );

      await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

      expect(gateway.recoveryResumeCalls, ['session-viewer']);
      expect(_liveAssistantText(chat), 'Hola mundo');
      expect(gateway.adoptions, isEmpty);
    },
  );

  test(
    'two durable turns with the same prompt are ambiguous and refused',
    () async {
      final gateway = _TruncatedReplayGateway()
        ..recoverySnapshot = _snapshot(
          assistant: 'Hola mundo, respuesta del turno B en curso',
        );
      final chat = _viewerChat(
        gateway,
        // Turn A closed during the cut and turn B reused the same prompt: the
        // inflight cannot be attributed to either one by its text.
        durableTranscript: const [
          {'role': 'user', 'content': 'hola'},
          {
            'message_id': 'turn-a-final',
            'role': 'assistant',
            'content': 'Hola mundo, respuesta del turno A',
          },
          {'role': 'user', 'content': 'hola'},
        ],
      );
      addTearDown(chat.dispose);
      chat.debugSeedViewerTruncatedTurnForTesting(
        runtimeSessionId: 'runtime-1',
        storedSessionId: 'session-viewer',
        messagesNewestFirst: _viewerRows('Hola mundo'),
      );

      await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

      expect(gateway.recoveryResumeCalls, ['session-viewer']);
      expect(_liveAssistantText(chat), 'Hola mundo');
      expect(gateway.adoptions, isEmpty);
    },
  );

  test('the snapshot keeps the live row activity trace', () async {
    final gateway = _TruncatedReplayGateway()
      ..recoverySnapshot = _snapshot(assistant: 'Hola mundo completo');
    final chat = _viewerChat(gateway);
    addTearDown(chat.dispose);
    chat.debugSeedViewerTruncatedTurnForTesting(
      runtimeSessionId: 'runtime-1',
      storedSessionId: 'session-viewer',
      messagesNewestFirst: [
        {
          'role': 'assistant',
          'content': 'Hola mundo',
          '_activity_trace': [
            {'kind': 'tool', 'label': 'read_file', 'id': 'call-1'},
          ],
        },
        {'role': 'user', 'content': 'hola'},
      ],
    );

    await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

    final live = chat.messages.firstWhere((row) => row['role'] == 'assistant');
    expect(live['content'], 'Hola mundo completo');
    expect(live['_activity_trace'], [
      {
        'kind': 'tool',
        'label': 'read_file',
        'status': 'completed',
        'id': 'call-1',
      },
    ]);
    expect(gateway.adoptions, hasLength(1));
  });

  test('the stream buffer restarts from the snapshot text', () async {
    final gateway = _TruncatedReplayGateway()
      ..recoverySnapshot = _snapshot(assistant: 'Hola mundo completo');
    final chat = _viewerChat(gateway);
    addTearDown(chat.dispose);
    chat.debugSeedViewerTruncatedTurnForTesting(
      runtimeSessionId: 'runtime-1',
      storedSessionId: 'session-viewer',
      messagesNewestFirst: _viewerRows('Hola mundo'),
    );

    await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

    // A later delta appends to this buffer; keeping the pre-cut prefix would
    // repaint the row shorter than the snapshot.
    expect(chat.debugAssistantStreamPublicText, 'Hola mundo completo');
    expect(_liveAssistantText(chat), 'Hola mundo completo');
  });

  test('a snapshot of an idle turn is refused and not adopted', () async {
    final gateway = _TruncatedReplayGateway()
      ..recoverySnapshot = _snapshot(running: false);
    final chat = _viewerChat(gateway);
    addTearDown(chat.dispose);
    chat.debugSeedViewerTruncatedTurnForTesting(
      runtimeSessionId: 'runtime-1',
      storedSessionId: 'session-viewer',
      messagesNewestFirst: _viewerRows('Hola mundo'),
    );

    await chat.debugNotifyTruncatedReplayAndWait('runtime-1', 'e1');

    expect(gateway.recoveryResumeCalls, ['session-viewer']);
    expect(_liveAssistantText(chat), 'Hola mundo');
    expect(gateway.adoptions, isEmpty);
  });
}
