// Task 1 (resync-after-reconnect): a transport recovery edge must force one
// FULL durable transcript read.
//
// Field symptom: after a ws 1006 cut, rows committed while the socket was down
// did not come back until the next 10 s passive gap, a `sessions.changed`
// tick or a manual pull-to-refresh. The passive reader was armed and healthy,
// but its cheap one-row tail probe answered `unchanged` (the last published
// page was still the newest durable row it had seen) and the read was
// short-circuited — nothing distinguished "the store did not move" from "we
// were not listening for a while".
//
// Contract under test (plan `plan-resync-after-reconnect.md`, Task 1):
//   * `ChatTransportVisibility.recoveries` (a shown loss that cleared) bumps a
//     recovery epoch on the chat;
//   * the passive read triggered by that edge skips the tail probe and is a
//     full page read, even when the probe would have said `unchanged`;
//   * the pending flag survives a failed read, a read that started before the
//     edge and a second edge that lands while a read is in flight, so the
//     convergence is never silently lost.
//
// These run the real ChatScreen passive reader against a fake HTTP transcript
// that counts probe (limit=1) vs. full-page reads, and drive a real
// socket-level loss/recovery through the fake gateway plus the connection
// status registry (the supervisor's `link`), which is what makes the loss
// visible after the 3 s active grace instead of the 5 min idle one.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:hermes_android/core/services/connection_status.dart';
import 'package:hermes_android/core/services/desktop_gateway_capabilities.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/in_memory_compression_restore_storage.dart';

const _storedId = 'stored-recovery-read';
const _rowCount = 20;

/// `/api/sessions/{id}/messages` with the same paging shape as the real
/// gateway: integer row ids, `order=latest` offsets counted back from the
/// newest row. Counts one-row tail probes apart from real page reads, and can
/// hold a response (in-flight window) or fail transiently.
final class _TranscriptServer {
  _TranscriptServer() {
    for (var i = 1; i <= _rowCount; i++) {
      append(i.isOdd ? 'user' : 'assistant');
    }
  }

  Duration latency = Duration.zero;
  bool failMessages = false;
  final List<Map<String, Object?>> _rows = [];
  final requests = <Uri>[];

  /// Reads that download a real page, as opposed to the one-row tail probe.
  int get heavyReads => requests
      .where(
        (uri) =>
            uri.path.endsWith('/messages') &&
            uri.queryParameters['limit'] != '1',
      )
      .length;

  int get probeReads => requests
      .where(
        (uri) =>
            uri.path.endsWith('/messages') &&
            uri.queryParameters['limit'] == '1',
      )
      .length;

  int get messageReads =>
      requests.where((uri) => uri.path.endsWith('/messages')).length;

  /// Read shapes since request index [from], in send order: `probe` is the
  /// one-row tail probe, `page` a full durable page read.
  List<String> readShapesSince(int from) => [
    for (final uri in requests.skip(from))
      if (uri.path.endsWith('/messages'))
        uri.queryParameters['limit'] == '1' ? 'probe' : 'page',
  ];

  /// In-place rewrite of the newest row (same durable id), as an edit of the
  /// tip or a display projection change would produce.
  void rewriteNewest(String content) {
    _rows.last = {..._rows.last, 'content': content};
  }

  void append(String role, {String? content}) {
    final id = _rows.length + 1;
    _rows.add({
      'id': id,
      'session_id': _storedId,
      'role': role,
      'content': content ?? '$role $id',
      'timestamp': 1790000000 + id,
    });
  }

  /// The newest durable rows, as of now. A read snapshots this BEFORE its
  /// latency: a row appended while a read is in flight cannot leak into it.
  List<Map<String, Object?>> _snapshotLatest(int limit) {
    final start = (_rows.length - limit).clamp(0, _rows.length);
    return _rows.sublist(start, _rows.length);
  }

  http.Client client() => MockClient((request) async {
    requests.add(request.url);
    final path = request.url.path;
    if (path != '/api/sessions/$_storedId/messages') {
      return http.Response('{"error":"not found"}', 404);
    }
    final query = request.url.queryParameters;
    final limit = int.parse(query['limit'] ?? '500').clamp(1, 500);
    final offset = int.parse(query['offset'] ?? '0');
    final page = _snapshotLatest(_rows.length - offset).length > limit
        ? _snapshotLatest(
            _rows.length - offset,
          ).sublist(_snapshotLatest(_rows.length - offset).length - limit)
        : _snapshotLatest(_rows.length - offset);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failMessages) {
      return http.Response('{"error":"unavailable"}', 500);
    }
    final body = jsonEncode({
      'object': 'list',
      'session_id': _storedId,
      'data': page,
      'pagination': {
        'limit': limit,
        'offset': offset,
        'order': 'latest',
        'returned': page.length,
      },
    });
    return http.Response(body, 200);
  });
}

class _RecoveryGateway
    implements
        HermesDesktopGateway,
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopSessionActivityGateway {
  final StreamController<TuiGatewayEvent> _events =
      StreamController<TuiGatewayEvent>.broadcast();
  final bool changeEventsAvailable = true;
  bool connected = true;

  /// While down, redials fail like a socket that cannot be reached.
  bool down = false;

  void emit(String type, {Map<String, dynamic> payload = const {}}) =>
      _events.add(
        TuiGatewayEvent(
          type: type,
          sessionId: 'runtime-recovery',
          payload: payload,
        ),
      );

  /// A real ws-level cut (1006): the events subscription reports the loss.
  void dropSocket() {
    connected = false;
    _events.addError(const SocketException('Connection reset by peer'));
  }

  void restoreSocket() {
    down = false;
    connected = true;
  }

  @override
  Stream<TuiGatewayEvent> get events => _events.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect() async {
    if (down) throw const SocketException('Connection reset by peer');
    connected = true;
  }

  @override
  Future<DesktopSessionBinding> resumeSession(
    String storedSessionId, {
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => DesktopSessionBinding(
    runtimeSessionId: 'runtime-recovery',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    if (down) throw const SocketException('Connection reset by peer');
    return DesktopSessionSnapshot(
      runtimeSessionId: 'runtime-recovery',
      storedSessionId: storedSessionId,
      created: false,
      running: false,
      status: 'idle',
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) async => const DesktopSessionSnapshot(
    runtimeSessionId: 'runtime-recovery',
    storedSessionId: _storedId,
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
    runtimeSessionId: runtimeSessionId,
    storedSessionId: storedSessionId,
    created: false,
    running: false,
    status: 'idle',
  );

  @override
  Future<DesktopActiveSessionList> listActiveSessions({
    String currentRuntimeSessionId = '',
  }) async => const DesktopActiveSessionList();

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

/// The connection supervisor's view of this connection's socket: what makes
/// an idle chat's loss visible after the 3 s active grace (a `link` that knows
/// the socket is down) instead of the 5 min idle one.
class _SupervisorLink implements ConnectionLinkSource {
  final ChangeNotifier _notifier = ChangeNotifier();
  bool _connected = true;
  DateTime? _reconnectAt;
  bool _closed = false;

  @override
  Listenable get linkListenable => _notifier;

  @override
  bool get isConnected => _connected;

  @override
  bool get isClosed => _closed;

  @override
  bool get linkAuthRejected => false;

  @override
  DateTime? get linkReconnectAt => _reconnectAt;

  @override
  int get linkReconnectAttempt => _reconnectAt == null ? 0 : 1;

  @override
  bool get linkParked => false;

  void markDown() {
    _connected = false;
    _reconnectAt = DateTime.now();
    _notifier.notifyListeners();
  }

  void markUp() {
    _connected = true;
    _reconnectAt = null;
    _notifier.notifyListeners();
  }

  void close() {
    _closed = true;
    _notifier.notifyListeners();
  }
}

final _connection = SavedConnection(
  id: 'recovery-read-conn',
  label: 'Recovery read',
  host: '127.0.0.1',
  port: 8642,
  apiKey: 'test-api-key',
  kind: InstanceKind.vps,
);

const _session = Session(
  id: _storedId,
  title: 'Recovery read',
  model: 'hermes-agent',
  source: 'desktop',
  messageCount: _rowCount,
  isActive: true,
  preview: '',
  startedAt: 0,
);

class _Fixture {
  _Fixture(this.chat, this.gateway, this.link, this.activeChats);
  final ActiveChat chat;
  final _RecoveryGateway gateway;
  final _SupervisorLink link;
  final ActiveChatService activeChats;
}

Future<_Fixture> _mount(WidgetTester tester, _TranscriptServer server) async {
  final prefs = await SharedPreferences.getInstance();
  final manager = await ConnectionManager.create(prefs);
  final secure = SecureStorage();
  final gateway = _RecoveryGateway();
  final link = _SupervisorLink();
  ConnectionStatusRegistry.instance.bind(_connection.id, link);
  final activeChats = ActiveChatService(
    attachDesktopRuntimeOnLoad: false,
    compressionRestoreStore: testCompressionRestoreStore(),
  );
  final chat = activeChats.attach(
    connection: _connection,
    sessionId: _session.id,
    sessionTitle: _session.title,
    sessionSnapshot: _session,
    initialStoredSessionId: _storedId,
    api: ApiClient(
      baseUrl: 'http://127.0.0.1:8642',
      apiKey: 'test-api-key',
      httpClient: server.client(),
    ),
    desktopGateway: gateway,
    attachDesktopRuntimeOnLoad: false,
    disableForegroundKeepAlive: true,
  );
  await chat.loadMessages(expectedMessageCount: _rowCount);
  final attached = await chat.ensureDesktopRuntime(
    acquireForExplicitAction: true,
  );
  expect(attached, isTrue);
  expect(chat.desktopRuntimeSessionId, 'runtime-recovery');
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
        initialStoredSessionId: chat.serverSessionId,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(identical(activeChats.of(_connection.id, _session.id), chat), isTrue);
  return _Fixture(chat, gateway, link, activeChats);
}

Future<void> _dispose(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  fixture.activeChats.dispose();
  await fixture.gateway.close();
  fixture.link.close();
}

Future<void> _idle(WidgetTester tester, Duration total) async {
  const step = Duration(seconds: 1);
  for (var elapsed = Duration.zero; elapsed < total; elapsed += step) {
    await tester.pump(step);
  }
}

/// A visible loss (longer than the 3 s active grace, since the supervisor says
/// the socket is down) followed by a healthy link (2 s hysteresis).
Future<void> _cutAndRecover(
  WidgetTester tester,
  _Fixture fixture, {
  Duration outage = const Duration(seconds: 5),
  Duration healthy = const Duration(seconds: 3),
}) async {
  fixture.gateway.down = true;
  fixture.gateway.dropSocket();
  fixture.link.markDown();
  await tester.pump();
  await _idle(tester, outage);
  expect(
    find.byKey(const ValueKey('chat-connection-recovery-row')),
    findsOneWidget,
    reason: 'the loss must be visible for a recovery edge to exist',
  );
  fixture.gateway.restoreSocket();
  fixture.link.markUp();
  await tester.pump();
  await _idle(tester, healthy);
  expect(
    find.byKey(const ValueKey('chat-connection-recovery-row')),
    findsNothing,
    reason: 'the recovery edge (and «Conexión restablecida») must have fired',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ConnectionStatusRegistry.instance.reset();
    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final secure = <String, String>{};
    final messenger = TestWidgetsFlutterBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
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
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_foreground_task/methods'),
      (call) async => call.method == 'isRunningService' ? false : null,
    );
  });

  tearDown(() {
    ConnectionStatusRegistry.instance.reset();
  });

  testWidgets(
    'T1-1: a recovery edge reads the full durable page (no tail probe) and '
    'brings in rows committed while the socket was down',
    (tester) async {
      final server = _TranscriptServer();
      final fixture = await _mount(tester, server);
      await _idle(tester, const Duration(seconds: 40));
      final heavyBefore = server.heavyReads;
      final requestsBefore = server.requests.length;

      fixture.gateway.down = true;
      fixture.gateway.dropSocket();
      fixture.link.markDown();
      await tester.pump();
      await _idle(tester, const Duration(seconds: 5));
      // Rows landed in the durable store while this surface could not hear
      // anything; the local projection and the confirmed tail know nothing.
      server.append('user', content: 'Asked while the socket was down');
      server.append('assistant', content: 'Answered while the socket was down');

      fixture.gateway.restoreSocket();
      fixture.link.markUp();
      await tester.pump();
      await _idle(tester, const Duration(seconds: 3));

      expect(
        server.heavyReads - heavyBefore,
        1,
        reason:
            'the recovery edge must read the full durable page exactly once '
            'instead of trusting the one-row tail probe',
      );
      expect(
        server.readShapesSince(requestsBefore).first,
        'page',
        reason:
            'a recovery read is forced: the first request of the generation '
            'is the full page, never the tail probe — that probe is what let '
            'the 「unchanged」 short-circuit swallow the rows landed offline',
      );
      expect(
        fixture.chat.messages.first['content'],
        'Answered while the socket was down',
      );
      expect(find.text('Answered while the socket was down'), findsOneWidget);
      expect(
        fixture.chat.messages.where(
          (m) => m['content'] == 'Answered while the socket was down',
        ),
        hasLength(1),
      );
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'T1-2: an empty reconnect still forces one full read, keeps the projection '
    'intact and clears the pending read',
    (tester) async {
      final server = _TranscriptServer();
      final fixture = await _mount(tester, server);
      await _idle(tester, const Duration(seconds: 40));
      final heavyBefore = server.heavyReads;
      final probeBefore = server.probeReads;
      final idsBefore = fixture.chat.messages.map((m) => m['id']).toList();

      await _cutAndRecover(tester, fixture);

      expect(
        server.heavyReads - heavyBefore,
        1,
        reason:
            'the first read of a recovery generation is always the full page, '
            'even when nothing moved',
      );
      expect(server.probeReads - probeBefore, 0);
      expect(fixture.chat.messages.map((m) => m['id']).toList(), idsBefore);
      expect(fixture.chat.messages, hasLength(_rowCount));

      // The read confirmed the generation: the next quiet window must not
      // re-download the page (a lost pending flag would force it again).
      final heavyAfterEdge = server.heavyReads;
      await _idle(tester, const Duration(seconds: 90));
      expect(server.heavyReads - heavyAfterEdge, 0);
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'T1-3: a read in flight across the edge does not swallow the forced read',
    (tester) async {
      final server = _TranscriptServer();
      final fixture = await _mount(tester, server);
      await _idle(tester, const Duration(seconds: 40));
      final heavyBefore = server.heavyReads;

      // A slow passive read started BEFORE the edge (an ordinary
      // `sessions.changed` tick) holds the reader while the link recovers.
      server.latency = const Duration(seconds: 3);
      fixture.gateway.emit('sessions.changed');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      fixture.gateway.down = true;
      fixture.gateway.dropSocket();
      fixture.link.markDown();
      await tester.pump();
      await _idle(tester, const Duration(seconds: 4));
      expect(
        find.byKey(const ValueKey('chat-connection-recovery-row')),
        findsOneWidget,
      );
      fixture.gateway.restoreSocket();
      fixture.link.markUp();
      await tester.pump();
      // The edge lands while the first read is still in flight.
      await _idle(tester, const Duration(seconds: 3));
      server.latency = Duration.zero;
      await _idle(tester, const Duration(seconds: 6));

      expect(
        server.heavyReads - heavyBefore,
        1,
        reason:
            'the edge request must be merged behind the in-flight read and '
            'still be the full page read of the recovery generation',
      );
      final ids = fixture.chat.messages.map((m) => m['id']).toList();
      expect(ids, hasLength(_rowCount));
      expect(ids.toSet(), hasLength(ids.length));
      expect(
        fixture.chat.transportRecoveryDurableReadCompletedEpoch,
        fixture.chat.transportRecoveryDurableReadEpoch,
        reason: 'the merged read closed the generation',
      );
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'T1-4: a failed recovery read keeps the pending forced read and converges '
    'on the reader retry',
    (tester) async {
      final server = _TranscriptServer();
      final fixture = await _mount(tester, server);
      await _idle(tester, const Duration(seconds: 40));
      final heavyBefore = server.heavyReads;

      server.append('assistant', content: 'Committed during the outage');
      server.failMessages = true;
      final requestsBefore = server.requests.length;
      await _cutAndRecover(tester, fixture);
      final failedAttempts = server.heavyReads - heavyBefore;
      expect(
        failedAttempts,
        greaterThanOrEqualTo(1),
        reason: 'the recovery read must be attempted at once',
      );
      expect(
        fixture.chat.messages.any(
          (m) => m['content'] == 'Committed during the outage',
        ),
        isFalse,
      );

      // The transient failure heals; the reader's first failure interval (5 s)
      // retries, and that retry must still be a forced full read.
      server.failMessages = false;
      await _idle(tester, const Duration(seconds: 12));

      expect(
        server.heavyReads - heavyBefore,
        greaterThan(failedAttempts),
        reason: 'a failed recovery read must be retried, not dropped',
      );
      expect(
        server.readShapesSince(requestsBefore).first,
        'page',
        reason:
            'the first request of the generation is the full page even when it '
            'fails, so the retry (not a tail probe) is what converges',
      );
      expect(
        fixture.chat.transportRecoveryDurableReadCompletedEpoch,
        fixture.chat.transportRecoveryDurableReadEpoch,
      );
      expect(
        fixture.chat.messages.first['content'],
        'Committed during the outage',
      );
      await _dispose(tester, fixture);
    },
  );

  testWidgets(
    'T1-5: a read in flight when a second recovery edge lands does not close '
    'the new generation; the newest edge gets its own full read',
    (tester) async {
      final server = _TranscriptServer();
      final fixture = await _mount(tester, server);
      await _idle(tester, const Duration(seconds: 40));
      final heavyBefore = server.heavyReads;

      // Edge 1 (the real widget edge): the generation converges at once.
      await _cutAndRecover(tester, fixture);
      expect(server.heavyReads - heavyBefore, 1);
      expect(
        fixture.chat.transportRecoveryDurableReadCompletedEpoch,
        fixture.chat.transportRecoveryDurableReadEpoch,
      );

      // A durable tip edit makes the next passive read a FULL read (the probe
      // can see it). Hold it 5 s so edge 2 lands while it is in flight.
      server.rewriteNewest('Edited tip from Desktop');
      server.latency = const Duration(seconds: 5);
      fixture.gateway.emit('sessions.changed');
      await tester.pump();
      final heavyBeforeEdge2 = server.heavyReads;
      // Probe (5 s) then the full read starts.
      await _idle(tester, const Duration(seconds: 7));
      expect(
        server.heavyReads - heavyBeforeEdge2,
        1,
        reason: 'the in-flight read of the pre-edge generation',
      );

      // Edge 2 while that read is still in flight. The second edge is
      // injected through the same public call the widget's edge handler
      // makes: `ChatTransportVisibility.noticeSpacing` reads the wall clock
      // (60 s), so a second REAL edge would need a full minute of test wall
      // time — the epoch/pending contract is what this test pins down.
      fixture.chat.noteTransportRecoveredForDurableRead();
      server.append('assistant', content: 'Committed after the second cut');
      server.latency = Duration.zero;
      // The screen requests the read for the new edge (merged behind the
      // in-flight one, exactly as a second widget edge would).
      fixture.gateway.emit('sessions.changed');
      await tester.pump();
      // The tick may wait for the reader's 10 s store-change gap: the pending
      // read of the newest generation must still run after it.
      await _idle(tester, const Duration(seconds: 25));

      expect(
        server.heavyReads - heavyBeforeEdge2,
        greaterThanOrEqualTo(2),
        reason:
            'the read that started before edge 2 cannot cover it: a new full '
            'read must run for the newest epoch',
      );
      expect(
        fixture.chat.messages.first['content'],
        'Committed after the second cut',
      );
      expect(
        fixture.chat.transportRecoveryDurableReadEpoch,
        2,
        reason: 'two recovery edges, two epochs',
      );
      expect(
        fixture.chat.transportRecoveryDurableReadCompletedEpoch,
        2,
        reason:
            'the generation converged only after a read covered the newest '
            'edge (the superseded read never closed it)',
      );
      await _dispose(tester, fixture);
    },
  );
}
