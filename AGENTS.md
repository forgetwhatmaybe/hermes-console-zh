# Agent release boundaries

Read `docs/PROJECT_BRIEF.md`, `docs/SECURITY_POLICY.md` and
`docs/RELEASE_DISTRIBUTION.md` before changing release or distribution files.

## Non-negotiable channel separation

- Google Play accepts only the signed `play` AAB. Never commit it, attach it to
  a GitHub Release, or upload it as a public workflow artifact.
- GitHub Releases and Obtainium accept only signed `full` release APKs. Never
  publish `play`, `qa`, `debug` or `profile` artifacts there.
- The `qa` flavor is internal emulator-test evidence and must never be public.
- Never commit or expose `key.properties`, keystores, passwords, tokens,
  mappings, diagnostic bundles, pairing payloads or private server details.
- Build outputs stay ignored. A request to build does not authorize upload,
  publication, tagging, repository visibility changes or Play submission.
- Every publication action requires explicit owner approval for that exact
  channel and artifact.

Use path-specific staging; never use `git add -A` or a broad recursive stage in
this repository.

## Review channel (owner directive, 2026-10-26)

- Every independent review of this repository runs on the Codex CLI with
  `-m gpt-6-astra` and `-c model_reasoning_effort="max"`.
  ```bash
  # Proxy host/port and the tool paths below are this Windows + Git Bash
  # machine's; on another machine keep the model/effort flags and adapt them.
  HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897 \
    codex exec --ephemeral --sandbox read-only --skip-git-repo-check \
    -m gpt-6-astra -c model_reasoning_effort="max" \
    --output-last-message <verdict.txt> - < <request.txt>
  ```
- `max` is a valid effort level for this model (an invalid value is rejected
  by the API, which is how the setting is confirmed to reach the request).
- A review counts only from the real final message of that run. `FAIL` blocks
  the change until fixed and re-reviewed; a malformed or empty verdict is not a
  pass. Do not swap model or channel without the owner saying so in the task.

## Architecture (map: `docs/ARCHITECTURE.md`, contract: `docs/UPSTREAM_CONTRACT.md`)

- One Flutter Android client. There is no Console backend: the phone talks only
  to the Hermes servers the person adds, plus the optional downloads (pets,
  voice models) that carry no conversation data.
- The Hermes Dashboard is the protocol contract; the client copy lives in
  `docs/UPSTREAM_CONTRACT.md`. A contract change lands in both, in one change.
- Live turns use the Desktop gateway (`/api/ws` JSON-RPC); REST serves history,
  files and admin. Do not add a second source of truth for a turn.
- Reconnect invariants: the client's transport-recovery durable-read epoch
  (`transportRecoveryDurableReadEpoch`) increases on every recovery edge, while
  the server's `replay_epoch` is a string compared for equality and never reset
  by the client; a durable read while a viewer streams may only add rows, never
  replace them; an own turn never reads durable mid-turn; a snapshot
  continuation is adopted only after the whole snapshot was applied, and a
  refused snapshot keeps the watermark, the held frames and the quarantine.
- Send path: one logical turn carries one `client_turn_id`; never drop it on an
  ambiguous failure, or the retry opens a second turn.
- `voice/` and the CJK STT paths are out of scope for unrelated changes.

## Testing

- Run with the proxy unset, or `flutter_tester` fails the WebSocket upgrade:
  ```bash
  export -n http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
  /c/flutter/bin/flutter.bat test <files>
  /c/flutter/bin/flutter.bat analyze lib test
  ```
- `flutter analyze lib test` must report `No issues found!`.
- Known baseline on this Windows machine, measured at `1.3.2+20018`
  (2026-10-26): full `flutter test` = 15412 passed / 72 failed / 16 skipped
  (`D://tmp//full-test4.log` here; keep the log next to the release). The
  failures outside the suites below are environment-shaped — golden fonts,
  pending timers, Windows temp-dir cleanup, real-socket timing — and none of
  the suites below is among them. Compare by failure NAME, not by count: do not
  regenerate a golden to make a suite pass.
- Baseline inside `test/chat_screen_test.dart`: 8 failures (generated image
  cache, in-flight media ownership, official producer paths, App Lock
  prefetch, two Galería dedupe cases). Do not "fix" them as part of an
  unrelated change.
- Suites that must stay green when touching chat, sending, reconnection or the
  status line: `turn_idempotency_contract_test`, `duplicate_send_repro_test`,
  `live_status_single_line_test`, `chat_replying_1215_test`,
  `ct1215_turn_in_transcript_test`, `truncated_replay_snapshot_boundary_test`,
  `viewer_truncated_replay_test`, `desktop_disconnect_recovery_test`,
  `console_desktop_transcript_reconcile_test`,
  `transport_recovery_durable_read_test`.
- A test that encodes the old UI contract is updated with the same change that
  moves the contract; it is never weakened to `findsWidgets` to go green.

## Docs map (read before a first change)

- `docs/CODE_MAP.md` — entry point: layers, one message end to end,
  invariants, change manual (which files and which suites for each kind of
  change), and the known traps.
- `docs/_map/chat_core.md` — sending/idempotency, replay and durable recovery,
  outbox, invariants with line numbers.
- `docs/_map/ui_layer.md` — render pipeline, status line and token footer,
  error bubble.
- `docs/_map/integrations.md` — notifications, voice/media, bots, cron, and the
  full user-visible error-string table.
- `docs/ERROR_STRINGS.md` — localization batches and status.
- Keep these in sync with the code in the same change that moves the contract;
  stale line numbers are a bug in the map.

## Active source-audit repair (2026-10-26)

- Current owner-authorized scope and acceptance: `specs/082-source-audit-fixes/`.
- Native sub-agent reviews are explicitly authorized for this task by the owner.
- Admission (server), replay transport, composer drafts and transport privacy
  have separate implementers; shared Flutter test execution is serialized.
- Preserve pre-existing working changes. Primary agent reruns behavior tests,
  verifies source hashes, and alone controls deployment/Git. Live phone recovery
  is a separate acceptance item from health checks and isolated test success.
