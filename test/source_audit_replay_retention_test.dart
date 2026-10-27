import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/services/recovery_proof.dart';
import 'package:hermes_android/core/services/replay_batch_proof.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';
import 'package:hermes_android/core/services/replay_snapshot_boundary.dart';

const _runtime = 'audit-runtime';
const _epoch = 'audit-epoch';

class _Replay {
  final coordinator = ReplayCoordinator();
  final channel = Object();

  _Replay() {
    emit('message.start', 1);
    coordinator.beginReconnect(generation: 2, channel: channel, epoch: _epoch);
  }

  ReplayLiveDisposition emit(String type, int sequence, {String text = ''}) =>
      coordinator.acceptLive(
        SessionGatewayEvent(type, _runtime, sequence, {'text': text}),
        socketGeneration: 2,
        channel: channel,
        replayEpoch: _epoch,
      );

  ReplayBatchDecision truncate() => coordinator.validateReplay(_runtime, {
    'epoch': _epoch,
    'truncated': true,
    'latest_seq': 6,
    'events': <dynamic>[],
  });

  bool adopt(
    int baseline, {
    Object? wire,
    int generation = 2,
    String epoch = _epoch,
  }) => coordinator.adoptSnapshotBoundary(
    runtime: _runtime,
    baseline: baseline,
    socketGeneration: generation,
    channel: wire ?? channel,
    replayEpoch: epoch,
  );
}

void main() {
  for (final abandon in ['single', 'all', 'quarantine']) {
    test(
      '$abandon replay abandonment preserves held control for safe recovery',
      () {
        final replay = _Replay();
        replay.emit('tool.start', 6);
        switch (abandon) {
          case 'single':
            replay.coordinator.abandonTransaction(_runtime);
          case 'all':
            replay.coordinator.abandonAllTransactions();
          case 'quarantine':
            replay.coordinator.quarantine(_runtime);
        }
        expect(replay.adopt(6), isFalse);
        expect(replay.adopt(5), isTrue);
        expect(
          replay.coordinator
              .takeCommittedRecoveryEvents(_runtime)
              .map((e) => e.type),
          ['tool.start'],
        );
      },
    );
  }

  test(
    'retired held frames require full recovery while allowing a fresh authority',
    () {
      final replay = _Replay();
      replay.emit('tool.start', 6);
      replay.coordinator.retireTransport(
        generation: 2,
        channel: replay.channel,
      );
      final nextChannel = Object();
      replay.coordinator.retireTransport(
        generation: 2,
        channel: replay.channel,
      );
      expect(replay.adopt(6, generation: 3, wire: nextChannel), isFalse);
      final proof = replay.coordinator.mintRecoveryProof(
        connectionId: 'connection',
        durableSessionId: 'stored',
        runtimeSessionId: _runtime,
        profile: 'default',
        socketGeneration: 3,
        channel: nextChannel,
        bindGeneration: 1,
        sessionGeneration: 1,
        turnGeneration: 1,
        replayEpoch: _epoch,
        created: false,
        durableIdentityExplicit: true,
        identityAliasesConsistent: true,
        coverage: RecoveryDomain.values.toSet(),
        postSnapshotSequence: 6,
      );
      expect(
        replay.coordinator.commitRecovery(
          proof,
          socketGeneration: 3,
          channel: nextChannel,
          replayEpoch: _epoch,
        ),
        isTrue,
      );
      expect(replay.coordinator.isQuarantined(_runtime), isFalse);
      expect(replay.coordinator.takeCommittedRecoveryEvents(_runtime), isEmpty);
    },
  );

  test('retired viewer can leave quarantine at an explicit new turn', () {
    final replay = _Replay();
    replay.emit('tool.start', 6);
    replay.coordinator.retireTransport(generation: 2, channel: replay.channel);
    expect(replay.adopt(6, generation: 3, wire: Object()), isFalse);
    expect(replay.coordinator.releaseForNewTurn(_runtime), isTrue);
    expect(
      replay.coordinator.acceptLive(
        const SessionGatewayEvent('message.start', _runtime, 7, {}),
        socketGeneration: 3,
        channel: Object(),
        replayEpoch: _epoch,
      ),
      ReplayLiveDisposition.dispatch,
    );
  });

  test('retired recovery markers remain within the runtime capacity', () {
    final coordinator = ReplayCoordinator();
    final channel = Object();
    for (var index = 0; index < ReplayCoordinator.maxTrackedRuntimes; index++) {
      coordinator.acceptLive(
        SessionGatewayEvent('message.start', 'runtime-$index', 1, {}),
      );
    }
    coordinator.beginReconnect(generation: 1, channel: channel, epoch: _epoch);
    for (var index = 0; index < ReplayCoordinator.maxTrackedRuntimes; index++) {
      expect(
        coordinator.acceptLive(
          SessionGatewayEvent('tool.start', 'runtime-$index', 2, {}),
          socketGeneration: 1,
          channel: channel,
          replayEpoch: _epoch,
        ),
        ReplayLiveDisposition.held,
      );
    }
    coordinator.retireTransport(generation: 1, channel: channel);
    coordinator.retireTransport(generation: 1, channel: channel);
    coordinator.forget('runtime-0');
    coordinator.quarantine('replacement');
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.start', 'replacement', 1, {}),
      ),
      ReplayLiveDisposition.held,
    );
    coordinator.quarantine('overflow');
    expect(
      coordinator.acceptLive(
        const SessionGatewayEvent('message.start', 'overflow', 1, {}),
      ),
      ReplayLiveDisposition.quarantined,
    );
    expect(
      coordinator.adoptSnapshotBoundary(
        runtime: 'runtime-1',
        baseline: 2,
        socketGeneration: 2,
        channel: Object(),
        replayEpoch: _epoch,
      ),
      isFalse,
    );
  });

  test('truncated replay retains uncovered tool across refused snapshot', () {
    final replay = _Replay();
    expect(replay.emit('tool.start', 6), ReplayLiveDisposition.held);
    expect(replay.truncate(), isA<ReplayBatchQuarantine>());
    expect(replay.coordinator.takeCommittedRecoveryEvents(_runtime), isEmpty);
    expect(replay.adopt(6), isFalse);
    expect(replay.coordinator.isQuarantined(_runtime), isTrue);
    expect(replay.emit('message.delta', 7), ReplayLiveDisposition.held);
    expect(replay.adopt(5), isTrue);
    final released = replay.coordinator.takeCommittedRecoveryEvents(_runtime);
    expect(released.map((e) => (e.type, e.sequence)), [
      ('tool.start', 6),
      ('message.delta', 7),
    ]);
    expect(replay.coordinator.takeCommittedRecoveryEvents(_runtime), isEmpty);
    expect(replay.emit('message.delta', 7), ReplayLiveDisposition.ignored);
    expect(replay.emit('message.delta', 8), ReplayLiveDisposition.dispatch);
  });

  test('truncated replay retains text suffix after snapshot cut', () {
    final replay = _Replay();
    replay.emit('message.delta', 7, text: 'retained suffix');
    replay.truncate();
    expect(replay.adopt(6), isTrue);
    final released = replay.coordinator.takeCommittedRecoveryEvents(_runtime);
    expect(released, hasLength(1));
    expect(released.single.payload['text'], 'retained suffix');
    expect(released.single.sequence, 7);
    expect(replay.coordinator.watermarks[_runtime], 7);
  });

  for (final mismatch in ['epoch', 'channel', 'generation']) {
    test('truncated replay refuses a different $mismatch', () {
      final replay = _Replay();
      replay.emit('message.delta', 7);
      replay.truncate();
      expect(
        replay.adopt(
          6,
          epoch: mismatch == 'epoch' ? 'other-epoch' : _epoch,
          wire: mismatch == 'channel' ? Object() : replay.channel,
          generation: mismatch == 'generation' ? 3 : 2,
        ),
        isFalse,
      );
      expect(replay.coordinator.takeCommittedRecoveryEvents(_runtime), isEmpty);
      expect(replay.coordinator.isQuarantined(_runtime), isTrue);
    });
  }

  test(
    'invalid replay cannot authorize snapshot over discarded held frames',
    () {
      final replay = _Replay();
      replay.emit('tool.start', 6);
      expect(
        replay.coordinator.validateReplay(_runtime, {
          'epoch': 'other-epoch',
          'truncated': false,
          'latest_seq': 6,
          'events': <dynamic>[],
        }),
        isA<ReplayBatchQuarantine>(),
      );
      expect(replay.adopt(6), isFalse);
      expect(replay.coordinator.takeCommittedRecoveryEvents(_runtime), isEmpty);
    },
  );

  test('conflicting held replay poisons later snapshot adoption', () {
    final replay = _Replay();
    replay.emit('message.delta', 6, text: 'first');
    expect(
      replay.emit('message.delta', 6, text: 'conflict'),
      ReplayLiveDisposition.quarantined,
    );
    expect(replay.adopt(6), isFalse);
    expect(replay.coordinator.takeCommittedRecoveryEvents(_runtime), isEmpty);
  });

  test('held replay overflow cannot become an empty valid snapshot', () {
    final replay = _Replay();
    for (var seq = 2; seq <= ReplayCoordinator.maxHeldEvents + 1; seq++) {
      expect(replay.emit('message.delta', seq), ReplayLiveDisposition.held);
    }
    expect(
      replay.emit('message.delta', ReplayCoordinator.maxHeldEvents + 2),
      ReplayLiveDisposition.quarantined,
    );
    expect(replay.adopt(ReplayCoordinator.maxHeldEvents + 2), isFalse);
    expect(replay.coordinator.takeCommittedRecoveryEvents(_runtime), isEmpty);
  });

  test(
    'snapshot binding requires its captured epoch including null rejection',
    () {
      const binding = ViewerTurnSnapshotBinding(
        connectionId: 'connection',
        storedSessionId: 'stored',
        serverSessionId: 'server',
        profile: 'default',
        runtimeSessionId: _runtime,
        socketGeneration: 2,
        replayEpoch: _epoch,
        turnEpoch: 3,
        viewerConvergenceEpoch: 4,
        viewerFreshBusyEpoch: null,
        recoveryRun: 5,
      );
      bool current(String? epoch) => binding.isCurrent(
        connectionId: 'connection',
        storedSessionId: 'stored',
        serverSessionId: 'server',
        profile: 'default',
        runtimeSessionId: _runtime,
        socketGeneration: 2,
        replayEpoch: epoch,
        turnEpoch: 3,
        viewerConvergenceEpoch: 4,
        viewerFreshBusyEpoch: null,
        recoveryRun: 5,
      );
      expect(current(_epoch), isTrue);
      expect(current('other-epoch'), isFalse);
      expect(current(null), isFalse);
    },
  );
}
