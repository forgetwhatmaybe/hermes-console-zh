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

- Three environment pieces must be repaired first, or `flutter_tester` never connects. All three
  are stripped by the agent sandbox, none of them is a missing capability:
  1. **Proxy** — Dart's `HttpClient` honours `http_proxy`, so `flutter_tester` sends its own
     VM-service WebSocket through it and fails the upgrade:
     ```bash
     unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
     export no_proxy=localhost,127.0.0.1,::1
     ```
  2. **PATH** — it arrives with only a handful of entries and no PowerShell directory, so the
     tool reports `PowerShell executable not found`. Prepend
     `%SystemRoot%\System32\WindowsPowerShell\v1.0`. Do **not** prepend `System32` itself: it
     shadows GNU `timeout`/`find` with the Windows binaries.
  3. **Variables** — `LOCALAPPDATA`, `APPDATA`, `USERPROFILE`, `ProgramFiles`, `ProgramFiles(x86)`,
     `ProgramData`, `ComSpec` are absent; pub stops with `No pub cache` then
     `%PROGRAMFILES(X86)% not found`. `ProgramFiles(x86)` contains parentheses and cannot be
     exported from bash — set it from python (or from the PowerShell tool).
  ```bash
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
- Re-measured at `1.3.2+20023` (2026-10-28, `4859884`): 15549 passed / 70 failed
  / 16 skipped. Diffed by name against the `+20018` log: 4 failures cleared, 2
  appeared. Of the two, `chat_screen_test.dart` "rechazo por owner conserva
  turno y bloquea reenvío hasta recheck" fails in isolation too (expected UI
  text `No se puede continuar en directo` never renders — the composer refuses
  with `turnFailed` first; both the test and the string date from `3fd569f`,
  1.2.10), while the two `hosted_group_completeness_boundary_test.dart`
  fail-closed cases are timing-shaped and did not reproduce on every run. Treat
  the first as a real open failure, not as baseline noise.
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

## Documentation and review gates (owner directive, 2026-10-28)

**Docs ship with the change.** Every finished task updates the documents it invalidated in the
same change — this file, `docs/ARCHITECTURE.md`, `docs/UPSTREAM_CONTRACT.md`, `docs/CODE_MAP.md`,
`docs/_map/*.md`, `docs/ERROR_STRINGS.md`, and the `specs/<NNN>/` state lines. A stale status line
("remains open", "BLOCKED", "do not deploy", an off-by-N line number) is a **defect**: it makes the
next reader — human or agent — act on a false premise. Write state as facts with evidence (commit
range, test counts, dates). Keep unfinished items visibly unfinished; a "done" summary must not
absorb them.

**Review before you touch, not only after.** Before editing, dispatch a read-only sub-agent to
review the current state *and* the proposed change: what the evidence actually proves, what the edit
would break, which neighbouring assumption it invalidates. Fix the plan first. This pre-check does
not replace the final independent review ticket — both gates apply — and no sub-agent self-report
counts as verification.

## Active source-audit repair (2026-10-26)

- Current owner-authorized scope and acceptance: `specs/082-source-audit-fixes/`.
- Native sub-agent reviews are explicitly authorized for this task by the owner.
- Admission (server), replay transport, composer drafts and transport privacy
  have separate implementers; shared Flutter test execution is serialized.
- Preserve pre-existing working changes. Primary agent reruns behavior tests,
  verifies source hashes, and alone controls deployment/Git. Live phone recovery
  is a separate acceptance item from health checks and isolated test success.
