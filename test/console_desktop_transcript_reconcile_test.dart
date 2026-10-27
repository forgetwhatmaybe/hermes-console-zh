// Regression coverage for bidirectional Console↔Desktop transcript
// reconciliation on `sessions.changed`.
//
// Root cause: `sessions.changed` is a session-less broadcast (state.db
// moved; see tui_gateway/contracts/events.py) that Desktop's own
// `useBackgroundSync`/`reconcileActiveTranscript` treats as an unconditional
// trigger to re-read and reconcile the currently OPEN transcript
// (apps/desktop/src/app/contrib/hooks/use-background-sync.ts,
// requestActiveTranscriptRefresh). Console's `_onDesktopEvent` received the
// same event but only ever fanned it into the subagent/process/control
// adaptive snapshot and the session LIST (`session_list_screen.dart`); the
// open transcript itself was never re-read, so a message written by another
// surface (Desktop, another Console instance) while THIS chat stayed open
// sat unseen until an unrelated event happened to trigger a passive read.
//
// These tests exercise `ActiveChatService`/`ChatScreen` directly against a
// fake desktop gateway that emits real `sessions.changed` events and a
// `storedMessageLoader` seam that stands in for the durable REST read, the
// same seam `chat_screen_test.dart` and
// `subagent_process_adaptive_refresh_test.dart` already use.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_active_session.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/session_reconciler.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

/// A minimal desktop gateway: connects, resumes/activates, and lets tests
/// fire real `sessions.changed` (and terminal) events on its event stream.
class _ReconcileGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionActivityGateway {
  _ReconcileGateway({this.changeEventsAvailable = true});

  final bool changeEventsAvailable;
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  String runtimeId = 'runtime-reconcile';
  bool connected = true;
  DesktopActiveSessionList activeSessionList = const DesktopActiveSessionList();

  /// When set, `resumeExisting`/`activateSession` return this stored id
  /// instead of echoing back the requested one — the real
  /// provisional-mob-*-to-durable promotion `session.resume` performs.
  String? promotedStoredSessionId;

  /// The ActiveChat's `logicalSessionId`, needed so a genuine promotion's
  /// snapshot can advertise a matching `lineageRootId` (see `resumeExisting`).
  String logicalRootId = '';

  void emit(String type, [Map<String, dynamic> payload = const {}]) {
    _events.add(
      TuiGatewayEvent(type: type, sessionId: runtimeId, payload: payload),
    );
  }

  /// The subscription the chat holds on [events] reports a socket-level loss
  /// (ws 1006): the real reconnect cycle starts from this edge.
  void emitError(Object error) => _events.addError(error);

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: runtimeId,
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: runtimeId,
    storedSessionId: promotedStoredSessionId ?? storedSessionId,
    storedSessionIdProvenance: promotedStoredSessionId != null
        ? DesktopStoredSessionIdProvenance.resumed
        : DesktopStoredSessionIdProvenance.storedSessionId,
    // A real `session.resume` promotion advertises the caller's logical
    // root alongside the new durable id, which is exactly what
    // `DesktopCompressionAcquisitionReceipt.tryCreate`'s
    // `remoteAdvertisedRoot` provenance checks against
    // (`authority.expectedRootId` == the ActiveChat's `logicalSessionId`).
    // Without this, a genuine (non-testing-bypass) promotion has no way to
    // authorize itself: `storedSessionIdentityExplicit` alone only covers
    // the exact-match case, which by definition never holds for a
    // provisional -> durable promotion.
    lineageRootId: promotedStoredSessionId != null ? logicalRootId : null,
    created: false,
    running: false,
    status: 'idle',
  );

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: runtimeId,
    storedSessionId: 'stored-reconcile',
    created: true,
  );

  @override
  DesktopGatewayCapabilityState capabilityState(
    DesktopGatewayCapability capability,
  ) => DesktopGatewayCapabilityState.supported;

  @override
  Future<DesktopSessionSnapshot> activateSession(
    String runtimeSessionId, {
    required String storedSessionId,
  }) async => DesktopSessionSnapshot(
    runtimeSessionId: runtimeId,
    storedSessionId: storedSessionId,
    created: false,
    running: false,
    status: 'idle',
  );

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => activeSessionList;

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
    connected = false;
    if (!_events.isClosed) await _events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _connection = SavedConnection(
  id: 'reconcile-conn',
  label: 'Transcript reconcile',
  host: 'example.invalid',
  port: 443,
  apiKey: 'unused',
  useHttps: true,
  kind: InstanceKind.vps,
);

const _session = Session(
  id: 'stored-reconcile',
  title: 'Transcript reconcile',
  model: 'hermes-agent',
  source: 'mobile',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 0,
);

class _Fixture {
  const _Fixture({
    required this.gateway,
    required this.chat,
    required this.activeChats,
  });

  final _ReconcileGateway gateway;
  final ActiveChat chat;
  final ActiveChatService activeChats;
}

Future<_Fixture> _mountChat(
  WidgetTester tester, {
  bool changeEventsAvailable = true,
  StoredSessionMessageLoader? storedMessageLoader,
  String initialStoredSessionId = 'stored-reconcile',
  String? promotedStoredSessionId,
}) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final gateway =
      _ReconcileGateway(changeEventsAvailable: changeEventsAvailable)
        ..promotedStoredSessionId = promotedStoredSessionId
        ..logicalRootId = _session.id;
  final activeChats = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = activeChats.attach(
    connection: _connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    initialStoredSessionId: initialStoredSessionId,
    api: ApiClient(
      baseUrl: 'https://example.invalid',
      apiKey: 'unused',
      httpClient: MockClient((_) async => http.Response('unused', 500)),
    ),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: false,
    // Not `allowUnownedDesktopSnapshotForTesting`: the fake gateway always
    // returns an explicit, identity-consistent snapshot (see
    // `_ReconcileGateway.resumeExisting`/`activateSession`), so the real
    // acquisition path authorizes it without the testing bypass. Setting the
    // bypass here self-conflicts: it taints the receipt's destination state
    // (`testingTainted=true`) built from the reservation snapshotted BEFORE
    // the taint was known, so the post-adoption re-check of
    // `acquisitionStillAuthorized()` (which compares against the *current*,
    // now-tainted, `_desktopCompressionAuthorityState`) spuriously fails and
    // `_acquireDesktopRuntime` returns `null`, i.e. `ensureDesktopRuntime`
    // reports `false` even though the gateway resumed the session cleanly.
    storedMessageLoader: storedMessageLoader,
    disableForegroundKeepAlive: true,
  );
  chat.messagesLoaded = true;
  expect(
    await chat.ensureDesktopRuntime(acquireForExplicitAction: true),
    isTrue,
  );
  await tester.pump();

  await tester.pumpWidget(
    HermesApp(
      connManager: manager,
      appLock: AppLockService(prefs),
      approvalPolicy: ApprovalPolicyService(prefs),
      fontSize: FontSizeService(prefs),

      sshManager: SshManager(secure, manager),
      sftpTransfers: SftpTransferService(
        SshManager(secure, manager),
        NotificationService(prefs),
      ),
      sshSessions: SshSessionService(SshManager(secure, manager)),
      notifications: NotificationService(prefs),
      activeChats: activeChats,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 500));
  final context = tester.element(find.byType(Navigator).first);
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => ChatScreen(
        connection: _connection,
        session: _session,
        // A real navigation always carries the CURRENT stored id, never a
        // stale pre-promotion one: by the time a screen mounts, any earlier
        // `ensureDesktopRuntime()` (as done above) has already updated
        // `chat.serverSessionId`. Reusing the original `initialStoredSessionId`
        // here would make `ActiveChatService.attach`'s
        // `bindKnownStoredSession` see a mismatch against the already-durable
        // id, fail, and — since ChatScreen's `attach()` call never passes a
        // `desktopGateway:` override — dispose this fixture's chat/gateway
        // and silently replace it with a real `TuiGatewayClient`, which then
        // tries to reach a live Dashboard and closes the fake gateway from
        // under the test.
        initialStoredSessionId: chat.serverSessionId,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return _Fixture(gateway: gateway, chat: chat, activeChats: activeChats);
}

Future<void> _disposeFixture(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  fixture.activeChats.dispose();
  await fixture.gateway.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final secure = <String, String>{};
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = (call.arguments as Map?) ?? {};
            switch (call.method) {
              case 'read':
                return secure[args['key']];
              case 'write':
                secure[args['key'] as String] = args['value'] as String;
              case 'delete':
                secure.remove(args['key']);
              case 'readAll':
                return Map<String, String>.from(secure);
              case 'containsKey':
                return secure.containsKey(args['key']);
            }
            return null;
          },
        );
    for (final name in [
      'dexterous.com/flutter/local_notifications',
      'flutter_foreground_task/background',
    ]) {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async => call.method == 'isRunningService' ? false : null,
        );
  });

  // (a) another surface (Desktop) sends while Console has the same session open.
  testWidgets(
    'sessions.changed while idle pulls in a message written by another surface',
    (tester) async {
      var loads = 0;
      const remoteReply = [
        {'role': 'assistant', 'content': 'Reply sent from Desktop'},
        {'role': 'user', 'content': 'Question sent from Desktop'},
      ];
      final fixture = await _mountChat(
        tester,
        storedMessageLoader: (_, _) async {
          loads += 1;
          return remoteReply;
        },
      );
      expect(loads, 0);

      fixture.gateway.emit('sessions.changed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        loads,
        greaterThan(0),
        reason:
            'sessions.changed must trigger a durable transcript re-read for '
            'the OPEN chat, not only the session list/roster.',
      );
      expect(
        find.text('Reply sent from Desktop'),
        findsOneWidget,
        reason:
            'the message from the other surface must reach the visible transcript',
      );

      await _disposeFixture(tester, fixture);
    },
  );

  // (b) Console is mid-stream when the other surface's message arrives.
  testWidgets(
    'sessions.changed mid-stream defers the durable read instead of clobbering the live turn',
    (tester) async {
      var loads = 0;
      final fixture = await _mountChat(
        tester,
        storedMessageLoader: (_, _) async {
          loads += 1;
          return const [
            {'role': 'assistant', 'content': 'Should not appear yet'},
          ];
        },
      );
      expect(
        await fixture.chat.send(
          fullText: 'question sent from console',
          model: 'hermes-agent',
          history: const [],
        ),
        isTrue,
      );
      fixture.gateway.emit('message.start');
      await tester.pump();
      expect(fixture.chat.isStreaming, isTrue);

      fixture.gateway.emit('sessions.changed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.text('Should not appear yet'),
        findsNothing,
        reason:
            'a durable read while streaming would clobber the in-flight '
            'partial with a stale REST snapshot',
      );

      fixture.gateway.emit('message.complete', const {'text': 'Live answer'});
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(
        loads,
        greaterThan(0),
        reason:
            'once the turn settles, the deferred sessions.changed signal '
            'must still land a reconciliation read',
      );

      await _disposeFixture(tester, fixture);
    },
  );

  // (c) a reconnect/network blip happens during reconciliation.
  testWidgets(
    'a failed reconciliation read after a disconnect is retried, not dropped',
    (tester) async {
      var attempt = 0;
      final fixture = await _mountChat(
        tester,
        storedMessageLoader: (_, _) async {
          attempt += 1;
          if (attempt <= 2) {
            throw StateError('network blip');
          }
          return const [
            {'role': 'assistant', 'content': 'Reply survives the blip'},
          ];
        },
      );

      fixture.gateway.emit('sessions.changed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(attempt, greaterThan(0));
      expect(find.text('Reply survives the blip'), findsNothing);
      final attemptsAfterFirstTick = attempt;

      // The passive reader's own failure backoff (5s floor) retries.
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        attempt,
        greaterThan(attemptsAfterFirstTick),
        reason:
            'a transient read failure must not permanently drop the '
            'pending reconciliation',
      );
      expect(find.text('Reply survives the blip'), findsOneWidget);

      await _disposeFixture(tester, fixture);
    },
  );

  // (d) session id changes from provisional to durable while a message from
  // another surface arrives.
  testWidgets(
    'sessions.changed after a provisional->durable id promotion reconciles the durable transcript',
    (tester) async {
      var loads = 0;
      final requestedIds = <String>[];
      final fixture = await _mountChat(
        tester,
        initialStoredSessionId: 'mob-provisional',
        // `ensureDesktopRuntime` inside `_mountChat` resumes the session and,
        // exactly like a real `session.resume`, the gateway answers with a
        // server-confirmed durable id different from the provisional one —
        // ActiveChat adopts it as `serverSessionId` before this test runs
        // any assertion.
        promotedStoredSessionId: 'durable-after-promotion',
        storedMessageLoader: (sessionId, _) async {
          loads += 1;
          requestedIds.add(sessionId);
          return const [
            {'role': 'assistant', 'content': 'Reply against the durable id'},
          ];
        },
      );

      expect(fixture.chat.serverSessionId, 'durable-after-promotion');

      fixture.gateway.emit('sessions.changed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(loads, greaterThan(0));
      expect(
        requestedIds,
        isNot(contains('mob-provisional')),
        reason:
            'the reconciliation read must target the durable id, never '
            'the stale provisional one, once promotion has happened',
      );
      expect(find.text('Reply against the durable id'), findsOneWidget);

      await _disposeFixture(tester, fixture);
    },
  );

  // ── T2 (plan r3): viewer 流式 durable 对账 + live 行保留 ──────────────────

  group('T2 viewer streaming durable reconciliation', () {
    /// Starts a turn this surface only observes (another surface submitted
    /// it): `_pipeline` live placeholder + a running tool trace, no local
    /// submit. This is the viewer state after a reconnect converged onto a
    /// running remote turn.
    void beginViewerTurn(_Fixture fixture) {
      fixture.chat.beginExternallyObservedDesktopTurnForTesting(
        DesktopSessionSnapshot(
          runtimeSessionId: fixture.gateway.runtimeId,
          storedSessionId: fixture.chat.serverSessionId,
          created: false,
          running: true,
          status: 'working',
        ),
      );
      fixture.gateway.emit(
        'tool.start',
        {'tool_id': 'call-viewer', 'name': 'terminal', 'context': ''},
      );
    }

    testWidgets(
      'T2-1: sessions.changed while a viewer streams still reads durable and '
      'keeps the live placeholder row and its trace',
      (tester) async {
        var loads = 0;
        final fixture = await _mountChat(
          tester,
          storedMessageLoader: (_, _) async {
            loads += 1;
            return const [
              {
                'message_id': 'viewer-remote-final',
                'role': 'assistant',
                'content': 'Remote reply committed mid-watch',
              },
              {
                'message_id': 'viewer-remote-user',
                'role': 'user',
                'content': 'Remote prompt from another surface',
              },
            ];
          },
        );
        beginViewerTurn(fixture);
        await tester.pump();
        expect(fixture.chat.isStreaming, isTrue);
        expect(fixture.chat.clientOwnsLiveTurn, isFalse);
        final liveRow = fixture.chat.messages.firstWhere(
          (message) => message['_pipeline'] == true,
        );
        final traceBefore = liveRow[assistantActivityTraceKey];

        fixture.gateway.emit('sessions.changed');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          loads,
          greaterThan(0),
          reason:
              'a viewer (this surface did not submit the running turn) must '
              'reconcile durable rows while the remote turn streams',
        );
        final messages = fixture.chat.messages;
        expect(
          messages.where((message) => message['_pipeline'] == true),
          hasLength(1),
          reason: 'the live placeholder row must survive the durable read',
        );
        final survivingLive = messages.firstWhere(
          (message) => message['_pipeline'] == true,
        );
        expect(
          survivingLive[assistantActivityTraceKey],
          traceBefore,
          reason: 'the live row keeps its activity trace',
        );
        final liveIndex = messages.indexOf(survivingLive);
        expect(liveIndex, 0, reason: 'new durable rows land below the live row');
        expect(
          messages
              .where((message) => message['content'] == 'Remote reply committed mid-watch'),
          hasLength(1),
          reason: 'no duplicate bubbles for the durable row',
        );

        await _disposeFixture(tester, fixture);
      },
    );

    testWidgets(
      'T2-2: an own submitted live turn stays excluded, and converges after done',
      (tester) async {
        var loads = 0;
        final fixture = await _mountChat(
          tester,
          storedMessageLoader: (_, _) async {
            loads += 1;
            return const [
              {'role': 'assistant', 'content': 'Should not appear mid-stream'},
            ];
          },
        );
        expect(
          await fixture.chat.send(
            fullText: 'own submitted turn',
            model: 'hermes-agent',
            history: const [],
          ),
          isTrue,
        );
        fixture.gateway.emit('message.start');
        await tester.pump();
        expect(fixture.chat.isStreaming, isTrue);
        expect(fixture.chat.clientOwnsLiveTurn, isTrue);

        final loadsWhileStreaming = loads;
        fixture.gateway.emit('sessions.changed');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          loads,
          loadsWhileStreaming,
          reason:
              'a turn this client submitted keeps excluding passive durable '
              'reads (they would paint a duplicate prompt/reply pair)',
        );

        fixture.gateway.emit(
          'message.complete',
          const {'text': 'Own final answer'},
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(
          loads,
          greaterThan(loadsWhileStreaming),
          reason: 'once the turn settles, the deferred read must land',
        );

        await _disposeFixture(tester, fixture);
      },
    );

    testWidgets(
      'T2-3: a viewer read that outlives a turn epoch change is dropped',
      (tester) async {
        final readGate = Completer<List<Map<String, dynamic>>>();
        var loads = 0;
        final fixture = await _mountChat(
          tester,
          storedMessageLoader: (_, _) async {
            loads += 1;
            if (loads == 1) {
              return const [
                {
                  'message_id': 'viewer-turn-a-final',
                  'role': 'assistant',
                  'content': 'Stale reply of turn A',
                },
              ];
            }
            return readGate.future;
          },
        );
        beginViewerTurn(fixture);
        await tester.pump();
        fixture.gateway.emit('sessions.changed');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(loads, greaterThan(0));

        // The read for the second tick is still in flight when the turn
        // changes: a successor viewer turn begins (new epoch, new rows).
        fixture.gateway.emit('sessions.changed');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(loads, greaterThan(1));
        beginViewerTurn(fixture);
        await tester.pump();
        final messagesBeforeLanding = List<Map<String, dynamic>>.from(
          fixture.chat.messages,
        );
        readGate.complete(const [
          {
            'message_id': 'viewer-turn-a-final',
            'role': 'assistant',
            'content': 'Stale reply of turn A',
          },
        ]);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          fixture.chat.messages.length,
          messagesBeforeLanding.length,
          reason: 'the stale read must not grow the new turn\'s projection',
        );

        await _disposeFixture(tester, fixture);
      },
    );
  });
}
