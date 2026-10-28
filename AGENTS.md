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

- This session's tool shell arrives with three gaps, and `flutter_tester` will not connect until
  all three are closed. None of them is a missing capability.
  **All three fixes and the `flutter test` call must happen in one shell invocation** — each bash
  call starts fresh, so an `export` in one call is gone by the next:
  1. **Proxy — injected, not missing.** `http_proxy`/`https_proxy` point at a localhost sidecar.
     `CODEBUDDY_SERVICE_PROXY_URL` is a sibling entry on a different port — do not use it as the
     proxy address. Dart's `HttpClient` honours those variables and ignores the Windows proxy
     bypass list, so it sends `flutter_tester`'s own VM-service WebSocket through the sidecar and
     the upgrade fails:
     ```bash
     unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
     export no_proxy=localhost,127.0.0.1,::1
     export NO_PROXY=localhost,127.0.0.1,::1
     ```
  2. **PATH — trimmed.** It arrives with a handful of entries and no PowerShell directory, so the
     tool reports `PowerShell executable not found`. `%SystemRoot%` is not set in this shell and
     `%…%` is cmd syntax, so it would be pasted as-is — write the path out:
     ```bash
     export PATH="/c/windows/System32/WindowsPowerShell/v1.0:$PATH"
     ```
     One guard to know about: this host rejects any command where `powershell` appears as a
     **standalone word**, in any capitalisation (`PowerShell.exe` is rejected just like
     `powershell.exe`). A path segment is not a standalone word, so
     `/c/windows/System32/WindowsPowerShell/v1.0` is safe to write out.
     Do **not** prepend `System32` itself: it shadows GNU `timeout`/`find` with the Windows
     binaries (`timeout` then fails with "无效语法。默认选项不允许超过 '1' 次").
  3. **Env vars — these really are missing.** `LOCALAPPDATA`, `ProgramFiles`, `ProgramFiles(x86)`,
     `ProgramData`, `ComSpec` are absent (`APPDATA` and `USERPROFILE` are still there). pub stops
     with `No pub cache` then `%PROGRAMFILES(X86)% not found`. `ProgramFiles(x86)` contains
     parentheses and bash refuses it (`export: not a valid identifier`), so build the env in python
     and launch flutter from that same process:
     ```python
     import os
     env = dict(os.environ)
     env.update({
         "LOCALAPPDATA":      os.path.join(env["USERPROFILE"], "AppData", "Local"),
         "ProgramFiles":      r"C:\Program Files",
         "ProgramFiles(x86)": r"C:\Program Files (x86)",
         "ProgramData":       r"C:\ProgramData",
         "ComSpec":           r"C:\Windows\system32\cmd.exe",
     })
     ```
     `USERPROFILE` is still set, so derive `LOCALAPPDATA` from it rather than hardcoding a user
     name — a literal `C:\Users\<user>\…` is not a real path and pub keeps failing.
     It has to be the same process: setting `$env:X` from the PowerShell tool does not reach a
     later bash run, which is why "set it in PowerShell then run flutter in bash" fails.
     `TEMP`/`TMP` are already set — leave them.
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
  with `turnFailed` first). The test dates from `3fd569f` (1.2.10); the Spanish
  string it asserts was last touched in `977966f`. Treat it as a real open
  failure, not baseline noise. The other new one is a single
  `hosted_group_completeness_boundary_test.dart` case (`groups.list fails closed
  when its exact channel closes`): an earlier full run the same day ended at
  15551 / 68, so it is not reproducible every time — timing-shaped. The per-case
  names in that earlier run were lost (truncated log), so it is not pinned down
  further.
- The helper script writes its log as `flutter-<timestamp>.log`, so repeated runs do not overwrite
  each other. If you redirect `flutter test` yourself, do the same — one overwritten log already
  cost a re-run to recover the numbers.
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
