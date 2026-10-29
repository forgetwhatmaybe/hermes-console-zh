# Repair backlog — what is still broken

Last updated: 2026-10-28, at `e7c8b9b` (the commit that made `Code Quality Checks`
pass for the first time in this fork's history).

This file lists **open** work only. Fixed items live in
`docs/PLAN-2026-10-28-cross-repo.md` and in the git log.

A machine-local companion (`docs/HANDOFF-*.md`, gitignored by design) carries the
per-machine tooling traps — proxy ports, runner quirks, review-CLI invocation.
Ask the owner for it if you are working on the machine that produced this file;
the items below are complete without it.

---

## P1 — real defect, expensive to fix

### 1. kanban half-delivered claims still lose events (server)

**Where**: `tui_gateway/session_notifications.py`, around `_kanban_rewind_claims`.

**Symptom**: one claim spans the diagnostic half and the result half of a text.
If one half was delivered and the other hit the refusal limit (3), that claim
range is **not** rewound — rewinding would replay the delivered half as a
duplicate. The refused half's events are lost for good.

**Current mitigation**: the drop log says
`N claimed range(s) stay advanced and their events are lost`. Visible, not
fixable from there.

**Root fix**: move the claim granularity from "range" to "event id". It changes
the claim protocol (`kanban_db_notify.py`'s `_cas_cursor` and
`rewind_notify_cursor` semantics), so it is a large change: spec + two votes.

**Acceptance**: build the "half delivered, half refused" case and assert that a
retry neither loses nor duplicates.

### 2. `session_authority` is not consumed (client)

**Where**: the replay proof (`lib/core/services/replay_batch_proof.dart`).

**Why it was skipped**: the server fills it from the same `missing` variable as
`truncated`, so today the two are always equal and wiring it buys nothing. There
is also no consumer, so it would be dead code.

**When to do it**: after the server makes the two diverge — `truncated` meaning
"cut short", `session_authority` meaning "re-fetch the snapshot".

**Acceptance**: with the server split in place, the client re-fetches on
`session_authority` alone and does not on `truncated` alone.

---

## P2 — worth doing, not urgent

### 3. `Failure summary` overflows the 1 MB step-summary limit — FIXED 2026-10-29 (working tree, uncommitted)

**Where**: `.github/workflows/pr-quality.yml`, the `Failure summary` step.

**Was**: the whole `test_output.txt` was written into `$GITHUB_STEP_SUMMARY`:

```
$GITHUB_STEP_SUMMARY upload aborted, supports content up to a size of 1024k, got 3842k
```

So when tests failed, the summary page was blank — exactly when you need it.

**Fix (applied, revised same day)**: the step emits a short header, the failing
test names, and each failure's real diagnostic: for widget/golden failures the
exception block printed BEFORE the `[E]` marker (after it Flutter only says
"Test failed. See exception logs above."), for ordinary matcher failures the
Expected/Actual paragraph after `[E]` (600 chars; exception blocks get 1600).
Blocks are attributed by the progress-message name in effect above the
banner (continuation banners inherit the name still in effect); a block is
claimed only at the `[E]` of that same test — with a frame check for wrapped
names and a failure-counter check (`-M` increments once per failed test at
the exception) for ownerless preamble blocks — so a passing test's planted
exception (`rowerr/chat_row_boundary_test.dart` seeds "Bad state: x" blocks
that sit right above an unrelated `[E]` in interleaved logs) is never pinned
on the wrong failure, and duplicate `[E]` emissions of one test yield one
bullet. A
capped 60-line tail covers no-`[E]` runs (compile/load errors); the markdown
hard-caps at 900 KB (1 KB reserved for the truncation note, which is appended
outside the block budget) with a note that the full log is in the job log.
The `if:` condition and the analyze/test reporting are unchanged; no other
step touched. Intermediate versions of this fix kept only the post-`[E]`
paragraph (discarding the actionable diagnostic for 25 golden/widget failures
in the real full-test log) and attached blocks by position alone (mis-attaching
a passing test's planted exception to `rt1215_tertiary_guard_test`); both
caught in review, fixed same day.

**Verified** (2026-10-29): the embedded script was extracted from the YAML and
run against the real full-test log (`D:\tmp\full-test4.log`, 72 failures /
73 `[E]` emissions incl. one duplicate): 72 unique bullets = 72 failures, 25
exception-attached + 29 matcher + 18 other raw-thrown paragraphs, 0 bare
"See exception logs above." pointers, exception-attached set exactly equals
the set of tests whose `[E]` is followed by the pointer line (symmetric
difference 0); `rt1215_tertiary_guard_test` shows its own `Expected: empty`
matcher failure, not the planted "Bad state: x" block. A 3,500-failure ~4 MB
synthetic log produced 920,456 bytes (under the 900 KB cap, note appended);
missing/empty/no-`[E]`/both-pass paths pass; YAML parses, 17 steps.

**Acceptance**: a failing run produces a readable summary under 1 MB — met by
construction; the first real failing CI run confirms it on GitHub's side.

### 4. Queued-message steer/replace has no UI (decided: do not build)

**Where**: `lib/core/services/tui_gateway_client.dart` defines
`steerQueuedPrompt` / `replaceQueuedPrompt`; they have **no production caller**
(the only reference is the params-shape assertion in
`test/queued_admission_control_test.dart`). `admission_id` is unused in
`active_chat_service.dart`.

**Why it was dropped**: `_drainQueue` is gated on `isStreaming` (line 26581)
and drains one entry at a time, so queued messages spend **most of their life in
the local queue**, where `steerQueuedTurnWithOutcome` already works. The server
FIFO only holds anything when *another owner* holds the session (multi-device),
and "edit a queue that lives on device B from device A" has no defensible UX.

**Revisit if**: the product decides to support cross-device queue management.
That needs `send(queued: true)` to return the `admission_id` it currently drops.

### 5. `FakeProc.poll` leaks across tests (server)

**Where**:
`tests/tui_gateway/test_kanban_core_functionality.py::test_gateway_dispatcher_disables_corrupt_board_without_traceback[sqlite|guard]`.

**Symptom**: passes when the file runs alone; fails when run in file order after
earlier cases, with `AttributeError: 'FakeProc' object has no attribute 'poll'`
at `kanban_db_dispatch.py:286` — line ~2898 leaks the fake into the module-level
`_live_worker_procs`.

**Fix**: a fixture that clears `_live_worker_procs` around those cases.

**Acceptance**: the whole file runs in order with zero failures.

### 6. `specs/082-source-audit-fixes` process tickets

Still unchecked in `specs/082-source-audit-fixes/tasks.md`:

| Ticket | Scope |
|---|---|
| `T1-FIX` / `T1-GREEN` | **Server**: admit one worker atomically, reconcile an unpersisted keyed reservation; Python 3.14 runner, concurrency fault injection |
| `LIVE-01` | Correlate phone foreground/network state with paired 1006 disconnects |
| `VERIFY` | Primary regression + `flutter analyze lib test` + compare failure names to baseline |
| `REVIEW-FINAL` | Freeze source/diff/hash, two independent native final votes |
| `PRIVACY` | Full scan of new and modified artifacts |
| `DEPLOY` | Server backup/readback, dashboard restart, protocol checks |

`T1-*` are server-side and do not live in this repository.

---

## P3 — known, deliberately not fixed

### 7. The Windows-only test baseline

`test/chat_screen_test.dart` is 812 passed / 8 failed locally, and the full suite
is 70 failed — **all Windows-shaped** (golden fonts, pending timers, temp-dir
cleanup, real-socket timing). **On CI (ubuntu) the same suites report 0
failures.** `AGENTS.md` says explicitly: do not fix them in an unrelated change,
and never regenerate a golden to make a suite pass.

### 8. One timing-shaped flake

`hosted_group_completeness_boundary_test.dart`: `groups.list fails closed when
its exact channel closes` passed in one full run and failed in another on the
same code. Not a regression.

### 9. SBOM freshness gate is relaxed

Step 12 (`Verify source SBOMs are fresh`) is `continue-on-error`. To restore it:
run `./tool/sbom/generate.sh` on **Linux with a JDK and the Android SDK**, commit
the output, then delete that line. Do **not** generate it on Windows —
`generate.py` shells out to `android/gradlew`, which is a POSIX script, and the
resulting diff would be wrong for the wrong reason.

---

## Suggested order

1. **#3** (15 min, CI config only) — otherwise the next failure is invisible
2. **#5** (30 min, fixture cleanup) — removes a permanent red spot
3. **#1** (half a day or more) — the only real data-loss risk left
4. #4 / #2 wait on product decisions
5. #6 as needed
