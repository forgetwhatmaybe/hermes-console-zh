import '../models/desktop_session_snapshot.dart';

/// The authoritative snapshot/replay cut a `session.resume` answer carries.
///
/// tui_gateway stamps `last_sequence` + `replay_epoch` inside the same
/// `history_lock` critical section that builds the snapshot, so every replay
/// frame with `sequence <= baseline` is already reflected in the snapshot
/// content. Without both fields there is no cut and nothing may be ordered by
/// guesswork (`latest_seq` from `session.events.since` is read later and would
/// mark frames the snapshot never covered as covered).
final class SnapshotReplayBoundary {
  final int baseline;
  final String replayEpoch;

  const SnapshotReplayBoundary({
    required this.baseline,
    required this.replayEpoch,
  });

  /// Resolves the cut from the RESPONSE itself and validates it against what
  /// the requesting side captured before sending `session.resume`.
  ///
  /// A restarted or rebound stream can answer with another runtime/session or
  /// another epoch; its boundary then orders frames of a different event
  /// stream. Absent or mismatching identity is a refusal, never a degraded
  /// application.
  static SnapshotReplayBoundary? tryResolve(
    DesktopSessionSnapshot snapshot, {
    required String runtimeSessionId,
    required String storedSessionId,
    required String? replayEpoch,
  }) {
    if (replayEpoch == null || replayEpoch.isEmpty) return null;
    final baseline = snapshot.lastSequence;
    if (baseline == null || baseline <= 0) return null;
    if (snapshot.runtimeSessionId != runtimeSessionId) return null;
    if (snapshot.storedSessionId != storedSessionId) return null;
    if (snapshot.replayEpoch != replayEpoch) return null;
    return SnapshotReplayBoundary(baseline: baseline, replayEpoch: replayEpoch);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SnapshotReplayBoundary &&
          baseline == other.baseline &&
          replayEpoch == other.replayEpoch;

  @override
  int get hashCode => Object.hash(baseline, replayEpoch);
}

/// Everything a truncated-replay viewer snapshot is bound to when it is
/// requested. The response may only be applied while every one of these still
/// matches: a session switch, a runtime change, a reconnect, a new turn or a
/// new viewer convergence generation makes the snapshot describe another
/// world.
final class ViewerTurnSnapshotBinding {
  final String connectionId;
  final String storedSessionId;
  final String serverSessionId;
  final String profile;
  final String runtimeSessionId;
  final int socketGeneration;
  final String replayEpoch;
  final int turnEpoch;
  final int viewerConvergenceEpoch;
  final int? viewerFreshBusyEpoch;
  final int recoveryRun;

  const ViewerTurnSnapshotBinding({
    required this.connectionId,
    required this.storedSessionId,
    required this.serverSessionId,
    required this.profile,
    required this.runtimeSessionId,
    required this.socketGeneration,
    required this.replayEpoch,
    required this.turnEpoch,
    required this.viewerConvergenceEpoch,
    required this.viewerFreshBusyEpoch,
    required this.recoveryRun,
  });

  bool isCurrent({
    required String connectionId,
    required String storedSessionId,
    required String serverSessionId,
    required String profile,
    required String runtimeSessionId,
    required int socketGeneration,
    required String? replayEpoch,
    required int turnEpoch,
    required int? viewerConvergenceEpoch,
    required int? viewerFreshBusyEpoch,
    required int recoveryRun,
  }) =>
      this.connectionId == connectionId &&
      this.storedSessionId == storedSessionId &&
      this.serverSessionId == serverSessionId &&
      this.profile == profile &&
      this.runtimeSessionId == runtimeSessionId &&
      this.socketGeneration == socketGeneration &&
      this.replayEpoch == replayEpoch &&
      this.turnEpoch == turnEpoch &&
      this.viewerConvergenceEpoch == viewerConvergenceEpoch &&
      this.viewerFreshBusyEpoch == viewerFreshBusyEpoch &&
      this.recoveryRun == recoveryRun;
}

/// Why a viewer snapshot was (not) applied. Only [accepted] authorises the
/// replay boundary: a rejected snapshot proves nothing about which held frames
/// its text already covers.
enum ViewerSnapshotRejection {
  accepted,

  /// The captured tuple (session/runtime/epochs/socket/turn/viewer run) moved
  /// while the request was in flight.
  bindingChanged,

  /// The response's own runtime/stored id/replay epoch are absent or differ
  /// from what the request captured.
  responseIdentity,

  /// The turn reached a terminal state before the answer arrived.
  terminalFence,

  /// The durable transcript shows this viewer turn already closed (a final
  /// answer after its prompt): the inflight describes the next turn.
  turnClosed,

  /// Nothing is running any more (`running:false` / `inflight:null`).
  notRunning,

  /// The live row's public text is no longer a prefix of the snapshot text.
  textDiverged,
}

final class ViewerSnapshotDecision {
  final ViewerSnapshotRejection rejection;
  final int? baseline;

  const ViewerSnapshotDecision._(this.rejection, this.baseline);

  const ViewerSnapshotDecision.rejected(ViewerSnapshotRejection rejection)
    : this._(rejection, null);

  const ViewerSnapshotDecision.accepted(int baseline)
    : this._(ViewerSnapshotRejection.accepted, baseline);

  bool get accepted => rejection == ViewerSnapshotRejection.accepted;
}

/// The single decision point of the truncated-replay snapshot application.
///
/// r4 semantics: a snapshot that any guard rejects never advances the replay
/// boundary, never drops held frames and never lifts the quarantine. Text
/// length or divergence is not proof that those frames are covered, so the
/// whole snapshot (and with it the boundary) is discarded; the chat converges
/// from the durable transcript instead.
ViewerSnapshotDecision decideViewerSnapshotApplication({
  required bool bindingCurrent,
  required bool responseIdentityMatches,
  required bool terminalFenced,
  required bool running,
  required bool turnStillOpen,
  required String livePublicText,
  required String snapshotPublicText,
  required int? baseline,
}) {
  if (!bindingCurrent) {
    return const ViewerSnapshotDecision.rejected(
      ViewerSnapshotRejection.bindingChanged,
    );
  }
  if (!responseIdentityMatches || baseline == null || baseline <= 0) {
    return const ViewerSnapshotDecision.rejected(
      ViewerSnapshotRejection.responseIdentity,
    );
  }
  if (terminalFenced) {
    return const ViewerSnapshotDecision.rejected(
      ViewerSnapshotRejection.terminalFence,
    );
  }
  if (!running) {
    return const ViewerSnapshotDecision.rejected(
      ViewerSnapshotRejection.notRunning,
    );
  }
  if (!turnStillOpen) {
    return const ViewerSnapshotDecision.rejected(
      ViewerSnapshotRejection.turnClosed,
    );
  }
  if (!liveTextIsPrefixOfSnapshot(livePublicText, snapshotPublicText)) {
    return const ViewerSnapshotDecision.rejected(
      ViewerSnapshotRejection.textDiverged,
    );
  }
  return ViewerSnapshotDecision.accepted(baseline);
}

/// The snapshot may only replace the live text when the live text is already
/// its prefix (or equal): the reply streams forward, never backwards, and a
/// fork means the live row is not this inflight at all.
bool liveTextIsPrefixOfSnapshot(String livePublicText, String snapshotPublicText) {
  final live = livePublicText.trimLeft();
  final snapshot = snapshotPublicText.trimLeft();
  if (live.isEmpty) return true;
  return snapshot.startsWith(live);
}
