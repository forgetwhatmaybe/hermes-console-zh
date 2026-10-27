// 复现「一次发送变成两次提交」的调查用例（只读调查，不修改 lib/）。
//
// 构造方式照抄 test/turn_idempotency_contract_test.dart 的 `_fixture`
// （ActiveChat + 内存 outbox + fake gateway），只把 fake 换成能记录
// 「线上实际发了什么」的版本：每一次 prompt.submit 都记录
// (runtimeId, text, clientTurnId)，其中 clientTurnId == null 表示这一次
// 提交是**没有去重键**的 legacy prompt.submit —— 服务端只能当成新回合。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/models/prepared_turn.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/services/turn_outbox_store.dart';

import 'support/in_memory_compression_restore_storage.dart';

const String _text = '今天知乎微博有啥关于ai的新闻';

class _MemoryOutbox implements TurnOutboxPersistence {
  final List<PreparedTurn> writes = [];
  final List<PreparedTurn> deletes = [];

  @override
  Future<void> save(PreparedTurn turn) async => writes.add(turn);

  @override
  Future<void> delete(PreparedTurn turn) async => deletes.add(turn);
}

/// 一次真正离开客户端的提交。
class _WireSubmission {
  _WireSubmission(this.runtimeSessionId, this.text, this.clientTurnId);

  final String runtimeSessionId;
  final String text;

  /// null = 走了 `submitPrompt`（没有 client_turn_id，服务端无从去重）。
  final String? clientTurnId;

  @override
  String toString() => '(runtime=$runtimeSessionId, id=$clientTurnId)';
}

class _FakeGateway implements HermesDesktopGateway, HermesDesktopIdempotentGateway {
  final _events = StreamController<TuiGatewayEvent>.broadcast();

  /// 每一次离开客户端的提交，按发生顺序。
  final List<_WireSubmission> wire = [];

  /// 服务端回合记录，模拟真实的 `client_turn_id` 去重语义：
  /// 同一个 id 再次到达 → 复用已有回合（ACK.duplicate = true），不新建；
  /// 没有 id 的 legacy 提交 → 每次都新建一个回合（= 用户看到的新气泡）。
  final Map<String, String> _turnByClientTurnId = {};

  /// 服务端一共创建了几个回合。
  final List<String> createdTurns = [];

  /// 第 n 次 `submitPromptIdempotent` 抛出的错误（null = 成功）。
  final List<Object?> idempotentErrors;

  /// 第 n 次提交**已被服务端受理**后，响应路径再抛带错误码的内部错误。
  /// 用来覆盖「accepted then coded error」：能力不能被判死，重试必须仍带 id。
  final int? codedErrorAfterAcceptAttempt;

  _FakeGateway({
    this.idempotentErrors = const [],
    this.codedErrorAfterAcceptAttempt,
  });

  int _idempotentCalls = 0;
  int statusCalls = 0;

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
    runtimeSessionId: 'runtime-desktop',
    storedSessionId: storedSessionId,
    created: false,
  );

  @override
  Future<DesktopTurnAck> submitPromptIdempotent(
    String runtimeSessionId,
    String text,
    String clientTurnId,
  ) async {
    final attempt = _idempotentCalls++;
    wire.add(_WireSubmission(runtimeSessionId, text, clientTurnId));
    if (attempt < idempotentErrors.length) {
      final error = idempotentErrors[attempt];
      if (error != null) {
        // 只有「结果未知」的失败（ACK 丢失/超时）才可能已被服务端接受；
        // 带确定错误码的拒收（4001 等）保证没有落库。
        final ambiguous =
            error is! TuiGatewayRpcError || error.code == null;
        if (ambiguous) {
          _turnByClientTurnId[clientTurnId] ??= _newTurn(clientTurnId, text);
        }
        throw error;
      }
    }
    final existing = _turnByClientTurnId[clientTurnId];
    final duplicate = existing != null;
    final turnId = existing ?? _newTurn(clientTurnId, text);
    if (attempt == codedErrorAfterAcceptAttempt) {
      // The turn is already durable; only the answer was lost to an internal
      // error. A coded failure here says nothing about the capability.
      throw const TuiGatewayRpcError(
        'prompt.submit',
        'internal error after accept',
        code: -32603,
      );
    }
    return DesktopTurnAck(
      accepted: true,
      clientTurnId: clientTurnId,
      serverTurnId: turnId,
      state: DesktopTurnState.accepted,
      duplicate: duplicate,
    );
  }

  String _newTurn(String key, String text) {
    final id = 'server-turn-${createdTurns.length + 1}';
    createdTurns.add(id);
    // Same contract as the server: a turn accepted under a client_turn_id is
    // returned again for a duplicate submit instead of opening a second turn.
    _turnByClientTurnId[key] = id;
    return id;
  }

  @override
  Future<bool> supportsTurnIdempotency() async => true;

  @override
  Future<DesktopTurnStatus> getTurnStatus(
    String sessionId,
    String clientTurnId,
  ) async {
    statusCalls++;
    return DesktopTurnStatus(known: false, clientTurnId: clientTurnId);
  }

  @override
  Future<void> submitPrompt(String runtimeSessionId, String text) async {
    // 这条路径不携带 clientTurnId：正是 legacy 线上格式。
    wire.add(_WireSubmission(runtimeSessionId, text, null));
    _newTurn('legacy-${createdTurns.length + 1}', text);
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
}

/// 4001 恢复需要 session lifecycle + typed recovery（与契约测试的
/// `_ModernGateway`/`_OwnershipGateway` 同构）。
class _OwnershipFakeGateway extends _FakeGateway
    implements
        HermesDesktopSessionLifecycleGateway,
        HermesDesktopTypedRecoveryGateway {
  _OwnershipFakeGateway({
    required this.resumeRuntimeIds,
    super.idempotentErrors,
  });

  final List<String> resumeRuntimeIds;
  final List<(String, String)> resumes = [];
  final ReplayCoordinator _recovery = ReplayCoordinator();
  final Object _recoveryChannel = Object();
  int _resumeIndex = 0;

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
    _recovery.quarantine(snapshot.runtimeSessionId);
    return _recovery.mintRecoveryProof(
      connectionId: connectionId,
      durableSessionId: snapshot.storedSessionId,
      runtimeSessionId: snapshot.runtimeSessionId,
      profile: profile,
      socketGeneration: 1,
      channel: _recoveryChannel,
      bindGeneration: bindGeneration,
      sessionGeneration: sessionGeneration,
      turnGeneration: turnGeneration,
      replayEpoch: null,
      created: snapshot.created,
      durableIdentityExplicit: snapshot.storedSessionIdentityExplicit,
      identityAliasesConsistent: snapshot.identityAliasesConsistent,
      coverage: RecoveryDomain.values.toSet(),
      postSnapshotSequence: 1,
    );
  }

  @override
  bool validateRecovery(RecoveryProof proof) => _recovery.canCommitRecovery(
    proof,
    socketGeneration: 1,
    channel: _recoveryChannel,
    replayEpoch: null,
  );

  @override
  bool commitRecovery(RecoveryProof proof) => _recovery.commitRecovery(
    proof,
    socketGeneration: 1,
    channel: _recoveryChannel,
    replayEpoch: null,
  );

  @override
  bool recoveryAuthorityStillCurrent(RecoveryProof proof) =>
      _recovery.isRecoveryAuthorityCurrent(
        proof,
        socketGeneration: 1,
        channel: _recoveryChannel,
        replayEpoch: null,
      );

  @override
  Future<DesktopSessionSnapshot> resumeExisting(
    String storedSessionId, {
    String profile = '',
    bool omitMessages = false,
    bool deferHistory = false,
  }) async {
    resumes.add((storedSessionId, profile));
    final index = _resumeIndex.clamp(0, resumeRuntimeIds.length - 1);
    _resumeIndex += 1;
    return DesktopSessionSnapshot(
      runtimeSessionId: resumeRuntimeIds[index],
      storedSessionId: storedSessionId,
      created: false,
    );
  }

  @override
  Future<DesktopSessionSnapshot> createForFirstSubmit({
    String profile = '',
    List<Map<String, dynamic>> seedMessages = const [],
    String model = '',
  }) => throw StateError('ownership recovery must never create a session');
}

({ActiveChat chat, ActiveTurnDelivery delivery, _MemoryOutbox store}) _fixture(
  HermesDesktopGateway gateway, {
  Future<bool> Function()? capability,
  _MemoryOutbox? outbox,
  String profile = '',
}) {
  final api = ApiClient(
    baseUrl: 'https://example.invalid',
    apiKey: 'test-only',
    httpClient: MockClient((_) async => http.Response('unused', 500)),
  );
  final chat = ActiveChat(
    compressionRestoreStore: testCompressionRestoreStore(),
    connection: SavedConnection(
      id: 'conn-modern',
      label: 'Modern',
      host: 'example.invalid',
      port: 443,
      apiKey: 'test-only',
      useHttps: true,
    ),
    sessionId: 'session-modern',
    sessionTitle: 'Modern',
    notifications: null,
    onTerminal: () {},
    api: api,
    desktopGateway: gateway,
    allowUnownedDesktopSnapshotForTesting: true,
    turnIdempotencyCapability: capability,
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  final store = outbox ?? _MemoryOutbox();
  return (
    chat: chat,
    delivery: ActiveTurnDelivery(
      prepared: PreparedTurn(
        connectionId: 'conn-modern',
        sessionId: 'session-modern',
        clientTurnId: 'client-turn-1',
        createdAtMs: now,
        updatedAtMs: now,
        text: _text,
        attachments: const [],
        model: 'hermes-agent',
        profile: profile,
      ),
      store: store,
    ),
    store: store,
  );
}

/// 屏幕侧重试：`_sendMessageOnce` 复用 `_preparedTurn`（chat_screen.dart:11266-11285），
/// 因此重试的 delivery 携带同一个 clientTurnId。
ActiveTurnDelivery _retryDelivery(
  ActiveTurnDelivery previous,
  _MemoryOutbox store,
) => ActiveTurnDelivery(prepared: previous.current, store: store);

Future<bool> _send(
  ActiveChat chat,
  ActiveTurnDelivery delivery, {
  String text = _text,
  String profile = '',
}) => chat.send(
  fullText: text,
  model: 'hermes-agent',
  history: const [],
  profile: profile,
  delivery: delivery,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('T1 一次 send 正常成功 → 线上只有一次提交', () async {
    final gateway = _FakeGateway();
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    expect(await _send(fixture.chat, fixture.delivery), isTrue);

    expect(gateway.wire, hasLength(1));
    expect(gateway.wire.single.clientTurnId, 'client-turn-1');
    expect(gateway.createdTurns, hasLength(1));
    expect(fixture.delivery.current.state, PreparedTurnState.running);
  });

  test('T2 ACK 丢失（connectionLost）后用户重试 → 仍带同一去重键，'
      '服务端只有一个回合', () async {
    final gateway = _FakeGateway(
      idempotentErrors: const [
        TuiGatewayRpcError(
          'prompt.submit',
          'Connection lost before JSON-RPC response',
          code: null,
          failureKind: TuiGatewayRpcFailureKind.connectionLost,
        ),
      ],
    );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    expect(await _send(fixture.chat, fixture.delivery), isFalse);
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.ambiguous,
      reason: 'ACK 丢失必须落成 ambiguous（服务端可能已接受）',
    );

    // 用户点了重试：屏幕复用同一个 clientTurnId（prepared 批次未变）。
    final retry = _retryDelivery(fixture.delivery, fixture.store);
    expect(await _send(fixture.chat, retry), isTrue);

    final ids = gateway.wire.map((submission) => submission.clientTurnId).toSet();
    expect(
      ids,
      {'client-turn-1'},
      reason:
          '重试必须以同一 client_turn_id 抵达服务端；'
          '实际线上序列=${gateway.wire}',
    );
    expect(
      gateway.wire,
      hasLength(2),
      reason: '一次 ACK 丢失 + 一次人工重试 = 两次线上提交，这是合法的',
    );
    expect(
      gateway.createdTurns,
      hasLength(1),
      reason:
          '服务端按 client_turn_id 去重后只能有一个回合；'
          '实际回合数=${gateway.createdTurns.length}',
    );
  });

  test('T2b 机制：ACK 丢失不得永久废掉幂等键，重试仍走 idempotent 通道', () async {
    final gateway = _FakeGateway(
      idempotentErrors: const [
        TuiGatewayRpcError(
          'prompt.submit',
          'Connection lost before JSON-RPC response',
          failureKind: TuiGatewayRpcFailureKind.connectionLost,
        ),
      ],
    );
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    expect(await _send(fixture.chat, fixture.delivery), isFalse);

    // 传输歧义不构成能力判决：capability 必须保留，否则重试会丢 id。
    expect(fixture.chat.turnIdempotencyInvalid, isFalse);

    final retry = _retryDelivery(fixture.delivery, fixture.store);
    expect(await _send(fixture.chat, retry), isTrue);

    expect(gateway.wire, hasLength(2), reason: '两次提交都真的离开了客户端');
    expect(gateway.wire[0].clientTurnId, 'client-turn-1');
    expect(
      gateway.wire[1].clientTurnId,
      'client-turn-1',
      reason:
          '重试必须继续带同一个 client_turn_id；'
          '掉成 legacy submitPrompt 会让服务端开出第二个回合',
    );
    expect(gateway.wire[1].text, _text);
    // 第一次已被服务端接受（只是 ACK 丢了）；第二次带同一 id → 去重，1 个回合。
    expect(gateway.createdTurns, hasLength(1));
  });

  test('T5 已受理后返回带码内部错误 → 能力不失效，重试同 id 只 1 个回合', () async {
    final gateway = _FakeGateway(codedErrorAfterAcceptAttempt: 0);
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    expect(await _send(fixture.chat, fixture.delivery), isFalse);
    // 服务端已落库，错误来自响应路径：不是能力判决。
    expect(gateway.createdTurns, hasLength(1));
    expect(fixture.chat.turnIdempotencyInvalid, isFalse);

    final retry = _retryDelivery(fixture.delivery, fixture.store);
    expect(await _send(fixture.chat, retry), isTrue);

    expect(gateway.wire.map((s) => s.clientTurnId).toSet(), {'client-turn-1'});
    expect(gateway.createdTurns, hasLength(1));
  });

  test('T3 4001 可恢复拒收 → 两次 submit、同一个 client_turn_id（不回归）', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'session not found',
      code: 4001,
    );
    final gateway = _OwnershipFakeGateway(
      resumeRuntimeIds: const ['runtime-stale', 'runtime-resumed'],
      idempotentErrors: const [rejection, null],
    );
    final fixture = _fixture(
      gateway,
      capability: () async => true,
      profile: 'owner-profile',
    );
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages(profile: 'owner-profile');
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    final accepted = await _send(
      fixture.chat,
      fixture.delivery,
      profile: 'owner-profile',
    );
    debugPrint = original;
    expect(
      accepted,
      isTrue,
      reason:
          '4001 之后应恢复 runtime 并重提成功；'
          'runtime=${fixture.chat.desktopRuntimeSessionId}, '
          'resumes=${gateway.resumes}, wire=${gateway.wire}, logs=$logs',
    );

    expect(gateway.resumes, hasLength(2));
    expect(gateway.wire, hasLength(2));
    expect(
      gateway.wire.map((submission) => submission.clientTurnId).toList(),
      ['client-turn-1', 'client-turn-1'],
      reason: '4001 重提必须复用同一个 id（既有契约测试断言的同一行为）',
    );
    expect(gateway.wire.map((submission) => submission.runtimeSessionId).toList(), [
      'runtime-stale',
      'runtime-resumed',
    ]);
    expect(fixture.chat.turnIdempotencyInvalid, isFalse);
    expect(
      gateway.createdTurns,
      hasLength(1),
      reason: '4001 被拒时服务端没有建回合，重提用同一 id 复用同一个回合',
    );
  });

  test('T3b 4001 重提失败后叠加用户重试 → 仍是同一个 id、同一个回合', () async {
    const rejection = TuiGatewayRpcError(
      'prompt.submit',
      'session not found',
      code: 4001,
    );
    final gateway = _OwnershipFakeGateway(
      resumeRuntimeIds: const ['runtime-stale', 'runtime-resumed'],
      idempotentErrors: const [rejection, rejection, null],
    );
    final fixture = _fixture(
      gateway,
      capability: () async => true,
      profile: 'owner-profile',
    );
    addTearDown(fixture.chat.dispose);

    await fixture.chat.loadMessages(profile: 'owner-profile');
    expect(
      await _send(fixture.chat, fixture.delivery, profile: 'owner-profile'),
      isFalse,
      reason: '两个 4001 之后必须停下，不能自己循环重提',
    );
    expect(
      fixture.delivery.current.state,
      PreparedTurnState.failedBeforeAcceptance,
    );
    expect(fixture.chat.turnIdempotencyInvalid, isFalse, reason: '4001 是确定性拒收');

    final retry = _retryDelivery(fixture.delivery, fixture.store);
    expect(
      await _send(fixture.chat, retry, profile: 'owner-profile'),
      isTrue,
    );

    expect(
      gateway.wire.map((submission) => submission.clientTurnId).toList(),
      ['client-turn-1', 'client-turn-1', 'client-turn-1'],
    );
    expect(
      gateway.createdTurns,
      hasLength(1),
      reason: '4001 → 自动重提 → 用户重试 全部复用同一 id，服务端只有一个回合',
    );
  });

  test('T4 两次不同手势、同一文本 → 两个不同 client_turn_id（防误去重）', () async {
    final gateway = _FakeGateway();
    final fixture = _fixture(gateway, capability: () async => true);
    addTearDown(fixture.chat.dispose);

    final now = DateTime.now().millisecondsSinceEpoch;
    PreparedTurn turn(String id) => PreparedTurn(
      connectionId: 'conn-modern',
      sessionId: 'session-modern',
      clientTurnId: id,
      createdAtMs: now,
      updatedAtMs: now,
      text: _text,
      attachments: const <AttachmentDraft>[],
      model: 'hermes-agent',
      profile: '',
    );

    expect(
      await _send(
        fixture.chat,
        ActiveTurnDelivery(prepared: turn('client-turn-a'), store: fixture.store),
      ),
      isTrue,
    );
    expect(
      await _send(
        fixture.chat,
        ActiveTurnDelivery(prepared: turn('client-turn-b'), store: fixture.store),
      ),
      isTrue,
    );

    expect(gateway.wire, hasLength(2));
    expect(
      gateway.wire.map((submission) => submission.clientTurnId).toSet(),
      {'client-turn-a', 'client-turn-b'},
    );
    expect(gateway.createdTurns, hasLength(2));
  });
}
