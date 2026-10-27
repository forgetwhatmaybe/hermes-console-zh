import 'dart:collection';

import 'json_rpc_wire.dart';
import 'recovery_proof.dart';
import 'replay_batch_proof.dart';

final class ReplayTransaction {
  final int generation;
  final Object channel;
  final String epoch;
  final String runtime;
  final int lastSeen;
  final List<SessionGatewayEvent> held = <SessionGatewayEvent>[];
  bool closed = false;

  ReplayTransaction({
    required this.generation,
    required this.channel,
    required this.epoch,
    required this.runtime,
    required this.lastSeen,
  });
}

final class _RecoveryTransaction {
  final Object identity = Object();
  final String runtime;
  int? socketGeneration;
  Object? channel;
  String? replayEpoch;
  String? connectionId;
  String? durableSessionId;
  String? profile;
  int? bindGeneration;
  int? sessionGeneration;
  int? turnGeneration;
  final List<SessionGatewayEvent> held = <SessionGatewayEvent>[];
  bool poisoned = false;
  // Retired wire frames cannot be replayed on a new wire. A text-only viewer
  // cut cannot cover that loss; a full-domain recovery proof still can.
  bool requiresFullRecovery = false;

  _RecoveryTransaction({
    required this.runtime,
    this.socketGeneration,
    this.channel,
    this.replayEpoch,
  });

  bool bindWire({
    required int generation,
    required Object? channelIdentity,
    required String? epoch,
  }) {
    if (poisoned) return false;
    if (socketGeneration != null && socketGeneration != generation) {
      return false;
    }
    if (channel != null && !identical(channel, channelIdentity)) return false;
    if (replayEpoch != null && replayEpoch != epoch) return false;
    socketGeneration ??= generation;
    channel ??= channelIdentity;
    replayEpoch ??= epoch;
    return true;
  }

  bool bindAuthority({
    required String connection,
    required String durable,
    required String ownerProfile,
    required int bind,
    required int session,
    required int turn,
  }) {
    if (poisoned) return false;
    if ((connectionId != null && connectionId != connection) ||
        (durableSessionId != null && durableSessionId != durable) ||
        (profile != null && profile != ownerProfile) ||
        (bindGeneration != null && bindGeneration != bind) ||
        (sessionGeneration != null && sessionGeneration != session) ||
        (turnGeneration != null && turnGeneration != turn)) {
      return false;
    }
    connectionId ??= connection;
    durableSessionId ??= durable;
    profile ??= ownerProfile;
    bindGeneration ??= bind;
    sessionGeneration ??= session;
    turnGeneration ??= turn;
    return true;
  }
}

enum ReplayLiveDisposition { dispatch, held, ignored, quarantined }

final class ReplayCoordinator {
  static const int maxTrackedRuntimes = 32;
  static const int maxQuarantineEntries = 32;
  static const int maxRecoveryExceptions = 32;
  static const int maxHeldEvents = 64;
  static const int maxTotalHeldEvents = maxTrackedRuntimes * maxHeldEvents;

  /// Frame types whose whole content a `session.resume` snapshot reproduces:
  /// the assistant text. A dropped frame of any other type (tool steps,
  /// activity, todo, reasoning, terminal) projects something the snapshot does
  /// not carry, so a snapshot boundary may not claim it as covered.
  static const Set<String> _snapshotCoveredReplayTypes = <String>{
    'message.start',
    'message.delta',
  };

  final LinkedHashMap<String, int> _watermarks = LinkedHashMap<String, int>();
  final Set<String> _quarantine = <String>{};
  final Set<String> _recoveryExceptions = <String>{};
  final Map<String, ReplayTransaction> _transactions =
      <String, ReplayTransaction>{};
  final Map<String, _RecoveryTransaction> _recoveryTransactions =
      <String, _RecoveryTransaction>{};
  final Set<RecoveryProof> _outstandingRecoveryProofs =
      HashSet<RecoveryProof>.identity();
  final Map<String, List<SessionGatewayEvent>> _committedRecoveryEvents =
      <String, List<SessionGatewayEvent>>{};
  final Map<String, RecoveryProof> _committedRecoveryAuthorities =
      <String, RecoveryProof>{};
  bool _quarantineAll = false;
  bool _resourceOverflowed = false;
  int _totalHeldEvents = 0;
  final RecoveryProofAuthority _recoveryAuthority = RecoveryProofAuthority();

  RecoveryProof mintRecoveryProof({
    required String connectionId,
    required String durableSessionId,
    required String runtimeSessionId,
    required String profile,
    required int socketGeneration,
    required Object channel,
    required int bindGeneration,
    required int sessionGeneration,
    required int turnGeneration,
    required String? replayEpoch,
    required bool created,
    required bool durableIdentityExplicit,
    required bool identityAliasesConsistent,
    required Set<RecoveryDomain> coverage,
    required int? postSnapshotSequence,
  }) {
    _outstandingRecoveryProofs.removeWhere(
      (candidate) => candidate.runtimeSessionId == runtimeSessionId,
    );
    final transaction = _recoveryTransactionFor(runtimeSessionId);
    if (transaction == null ||
        !transaction.bindWire(
          generation: socketGeneration,
          channelIdentity: channel,
          epoch: replayEpoch,
        ) ||
        !transaction.bindAuthority(
          connection: connectionId,
          durable: durableSessionId,
          ownerProfile: profile,
          bind: bindGeneration,
          session: sessionGeneration,
          turn: turnGeneration,
        )) {
      if (transaction != null) _poisonRecovery(transaction);
    }
    final proof = _recoveryAuthority.mint(
      transactionIdentity: transaction?.identity,
      channelIdentity: channel,
      connectionId: connectionId,
      durableSessionId: durableSessionId,
      runtimeSessionId: runtimeSessionId,
      profile: profile,
      socketGeneration: socketGeneration,
      bindGeneration: bindGeneration,
      sessionGeneration: sessionGeneration,
      turnGeneration: turnGeneration,
      replayEpoch: replayEpoch,
      created: created,
      durableIdentityExplicit: durableIdentityExplicit,
      identityAliasesConsistent: identityAliasesConsistent,
      coverage: coverage,
      postSnapshotSequence: postSnapshotSequence,
    );
    if (transaction != null && !transaction.poisoned && !_resourceOverflowed) {
      _outstandingRecoveryProofs.add(proof);
    }
    return proof;
  }

  List<SessionGatewayEvent> takeCommittedRecoveryEvents(String runtime) =>
      List<SessionGatewayEvent>.unmodifiable(
        _committedRecoveryEvents.remove(runtime) ??
            const <SessionGatewayEvent>[],
      );

  bool get hasWatermarks => _watermarks.isNotEmpty;
  Map<String, int> get watermarks => Map<String, int>.unmodifiable(_watermarks);
  bool isQuarantined(String runtime) =>
      _resourceOverflowed ||
      (_quarantineAll && !_recoveryExceptions.contains(runtime)) ||
      _quarantine.contains(runtime);

  List<MapEntry<String, int>> beginReconnect({
    required int generation,
    required Object channel,
    required String epoch,
  }) {
    _poisonWireMismatches(
      generation: generation,
      channel: channel,
      epoch: epoch,
    );
    final entries = _watermarks.entries.toList(growable: false);
    final overflow = entries.length - maxTrackedRuntimes;
    if (overflow > 0) {
      _poisonAllForResourceOverflow();
      return const <MapEntry<String, int>>[];
    }
    for (final entry in entries) {
      _transactions[entry.key] = ReplayTransaction(
        generation: generation,
        channel: channel,
        epoch: epoch,
        runtime: entry.key,
        lastSeen: entry.value,
      );
    }
    return entries;
  }

  ReplayLiveDisposition acceptLive(
    SessionGatewayEvent event, {
    int? socketGeneration,
    Object? channel,
    String? replayEpoch,
  }) {
    final runtime = event.sessionId;
    if (_resourceOverflowed) return ReplayLiveDisposition.quarantined;
    if (isQuarantined(runtime)) {
      final held = _recoveryTransactionFor(
        runtime,
        socketGeneration: socketGeneration,
        channel: channel,
        replayEpoch: replayEpoch,
      );
      if (held == null || held.poisoned) {
        return ReplayLiveDisposition.quarantined;
      }
      if (socketGeneration != null &&
          !held.bindWire(
            generation: socketGeneration,
            channelIdentity: channel,
            epoch: replayEpoch,
          )) {
        _poisonRecovery(held);
        return ReplayLiveDisposition.quarantined;
      }
      for (final prior in held.held) {
        if (prior.sequence != event.sequence) continue;
        if (ReplayBatchProof.sameEvent(prior, event)) {
          return ReplayLiveDisposition.ignored;
        }
        _poisonRecovery(held);
        return ReplayLiveDisposition.quarantined;
      }
      if (held.held.length >= maxHeldEvents ||
          _totalHeldEvents >= maxTotalHeldEvents) {
        _poisonRecovery(held);
        return ReplayLiveDisposition.quarantined;
      }
      held.held.add(event);
      _totalHeldEvents += 1;
      return ReplayLiveDisposition.held;
    }
    final transaction = _transactions[runtime];
    if (transaction != null && !transaction.closed) {
      if ((socketGeneration != null &&
              transaction.generation != socketGeneration) ||
          (channel != null && !identical(transaction.channel, channel)) ||
          (replayEpoch != null && transaction.epoch != replayEpoch)) {
        abandonTransaction(runtime, poison: true);
        return ReplayLiveDisposition.quarantined;
      }
      for (final prior in transaction.held) {
        if (prior.sequence != event.sequence) continue;
        if (ReplayBatchProof.sameEvent(prior, event)) {
          return ReplayLiveDisposition.ignored;
        }
        abandonTransaction(runtime, poison: true);
        return ReplayLiveDisposition.quarantined;
      }
      if (transaction.held.length >= maxHeldEvents ||
          _totalHeldEvents >= maxTotalHeldEvents) {
        abandonTransaction(runtime, poison: true);
        return ReplayLiveDisposition.quarantined;
      }
      transaction.held.add(event);
      _totalHeldEvents += 1;
      return ReplayLiveDisposition.held;
    }
    final sequence = event.sequence!;
    final previous = _watermarks[runtime];
    if (previous == null) {
      _recordWatermark(runtime, sequence);
      return isQuarantined(runtime)
          ? ReplayLiveDisposition.quarantined
          : ReplayLiveDisposition.dispatch;
    }
    if (sequence <= previous) return ReplayLiveDisposition.ignored;
    if (sequence != previous + 1) {
      quarantine(runtime);
      return ReplayLiveDisposition.quarantined;
    }
    _recordWatermark(runtime, sequence);
    return ReplayLiveDisposition.dispatch;
  }

  ReplayBatchDecision validateReplay(String runtime, Object? result) {
    final transaction = _transactions[runtime];
    if (transaction == null || transaction.closed) {
      return const ReplayBatchQuarantine('replay transaction is not current');
    }
    final decision = ReplayBatchProof.validate(
      runtime: runtime,
      epoch: transaction.epoch,
      lastSeen: transaction.lastSeen,
      result: result,
      held: List<SessionGatewayEvent>.unmodifiable(transaction.held),
    );
    // N10h-1: only a proven contiguous batch resumes the live stream (Hermes
    // Desktop flushReplayHold). Every other answer keeps the quarantine.
    if (decision is ReplayBatchCommit) {
      transaction.closed = true;
      _transactions.remove(runtime);
      _totalHeldEvents -= transaction.held.length;
      transaction.held.clear();
      _recordWatermark(runtime, decision.newWatermark);
    } else {
      // Quarantine retains the live frames on their captured wire. Only a
      // valid truncated proof may delegate their coverage to a viewer cut.
      quarantine(runtime);
      if (decision is! ReplayBatchQuarantine ||
          decision.reason != 'replay truncated') {
        final recovery = _recoveryTransactionFor(runtime);
        if (recovery != null) _poisonRecovery(recovery);
      }
    }
    return decision;
  }

  void abandonTransaction(String runtime, {bool poison = false}) {
    quarantine(runtime);
    if (poison) {
      final recovery = _recoveryTransactionFor(runtime);
      if (recovery != null) _poisonRecovery(recovery);
    }
  }

  void abandonAllTransactions() {
    for (final runtime in _transactions.keys.toList(growable: false)) {
      abandonTransaction(runtime);
    }
  }

  void rotateEpoch() {
    final observed = <String>{
      ..._watermarks.keys,
      ..._transactions.keys,
      ..._recoveryTransactions.keys,
    };
    _watermarks.clear();
    for (final transaction in _transactions.values) {
      _totalHeldEvents -= transaction.held.length;
      transaction.held.clear();
      transaction.closed = true;
    }
    _transactions.clear();
    for (final transaction in _recoveryTransactions.values.toList()) {
      _poisonRecovery(transaction);
    }
    _recoveryTransactions.clear();
    _outstandingRecoveryProofs.clear();
    _committedRecoveryAuthorities.clear();
    for (final runtime in observed) {
      quarantine(runtime);
    }
  }

  void retireTransport({required int generation, required Object channel}) {
    _committedRecoveryAuthorities.removeWhere(
      (_, proof) =>
          proof.socketGeneration == generation &&
          identical(proof.channelIdentity, channel),
    );
    // First transfer any replay hold so retirement cannot bypass its loss
    // marker. Repeated retirement of the old wire leaves the fresh marker.
    for (final entry in _transactions.entries.toList()) {
      final transaction = entry.value;
      if (transaction.generation == generation &&
          identical(transaction.channel, channel)) {
        abandonTransaction(entry.key);
      }
    }
    for (final transaction in _recoveryTransactions.values.toList()) {
      if (transaction.socketGeneration == generation &&
          identical(transaction.channel, channel)) {
        final lostProjection =
            transaction.requiresFullRecovery ||
            transaction.poisoned ||
            transaction.held.isNotEmpty;
        _poisonRecovery(transaction);
        if (identical(
          _recoveryTransactions[transaction.runtime],
          transaction,
        )) {
          _recoveryTransactions.remove(transaction.runtime);
          if (lostProjection && !_resourceOverflowed) {
            _recoveryTransactionFor(transaction.runtime)?.requiresFullRecovery =
                true;
          }
        }
      }
    }
  }

  /// Drops every trace of [runtime] once nobody on this transport reads it
  /// any more (the chat that attached it on a shared socket was released).
  /// Unlike [quarantine] it frees the slot: a long-lived socket shared by many
  /// chats would otherwise reach [maxTrackedRuntimes] and poison every live
  /// runtime. A later resume of the same runtime starts from no watermark,
  /// exactly as a fresh socket would.
  void forget(String runtime) {
    if (_resourceOverflowed) return;
    _watermarks.remove(runtime);
    _quarantine.remove(runtime);
    _recoveryExceptions.remove(runtime);
    _committedRecoveryEvents.remove(runtime);
    _committedRecoveryAuthorities.remove(runtime);
    _outstandingRecoveryProofs.removeWhere(
      (proof) => proof.runtimeSessionId == runtime,
    );
    final replay = _transactions.remove(runtime);
    if (replay != null) {
      _totalHeldEvents -= replay.held.length;
      replay.held.clear();
      replay.closed = true;
    }
    final recovery = _recoveryTransactions.remove(runtime);
    if (recovery != null) {
      if (!recovery.poisoned) _totalHeldEvents -= recovery.held.length;
      recovery.held.clear();
      recovery.poisoned = true;
    }
  }

  /// N10c: a turn the user just started on [runtime] is a turn boundary. The
  /// quarantine of a past cut (or live correction) guards that older turn,
  /// which its durable history already closes; keeping it would withhold every
  /// later turn of this runtime (no reasoning, no streaming) until the app
  /// restarts. Lifts it and drops the frames held for the old turn, so the
  /// first live frame of the new turn is the base. Refuses while a recovery
  /// proof is outstanding or a reconnect replay is open: that recovery decides
  /// by itself. Returns whether the quarantine was lifted.
  bool releaseForNewTurn(String runtime) {
    if (_resourceOverflowed || _quarantineAll) return false;
    if (!_quarantine.contains(runtime)) return false;
    if (_transactions.containsKey(runtime)) return false;
    if (_outstandingRecoveryProofs.any(
      (proof) => proof.runtimeSessionId == runtime,
    )) {
      return false;
    }
    final recovery = _recoveryTransactions.remove(runtime);
    if (recovery != null) {
      if (!recovery.poisoned) _totalHeldEvents -= recovery.held.length;
      recovery.held.clear();
      recovery.poisoned = true;
    }
    _quarantine.remove(runtime);
    _watermarks.remove(runtime);
    _committedRecoveryEvents.remove(runtime);
    _committedRecoveryAuthorities.remove(runtime);
    return true;
  }

  void quarantine(String runtime) {
    _committedRecoveryEvents.remove(runtime);
    _committedRecoveryAuthorities.remove(runtime);
    _outstandingRecoveryProofs.removeWhere(
      (proof) => proof.runtimeSessionId == runtime,
    );
    _watermarks.remove(runtime);
    final replay = _transactions.remove(runtime);
    final held = replay == null
        ? const <SessionGatewayEvent>[]
        : List<SessionGatewayEvent>.of(replay.held);
    if (replay != null) {
      _totalHeldEvents -= replay.held.length;
      replay.held.clear();
      replay.closed = true;
    }
    if (_resourceOverflowed) return;
    final known = <String>{
      ..._quarantine,
      ..._watermarks.keys,
      ..._transactions.keys,
      ..._recoveryTransactions.keys,
    };
    if (!known.contains(runtime) && known.length >= maxTrackedRuntimes) {
      _poisonAllForResourceOverflow();
      return;
    }
    if (_quarantineAll) {
      _recoveryExceptions.remove(runtime);
    } else {
      _quarantine.add(runtime);
      if (_quarantine.length > maxQuarantineEntries) {
        _poisonAllForResourceOverflow();
      }
    }
    if (replay != null && !_resourceOverflowed) {
      final recovery = _recoveryTransactionFor(
        runtime,
        socketGeneration: replay.generation,
        channel: replay.channel,
        replayEpoch: replay.epoch,
      );
      if (recovery != null &&
          !recovery.bindWire(
            generation: replay.generation,
            channelIdentity: replay.channel,
            epoch: replay.epoch,
          )) {
        _poisonRecovery(recovery);
      }
      for (final event in held) {
        acceptLive(
          event,
          socketGeneration: replay.generation,
          channel: replay.channel,
          replayEpoch: replay.epoch,
        );
      }
    }
  }

  bool commitRecovery(
    RecoveryProof proof, {
    required int socketGeneration,
    required Object channel,
    required String? replayEpoch,
  }) {
    if (!canCommitRecovery(
      proof,
      socketGeneration: socketGeneration,
      channel: channel,
      replayEpoch: replayEpoch,
    )) {
      _outstandingRecoveryProofs.remove(proof);
      return false;
    }
    _outstandingRecoveryProofs.remove(proof);
    final runtime = proof.runtimeSessionId;
    final transaction = _recoveryTransactions[runtime]!;
    final baseline = proof.postSnapshotSequence!;
    final released = <SessionGatewayEvent>[];
    for (final event in transaction.held) {
      if (event.sequence! > baseline) released.add(event);
    }
    _totalHeldEvents -= transaction.held.length;
    transaction.held.clear();
    _recoveryTransactions.remove(runtime);
    _quarantine.remove(runtime);
    if (_quarantineAll) {
      _recoveryExceptions.add(runtime);
      if (_recoveryExceptions.length > maxRecoveryExceptions) {
        _recoveryExceptions.remove(_recoveryExceptions.first);
      }
    }
    _recordWatermark(
      runtime,
      released.isEmpty ? baseline : released.last.sequence!,
    );
    if (released.isNotEmpty) {
      _committedRecoveryEvents[runtime] =
          List<SessionGatewayEvent>.unmodifiable(released);
    }
    _committedRecoveryAuthorities[runtime] = proof;
    return true;
  }

  /// Resumes a quarantined runtime's live stream from an authoritative
  /// snapshot/replay cut, for a turn this client only WATCHES (a viewer): it
  /// never mints or commits a recovery proof, never takes over the runtime and
  /// never touches ownership.
  ///
  /// The caller MUST have applied the snapshot completely before calling this
  /// (r4): the boundary is only trusted because the snapshot content covers it.
  /// Steps, identical in meaning to [commitRecovery]:
  ///   (a) held text frames with `seq <= baseline` are dropped; other types
  ///       refuse adoption because the viewer snapshot does not cover them;
  ///   (b) held frames with `seq > baseline` must be contiguous from
  ///       `baseline + 1`; a hole refuses the whole adoption and leaves the
  ///       quarantine (and every held frame) in place for the durable path;
  ///   (c) the watermark lands on `baseline` (or the last released frame) and
  ///       the quarantine is lifted, so later live frames dispatch again
  ///       through [acceptLive] — this is what "the stream continues after the
  ///       snapshot" means.
  bool adoptSnapshotBoundary({
    required String runtime,
    required int baseline,
    required int socketGeneration,
    required Object channel,
    required String replayEpoch,
  }) {
    if (_resourceOverflowed || baseline <= 0) return false;
    if (!isQuarantined(runtime)) return false;
    // An open replay transaction still owns this runtime's ordering: let it
    // answer instead of cutting under it.
    if (_transactions.containsKey(runtime)) return false;
    final transaction = _recoveryTransactionFor(
      runtime,
      socketGeneration: socketGeneration,
      channel: channel,
      replayEpoch: replayEpoch,
    );
    if (transaction == null ||
        transaction.poisoned ||
        transaction.requiresFullRecovery) {
      return false;
    }
    if (!transaction.bindWire(
      generation: socketGeneration,
      channelIdentity: channel,
      epoch: replayEpoch,
    )) {
      _poisonRecovery(transaction);
      return false;
    }
    var expected = baseline + 1;
    for (final event in transaction.held) {
      final sequence = event.sequence;
      if (sequence == null) return false;
      if (sequence <= baseline) {
        // The snapshot carries the assistant TEXT, not the tool/activity steps
        // those frames projected: dropping a tool frame here would lose a
        // running pill the cut never covered, so the whole adoption is
        // refused and the durable transcript converges instead (r4 invariant:
        // only what the snapshot fully covers may be discarded).
        if (!_snapshotCoveredReplayTypes.contains(event.type)) return false;
        continue;
      }
      if (sequence != expected) return false;
      expected += 1;
    }
    final released = <SessionGatewayEvent>[
      for (final event in transaction.held)
        if (event.sequence! > baseline) event,
    ];
    _totalHeldEvents -= transaction.held.length;
    transaction.held.clear();
    _recoveryTransactions.remove(runtime);
    _quarantine.remove(runtime);
    if (_quarantineAll) {
      _recoveryExceptions.add(runtime);
      if (_recoveryExceptions.length > maxRecoveryExceptions) {
        _recoveryExceptions.remove(_recoveryExceptions.first);
      }
    }
    _recordWatermark(
      runtime,
      released.isEmpty ? baseline : released.last.sequence!,
    );
    if (released.isNotEmpty) {
      _committedRecoveryEvents[runtime] =
          List<SessionGatewayEvent>.unmodifiable(released);
    }
    return true;
  }

  bool isRecoveryAuthorityCurrent(
    RecoveryProof proof, {
    required int socketGeneration,
    required Object channel,
    required String? replayEpoch,
  }) =>
      identical(_committedRecoveryAuthorities[proof.runtimeSessionId], proof) &&
      proof.wasMintedBy(_recoveryAuthority) &&
      proof.isStructurallyAuthoritative() &&
      proof.socketGeneration == socketGeneration &&
      identical(proof.channelIdentity, channel) &&
      proof.replayEpoch == replayEpoch &&
      !isQuarantined(proof.runtimeSessionId);

  bool canCommitRecovery(
    RecoveryProof proof, {
    required int socketGeneration,
    required Object channel,
    required String? replayEpoch,
  }) {
    final transaction = _recoveryTransactions[proof.runtimeSessionId];
    if (_resourceOverflowed ||
        transaction == null ||
        transaction.poisoned ||
        !_outstandingRecoveryProofs.contains(proof) ||
        !proof.wasMintedBy(_recoveryAuthority) ||
        !identical(proof.transactionIdentity, transaction.identity) ||
        !proof.isStructurallyAuthoritative() ||
        proof.socketGeneration != socketGeneration ||
        proof.replayEpoch != replayEpoch ||
        !identical(proof.channelIdentity, channel) ||
        transaction.socketGeneration != socketGeneration ||
        transaction.replayEpoch != replayEpoch ||
        (transaction.channel != null &&
            !identical(transaction.channel, channel)) ||
        transaction.connectionId != proof.connectionId ||
        transaction.durableSessionId != proof.durableSessionId ||
        transaction.profile != proof.profile ||
        transaction.bindGeneration != proof.bindGeneration ||
        transaction.sessionGeneration != proof.sessionGeneration ||
        transaction.turnGeneration != proof.turnGeneration ||
        !isQuarantined(proof.runtimeSessionId) ||
        proof.postSnapshotSequence == null ||
        proof.postSnapshotSequence! <= 0) {
      return false;
    }
    final baseline = proof.postSnapshotSequence!;
    var expected = baseline + 1;
    for (final event in transaction.held) {
      final sequence = event.sequence;
      if (sequence == null) return false;
      if (sequence <= baseline) continue;
      if (sequence != expected) return false;
      expected += 1;
    }
    return true;
  }

  _RecoveryTransaction? _recoveryTransactionFor(
    String runtime, {
    int? socketGeneration,
    Object? channel,
    String? replayEpoch,
  }) {
    final existing = _recoveryTransactions[runtime];
    if (existing != null) return existing;
    final known = <String>{
      ..._quarantine,
      ..._watermarks.keys,
      ..._transactions.keys,
      ..._recoveryTransactions.keys,
    };
    if (!known.contains(runtime) && known.length >= maxTrackedRuntimes) {
      _poisonAllForResourceOverflow();
      return null;
    }
    final transaction = _RecoveryTransaction(
      runtime: runtime,
      socketGeneration: socketGeneration,
      channel: channel,
      replayEpoch: replayEpoch,
    );
    _recoveryTransactions[runtime] = transaction;
    return transaction;
  }

  void _poisonWireMismatches({
    required int generation,
    required Object channel,
    required String epoch,
  }) {
    for (final transaction in _recoveryTransactions.values.toList()) {
      if ((transaction.socketGeneration != null &&
              transaction.socketGeneration != generation) ||
          (transaction.channel != null &&
              !identical(transaction.channel, channel)) ||
          (transaction.replayEpoch != null &&
              transaction.replayEpoch != epoch)) {
        _poisonRecovery(transaction);
      }
    }
  }

  void _poisonRecovery(_RecoveryTransaction transaction) {
    if (!transaction.poisoned) {
      _totalHeldEvents -= transaction.held.length;
      transaction.held.clear();
      transaction.poisoned = true;
    }
    _committedRecoveryEvents.remove(transaction.runtime);
    _committedRecoveryAuthorities.remove(transaction.runtime);
    _outstandingRecoveryProofs.removeWhere(
      (proof) => proof.runtimeSessionId == transaction.runtime,
    );
    _quarantine.add(transaction.runtime);
  }

  void _poisonAllForResourceOverflow() {
    _resourceOverflowed = true;
    _quarantineAll = true;
    _quarantine.clear();
    _recoveryExceptions.clear();
    _watermarks.clear();
    for (final transaction in _transactions.values) {
      transaction.held.clear();
      transaction.closed = true;
    }
    _transactions.clear();
    for (final transaction in _recoveryTransactions.values) {
      transaction.held.clear();
      transaction.poisoned = true;
    }
    _recoveryTransactions.clear();
    _outstandingRecoveryProofs.clear();
    _committedRecoveryEvents.clear();
    _committedRecoveryAuthorities.clear();
    _totalHeldEvents = 0;
  }

  void _recordWatermark(String runtime, int sequence) {
    _watermarks.remove(runtime);
    if (_watermarks.length >= maxTrackedRuntimes) {
      _poisonAllForResourceOverflow();
      return;
    }
    if (isQuarantined(runtime)) return;
    _watermarks[runtime] = sequence;
  }
}
