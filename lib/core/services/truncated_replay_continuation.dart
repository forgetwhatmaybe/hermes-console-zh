import '../models/desktop_session_snapshot.dart';
import 'replay_snapshot_boundary.dart';
import 'viewer_turn_snapshot_projection.dart';

/// Outcome of a truncated-replay snapshot continuation attempt.
enum TruncatedReplayVerdict {
  /// The snapshot was applied completely and the replay boundary adopted: live
  /// frames after it dispatch again.
  continued,

  /// The snapshot was not applied (or could not be completed): nothing moved,
  /// the quarantine and every held frame stay, and the durable transcript is
  /// the convergence path.
  convergedDurably,

  /// Not applicable (no running viewer turn for this runtime, request failure).
  skipped,
}

final class TruncatedReplayOutcome {
  final TruncatedReplayVerdict verdict;
  final ViewerSnapshotRejection rejection;
  final int? baseline;
  final bool boundaryAdopted;

  const TruncatedReplayOutcome({
    required this.verdict,
    this.rejection = ViewerSnapshotRejection.accepted,
    this.baseline,
    this.boundaryAdopted = false,
  });

  static const TruncatedReplayOutcome skipped = TruncatedReplayOutcome(
    verdict: TruncatedReplayVerdict.skipped,
  );

  static TruncatedReplayOutcome rejected(ViewerSnapshotRejection rejection) =>
      TruncatedReplayOutcome(
        verdict: TruncatedReplayVerdict.convergedDurably,
        rejection: rejection,
      );

  @override
  String toString() =>
      'TruncatedReplayOutcome($verdict, ${rejection.name}, '
      'baseline=$baseline, adopted=$boundaryAdopted)';
}

/// What [ViewerTruncatedReplayContinuation] needs from the chat that owns the
/// viewer turn. The service is the adapter; this port keeps the ordering rules
/// of the continuation testable without a live socket.
abstract class ViewerTruncatedReplayPort {
  /// A turn submitted elsewhere is still being watched here and is not
  /// terminal (the only state the boundary may resume).
  bool get viewerTurnStillRunning;

  /// Runtime this chat has attached, if any.
  String? get attachedRuntimeSessionId;

  /// The turn already reached a terminal state locally.
  bool get terminalFenced;

  /// Public text currently painted in the live assistant row.
  String get livePublicAssistantText;

  ViewerTurnSnapshotBinding captureBinding({
    required String runtimeSessionId,
    required String replayEpoch,
  });

  bool bindingIsCurrent(ViewerTurnSnapshotBinding binding);

  /// `session.resume` of the watched durable session (read-only: no runtime
  /// adoption, no ownership, no `close_on_disconnect`).
  Future<DesktopSessionSnapshot> readSnapshot();

  /// Durable causal proof that the inflight still describes this viewer turn
  /// (a final answer after its prompt means the snapshot belongs to a later
  /// turn with the same prompt).
  Future<bool> keepsViewerTurnOpen(DesktopSessionSnapshot snapshot);

  /// Applies the snapshot completely (live text + display metadata + todo).
  /// Returns false when any part could not be projected.
  Future<bool> applySnapshot(DesktopSessionSnapshot snapshot);

  /// Adopts the snapshot/replay cut in the replay coordinator.
  bool adoptBoundary({required int baseline, required String replayEpoch});
}

/// Drives the viewer half of Task 3: after a truncated replay batch, read the
/// authoritative inflight snapshot and — only if it applies completely — adopt
/// its `last_sequence` boundary so the stream continues.
///
/// The order is the invariant (r4):
///   1. guards that cost nothing (binding, response identity/epoch, terminal
///      fence, still running) reject before any durable read;
///   2. the durable causal proof separates two consecutive turns with the same
///      prompt;
///   3. the text prefix guard runs inside [ViewerTruncatedReplayPort.applySnapshot]
///      via [projectViewerTurnSnapshot] and a rejection there refuses the whole
///      snapshot;
///   4. only then is the boundary adopted. A refused snapshot never advances the
///      watermark, never drops held frames and never lifts the quarantine.
final class ViewerTruncatedReplayContinuation {
  const ViewerTruncatedReplayContinuation();

  Future<TruncatedReplayOutcome> run({
    required String runtimeSessionId,
    required String replayEpoch,
    required ViewerTruncatedReplayPort port,
  }) async {
    if (!port.viewerTurnStillRunning) return TruncatedReplayOutcome.skipped;
    if (port.attachedRuntimeSessionId != runtimeSessionId) {
      return TruncatedReplayOutcome.skipped;
    }
    final binding = port.captureBinding(
      runtimeSessionId: runtimeSessionId,
      replayEpoch: replayEpoch,
    );
    final DesktopSessionSnapshot snapshot;
    try {
      snapshot = await port.readSnapshot();
    } catch (_) {
      return TruncatedReplayOutcome.skipped;
    }
    final boundary = SnapshotReplayBoundary.tryResolve(
      snapshot,
      runtimeSessionId: binding.runtimeSessionId,
      storedSessionId: binding.storedSessionId,
      replayEpoch: binding.replayEpoch,
    );
    final bindingCurrent = port.bindingIsCurrent(binding);
    final running = snapshot.running && snapshot.inflight != null;
    final ViewerSnapshotDecision decision;
    if (!bindingCurrent || boundary == null || port.terminalFenced || !running) {
      decision = decideViewerSnapshotApplication(
        bindingCurrent: bindingCurrent,
        responseIdentityMatches: boundary != null,
        terminalFenced: port.terminalFenced,
        running: running,
        // Not reached in this branch: one of the guards above already failed.
        turnStillOpen: false,
        livePublicText: '',
        snapshotPublicText: '',
        baseline: boundary?.baseline,
      );
    } else {
      final turnStillOpen = await port.keepsViewerTurnOpen(snapshot);
      decision = decideViewerSnapshotApplication(
        bindingCurrent: true,
        responseIdentityMatches: true,
        terminalFenced: false,
        running: true,
        turnStillOpen: turnStillOpen,
        livePublicText: port.livePublicAssistantText,
        snapshotPublicText: viewerSnapshotPublicText(snapshot.inflight),
        baseline: boundary.baseline,
      );
    }
    if (!decision.accepted) {
      return TruncatedReplayOutcome.rejected(decision.rejection);
    }
    // The application re-checks every guard against the state that is current
    // NOW (the durable read above is asynchronous): a late terminal frame, a
    // session switch or a newer delta refuses the whole snapshot.
    final bool applied;
    try {
      applied = await port.applySnapshot(snapshot);
    } catch (_) {
      return TruncatedReplayOutcome.rejected(
        ViewerSnapshotRejection.textDiverged,
      );
    }
    if (!applied) {
      return TruncatedReplayOutcome.rejected(
        ViewerSnapshotRejection.textDiverged,
      );
    }
    final baseline = decision.baseline!;
    final adopted = port.adoptBoundary(
      baseline: baseline,
      replayEpoch: binding.replayEpoch,
    );
    return TruncatedReplayOutcome(
      verdict: TruncatedReplayVerdict.continued,
      baseline: baseline,
      boundaryAdopted: adopted,
    );
  }
}
