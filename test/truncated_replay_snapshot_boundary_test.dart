import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/desktop_session_snapshot.dart';
import 'package:hermes_android/core/services/json_rpc_wire.dart';
import 'package:hermes_android/core/services/replay_coordinator.dart';

/// Task 3: truncated 回放的快照续流。
///
/// A 组锁定 `DesktopSessionSnapshot` 对 `last_sequence` / `replay_epoch` 以及
/// `inflight.display_kind` / `inflight.display_metadata` 的防御式解析。
/// B/C 组锁定 `ReplayCoordinator.adoptSnapshotBoundary` 的排序语义
/// (T3-1/2/3/10/11)：只有「快照覆盖到 baseline，且 baseline 之后的 retained
/// 帧连续」才允许采用，采用后 watermark 落到最后一帧、quarantine 解除，之后
/// 的 live 帧重新 dispatch。
SessionGatewayEvent frame(int seq, {String runtime = 'runtime-a'}) =>
    SessionGatewayEvent('message.delta', runtime, seq, {'text': 'x'});

DesktopSessionSnapshot parse(Map<String, dynamic> extra) =>
    DesktopSessionSnapshot.fromJson(
      <String, dynamic>{'session_id': 'runtime-a', ...extra},
      requestedStoredSessionId: 'stored-a',
      created: false,
      method: 'session.resume',
    );

List<int?> sequencesOf(List<SessionGatewayEvent> events) =>
    events.map((event) => event.sequence).toList();

void main() {
  group('A. 快照边界解析 (DesktopSessionSnapshot.fromJson)', () {
    test('A1 last_sequence:42 + replay_epoch:"e1" 解析为 42 / "e1"', () {
      final snapshot = parse(const {
        'last_sequence': 42,
        'replay_epoch': 'e1',
      });

      expect(snapshot.lastSequence, 42);
      expect(snapshot.replayEpoch, 'e1');
    });

    test('A2 两字段缺失 → 都是 null（旧服务器无权威切点）', () {
      final snapshot = parse(const <String, dynamic>{});

      expect(snapshot.lastSequence, null);
      expect(snapshot.replayEpoch, null);
    });

    test('A3 last_sequence 非正整数 / 非数字 → null（防御式解析）', () {
      final cases = <String, Object?>{
        'zero': 0,
        'negative': -7,
        'string "42"': '42',
        'fraction 4.5': 4.5,
      };

      for (final entry in cases.entries) {
        final snapshot = parse(<String, dynamic>{
          'last_sequence': entry.value,
        });
        expect(
          snapshot.lastSequence,
          null,
          reason: 'last_sequence=${entry.key} 必须解析为 null',
        );
      }
    });

    test('A4 replay_epoch 空串 / 纯空格 / 非字符串 → null', () {
      final cases = <String, Object?>{
        'empty': '',
        'blank': '   ',
        'number': 123,
      };

      for (final entry in cases.entries) {
        final snapshot = parse(<String, dynamic>{
          'replay_epoch': entry.value,
        });
        expect(
          snapshot.replayEpoch,
          null,
          reason: 'replay_epoch=${entry.key} 必须解析为 null',
        );
      }
    });

    test('A5 inflight.display_kind / display_metadata 解析，缺字段不崩', () {
      final snapshot = parse(const {
        'inflight': {
          'assistant': 'hola',
          'streaming': true,
          'display_kind': 'model_switch',
          'display_metadata': {'from': 'a', 'to': 'b', 'nested': {'k': 1}},
        },
      });
      final inflight = snapshot.inflight!;

      expect(inflight.displayKind, 'model_switch');
      expect(inflight.displayMetadata, {
        'from': 'a',
        'to': 'b',
        'nested': {'k': 1},
      });

      // 缺少投影字段：turn 仍在，投影字段为 null（重投影时不得抛）。
      final bare = parse(const {
        'inflight': {'assistant': 'hola'},
      }).inflight!;
      expect(bare.displayKind, null);
      expect(bare.displayMetadata, null);

      // 字段类型错误：同样退化为 null，而不是崩溃或强转。
      final wrongTypes = parse(const {
        'inflight': {
          'assistant': 'hola',
          'display_kind': 7,
          'display_metadata': 'nope',
        },
      }).inflight!;
      expect(wrongTypes.displayKind, null);
      expect(wrongTypes.displayMetadata, null);
    });
  });

  group('B. adoptSnapshotBoundary 排序语义', () {
    test('B1 baseline 6 采用快照 → 释放 7/8，watermark=8，seq 9 继续 dispatch', () {
      final coordinator = ReplayCoordinator();
      const runtime = 'runtime-a';
      const generation = 7;
      const epoch = 'epoch-a';
      final channel = Object();

      bool adopt(int baseline) => coordinator.adoptSnapshotBoundary(
        runtime: runtime,
        baseline: baseline,
        socketGeneration: generation,
        channel: channel,
        replayEpoch: epoch,
      );

      ReplayLiveDisposition live(int seq) => coordinator.acceptLive(
        frame(seq),
        socketGeneration: generation,
        channel: channel,
        replayEpoch: epoch,
      );

      // 1) 先建立 watermark（正常在线阶段）。
      expect(live(1), ReplayLiveDisposition.dispatch);
      expect(coordinator.watermarks, {runtime: 1});

      // 2) 流被打断，运行时进入隔离态。
      coordinator.quarantine(runtime);
      expect(coordinator.isQuarantined(runtime), true);

      // 3) truncated 期间的 live 帧被 hold。
      for (final seq in [5, 6, 7, 8]) {
        expect(live(seq), ReplayLiveDisposition.held, reason: 'seq $seq');
      }

      // 4) 快照覆盖到 6，held 的 7/8 连续 → 采用成功。
      expect(adopt(6), true);
      expect(coordinator.isQuarantined(runtime), false);
      expect(coordinator.watermarks, {runtime: 8});
      expect(
        sequencesOf(coordinator.takeCommittedRecoveryEvents(runtime)),
        [7, 8],
      );
      // 已交付的帧不会被第二次交付。
      expect(coordinator.takeCommittedRecoveryEvents(runtime), isEmpty);

      // 5) T3-2：快照之后流式继续，下一帧直接 dispatch。
      expect(live(9), ReplayLiveDisposition.dispatch);
      expect(coordinator.watermarks, {runtime: 9});
    });

    test('B2 baseline 等于最后一帧 → 采用成功，watermark=8，无帧释放', () {
      final coordinator = ReplayCoordinator();
      const runtime = 'runtime-a';
      const generation = 3;
      const epoch = 'epoch-a';
      final channel = Object();

      coordinator.quarantine(runtime);
      for (final seq in [5, 6, 7, 8]) {
        expect(
          coordinator.acceptLive(
            frame(seq),
            socketGeneration: generation,
            channel: channel,
            replayEpoch: epoch,
          ),
          ReplayLiveDisposition.held,
        );
      }

      expect(
        coordinator.adoptSnapshotBoundary(
          runtime: runtime,
          baseline: 8,
          socketGeneration: generation,
          channel: channel,
          replayEpoch: epoch,
        ),
        true,
      );
      expect(coordinator.isQuarantined(runtime), false);
      expect(coordinator.watermarks, {runtime: 8});
      expect(coordinator.takeCommittedRecoveryEvents(runtime), isEmpty);
    });

    test('B3 baseline 之后有空洞（缺 6）→ 拒绝，held 不丢（T3-3）', () {
      final coordinator = ReplayCoordinator();
      const runtime = 'runtime-a';
      const generation = 11;
      const epoch = 'epoch-a';
      final channel = Object();

      bool adopt(int baseline) => coordinator.adoptSnapshotBoundary(
        runtime: runtime,
        baseline: baseline,
        socketGeneration: generation,
        channel: channel,
        replayEpoch: epoch,
      );

      coordinator.quarantine(runtime);
      for (final seq in [5, 7, 8]) {
        expect(
          coordinator.acceptLive(
            frame(seq),
            socketGeneration: generation,
            channel: channel,
            replayEpoch: epoch,
          ),
          ReplayLiveDisposition.held,
          reason: 'seq $seq',
        );
      }

      // baseline 5 要求 held 侧从 6 起连续，实际第一条是 7 → 空洞。
      expect(adopt(5), false);
      expect(coordinator.isQuarantined(runtime), true);
      // 隔离时 watermark 已被清空，被拒的采用不得写入任何新边界。
      expect(coordinator.watermarks, isEmpty);
      expect(coordinator.takeCommittedRecoveryEvents(runtime), isEmpty);

      // held 帧没有被失败吞掉：能覆盖空洞的 baseline 6 立即采用成功。
      expect(adopt(6), true);
      expect(coordinator.watermarks, {runtime: 8});
      expect(
        sequencesOf(coordinator.takeCommittedRecoveryEvents(runtime)),
        [7, 8],
      );
    });

    test('B3b baseline 6 已覆盖 5/6 → 基线之后仍连续即接受', () {
      // 说明：本题正是任务书里 "held 5,7,8 + baseline 6" 的形态。baseline 6
      // 表示快照内容已经包含 5 和 6（replay_coordinator.dart:583-590 对
      // `sequence <= baseline` 直接跳过），因此 7/8 是连续的，不存在空洞，
      // 采用必须成功。真正的空洞是 baseline 5（见 B3）。
      final coordinator = ReplayCoordinator();
      const runtime = 'runtime-a';
      const generation = 12;
      const epoch = 'epoch-a';
      final channel = Object();

      coordinator.quarantine(runtime);
      for (final seq in [5, 7, 8]) {
        expect(
          coordinator.acceptLive(
            frame(seq),
            socketGeneration: generation,
            channel: channel,
            replayEpoch: epoch,
          ),
          ReplayLiveDisposition.held,
        );
      }

      expect(
        coordinator.adoptSnapshotBoundary(
          runtime: runtime,
          baseline: 6,
          socketGeneration: generation,
          channel: channel,
          replayEpoch: epoch,
        ),
        true,
      );
      expect(coordinator.isQuarantined(runtime), false);
      expect(coordinator.watermarks, {runtime: 8});
      expect(
        sequencesOf(coordinator.takeCommittedRecoveryEvents(runtime)),
        [7, 8],
      );
    });

    test('B4 未 quarantine 的 runtime → 拒绝', () {
      final coordinator = ReplayCoordinator();

      expect(coordinator.acceptLive(frame(1)), ReplayLiveDisposition.dispatch);
      expect(coordinator.isQuarantined('runtime-a'), false);

      expect(
        coordinator.adoptSnapshotBoundary(
          runtime: 'runtime-a',
          baseline: 5,
          socketGeneration: 7,
          channel: Object(),
          replayEpoch: 'epoch-a',
        ),
        false,
      );

      expect(coordinator.isQuarantined('runtime-a'), false);
      expect(coordinator.watermarks, {'runtime-a': 1});
    });

    test('B5 baseline <= 0 → 拒绝且不动任何状态', () {
      final coordinator = ReplayCoordinator();
      const runtime = 'runtime-a';
      const generation = 4;
      const epoch = 'epoch-a';
      final channel = Object();

      coordinator.quarantine(runtime);
      for (final seq in [5, 6, 7, 8]) {
        expect(
          coordinator.acceptLive(
            frame(seq),
            socketGeneration: generation,
            channel: channel,
            replayEpoch: epoch,
          ),
          ReplayLiveDisposition.held,
        );
      }

      for (final baseline in [0, -1]) {
        expect(
          coordinator.adoptSnapshotBoundary(
            runtime: runtime,
            baseline: baseline,
            socketGeneration: generation,
            channel: channel,
            replayEpoch: epoch,
          ),
          false,
          reason: 'baseline $baseline 必须被拒绝',
        );
        expect(coordinator.isQuarantined(runtime), true);
        expect(coordinator.watermarks, isEmpty);
      }

      // held 帧仍在：正确 baseline 立刻可用。
      expect(
        coordinator.adoptSnapshotBoundary(
          runtime: runtime,
          baseline: 6,
          socketGeneration: generation,
          channel: channel,
          replayEpoch: epoch,
        ),
        true,
      );
      expect(coordinator.watermarks, {runtime: 8});
      expect(
        sequencesOf(coordinator.takeCommittedRecoveryEvents(runtime)),
        [7, 8],
      );
    });

    test('B6 epoch 不符 → 拒绝，quarantine 保留（T3-11 协调器层）', () {
      final coordinator = ReplayCoordinator();
      const runtime = 'runtime-a';
      const generation = 9;
      const epoch = 'epoch-a';
      final channel = Object();

      coordinator.quarantine(runtime);
      for (final seq in [5, 6, 7, 8]) {
        expect(
          coordinator.acceptLive(
            frame(seq),
            socketGeneration: generation,
            channel: channel,
            replayEpoch: epoch,
          ),
          ReplayLiveDisposition.held,
        );
      }

      // 快照宣告的 epoch 属于另一条流：它的边界不描述这里 held 的帧。
      expect(
        coordinator.adoptSnapshotBoundary(
          runtime: runtime,
          baseline: 6,
          socketGeneration: generation,
          channel: channel,
          replayEpoch: 'epoch-b',
        ),
        false,
      );
      expect(coordinator.isQuarantined(runtime), true);
      expect(coordinator.watermarks, isEmpty);
      // 恢复事务在 wire 绑定失败后被 poison，后续 live 帧只能继续隔离。
      expect(
        coordinator.acceptLive(
          frame(9),
          socketGeneration: generation,
          channel: channel,
          replayEpoch: 'epoch-b',
        ),
        ReplayLiveDisposition.quarantined,
      );
      expect(coordinator.isQuarantined(runtime), true);
    });
  });

  group('C. 被拒快照不推进边界 (T3-10)', () {
    test('C1 失败的 adopt 无副作用：watermark 不前进、held 仍可被正确采用', () {
      final coordinator = ReplayCoordinator();
      const runtime = 'runtime-a';
      const generation = 21;
      const epoch = 'epoch-a';
      final channel = Object();

      bool adopt(int baseline) => coordinator.adoptSnapshotBoundary(
        runtime: runtime,
        baseline: baseline,
        socketGeneration: generation,
        channel: channel,
        replayEpoch: epoch,
      );

      // 先有一次真实的 watermark，再被截断清掉，才能证明「被拒」没有偷偷
      // 把它恢复成某个快照值。
      expect(
        coordinator.acceptLive(
          frame(1),
          socketGeneration: generation,
          channel: channel,
          replayEpoch: epoch,
        ),
        ReplayLiveDisposition.dispatch,
      );
      expect(coordinator.watermarks, {runtime: 1});

      coordinator.quarantine(runtime);
      expect(coordinator.watermarks, isEmpty);

      for (final seq in [5, 7, 8]) {
        expect(
          coordinator.acceptLive(
            frame(seq),
            socketGeneration: generation,
            channel: channel,
            replayEpoch: epoch,
          ),
          ReplayLiveDisposition.held,
        );
      }

      // 被拒（空洞）：边界不前进。
      expect(adopt(5), false);
      expect(coordinator.isQuarantined(runtime), true);
      expect(coordinator.watermarks, isEmpty);
      expect(coordinator.takeCommittedRecoveryEvents(runtime), isEmpty);

      // 同一份 held 用正确 baseline 立刻完成采用 → 失败的 adopt 没有吞掉状态。
      expect(adopt(6), true);
      expect(coordinator.isQuarantined(runtime), false);
      expect(coordinator.watermarks, {runtime: 8});
      expect(
        sequencesOf(coordinator.takeCommittedRecoveryEvents(runtime)),
        [7, 8],
      );
    });

    test('B7 快照未覆盖的帧（tool.start）在 baseline 之下 → 拒绝采用，'
        'quarantine 与 held 全部保留', () {
      final coordinator = ReplayCoordinator();
      const runtime = 'runtime-a';
      const generation = 21;
      const epoch = 'epoch-a';
      final channel = Object();

      bool adopt(int baseline) => coordinator.adoptSnapshotBoundary(
        runtime: runtime,
        baseline: baseline,
        socketGeneration: generation,
        channel: channel,
        replayEpoch: epoch,
      );

      coordinator.quarantine(runtime);
      // 5 = texto, 6 = un paso de herramienta que el snapshot NO reproduce.
      for (final event in [
        frame(5),
        const SessionGatewayEvent('tool.start', runtime, 6, {
          'tool_id': 'call-1',
          'name': 'read_file',
        }),
        frame(7),
      ]) {
        expect(
          coordinator.acceptLive(
            event,
            socketGeneration: generation,
            channel: channel,
            replayEpoch: epoch,
          ),
          ReplayLiveDisposition.held,
          reason: 'seq ${event.sequence}',
        );
      }

      // baseline 6 "cubriría" el tool.start, pero el snapshot sólo lleva
      // texto: descartarlo perdería la pill de la herramienta.
      expect(adopt(6), false);
      expect(coordinator.isQuarantined(runtime), true);
      expect(coordinator.watermarks, isEmpty);
      expect(coordinator.takeCommittedRecoveryEvents(runtime), isEmpty);

      // 拒绝没有吞掉任何状态：再以 baseline 4 采用，5/6/7 全部按序释放。
      expect(adopt(4), true);
      expect(coordinator.isQuarantined(runtime), false);
      expect(coordinator.watermarks, {runtime: 7});
      expect(
        sequencesOf(coordinator.takeCommittedRecoveryEvents(runtime)),
        [5, 6, 7],
      );
    });
  });
}
