# Source audit repair implementation plan

> For agentic workers: use subagent-driven-development task by task. Preserve the existing owner authorization; execute the reviewed plan directly.

**Goal:** Fix the reproducible admission, recovery, draft and privacy defects and investigate the ongoing phone disconnect.

**Architecture:** Keep the current Flutter state/transport layers and Python session engine. Repair ownership decisions at their source; keep persistence before acknowledgement and dispatch normalized events through the existing boundary. Independent files may proceed concurrently; shared Flutter verification is serialized.

**Tech stack:** Flutter/Dart (installed toolchain), Python 3.14 PM-managed test environment, canonical Hermes test runner.

**Spec:** [spec.md](spec.md). **Tasks:** [tasks.md](tasks.md).

## Global constraints

All spec constraints apply. Implementers own only their assigned production/test files. The primary agent controls Git, deployment and acceptance; no agent independently commits, pushes or restarts a service. Production source edits do not authorize a live process to reload until checks pass.

## Review focus

1. Atomic admission must cover queue, unkeyed callers, storage failure, worker start failure and cancellation races, without dropping a durable accepted turn.
2. Replay fixes must cover truncation, invalid batches, transport retirement and capacity bounds; never regress generation/epoch rejection.
3. Recovered cancellation must clear the pending request registry and preserve approval ID translation, not merely rename the UI event.
4. Draft fixes must cover post-ACK/pre-debounce, post-debounce, attachment-only work and edits made during awaited cleanup.
5. IPv6 parsing must cover compressed/expanded literals, mapped IPv4, brackets and private addresses; no network in boundary tests.

## Work order and deliverables

- P0 diagnostic lane: investigate LIVE-01 using local health, service identity, timestamped WS close logs and local Tailscale/ADB availability. Do not prescribe a network/power fix without evidence. Coordinate any resulting source fix as a separate enumerated defect.
- T1 server admission: `tui_gateway/methods_prompt.py` and behavioral tests in the server repository. Make idle admission atomic and unwind only proven unpersisted keyed reservations. The single implementer owns both issues because they share the same state transitions.
- T2 replay/cancel: `replay_coordinator.dart`, `tui_gateway_client.dart` and focused tests. Retain or poison failed held replay without authorizing an unsafe snapshot; route committed events through normal dispatch semantics.
- T2 also fixes the isolated `ViewerTurnSnapshotBinding.isCurrent` epoch self-comparison in `replay_snapshot_boundary.dart`, with a matching/mismatched/null epoch test. It remains outside the live caller graph; do not wire it in as part of this repair.
- T3 draft ownership: `chat_screen.dart` and focused widget tests. Preserve successor drafts and compare complete batch identity across both automatic and manual settlement. Keep new batches recoverable; avoid silently consuming a Send gesture as a successful send of a different batch.
- T4 transport boundary: `transport_privacy.dart` and network-policy tests. Parse IP literals before the single-label DNS compatibility case.
- The IPv6 cleartext allow-list is loopback `::1/128`, unique-local `fc00::/7` (including Tailscale), and link-local `fe80::/10`; mapped IPv4 uses the existing IPv4 policy. Global, unspecified and multicast addresses are rejected. Preserve existing local DNS names and secure URL handling.
- T5 acceptance/documentation: update code-map locations and architecture validation notes, then run required suites, mutation checks for changed decisions, frozen-source independent review from two lenses, and privacy scan.

## Verification commands

Console: unset all proxy variable variants before the absolute installed `flutter.bat test` / `flutter.bat analyze lib test` invocations. Run new focused REDs, then GREEN plus the ten mandatory chat/idempotency/recovery/status suites listed in AGENTS.md. Existing broader failures are compared by name and must not be hidden.

Server: use the installed Python 3.14 PM-managed test interpreter through `scripts/run_tests.sh`, with an isolated `HERMES_HOME`/runtime directory, bounded file timeouts and retained logs. Run new admission tests and prior lock/idempotency/retirement/submit/cancel suites.

Primary agent reruns key behavior tests, not merely reads sub-agent summaries. New RED tests must fail on the frozen prior implementation. Mutation checks restore the faulty predicate in an isolated copy or in memory, never alter the live source during tests.

## Deployment and rollback

After reviews and green required regressions: retain exact prior bytes and SHA receipt, restart only dashboard if server fixes landed, verify health and a synthetic protocol check. Build the existing full release APK lane only if client fixes pass; no upload/public release is implied. Keep old APK and server backups. Phone functional verification remains separately visible if unavailable; do not call health-only success a recovered conversation.

## Evidence-driven cancellation closure

Independent review and primary RED runs exposed the same ownership gap on
late storage success/failure, worker startup failure, Stop's stale liveness
observation, cancellation before worker entry, and delayed provider/request
cleanup. Treat admission through Stop cleanup as one lifecycle.

Use a counted Stop fence under the existing history lock. Set the cancellation
latch at entry, keep provider/plugin/request side effects outside that lock,
and release only the current Stop's count in `finally`. While the count is
nonzero, idle and busy prompt paths refuse new keys using the existing busy
response, without queueing, steering or consuming an idempotency identity.
Known-key receipts remain readable. The shared admission gate also covers
queue drain, goal continuation and notification; direct compression and
compute-child start must respect the same fence. Auto continuation retains
its existing cancellation-latch guard.

Tests must show both Stop/worker orderings, overlapping Stop calls, exceptional
cleanup, preserved queue envelopes, and successful post-Stop retry with a clean
provider interrupt state and an intact new clarification request. A dead or
cancelled worker cannot leave a phantom running snapshot, and cleanup cannot
release a different admission or manual compaction. New conditions join the
isolated mutation checks and both independent review scopes.
