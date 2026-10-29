# Repair progress — where everything stands

Single source of truth for "what is done, what is not, and what proves it".
Companion to `docs/REPAIR_BACKLOG.md` (which lists the *items*; this file records
their *state*). Update this file whenever an item changes state.

Last updated: 2026-10-29 10:30 (Asia/Shanghai).

---

## One-page status

| # | Item | State | Proof |
|---|---|---|---|
| 3 | `Failure summary` overflowed the 1 MB step-summary cap | **DONE, pushed** | commit `bff0591`; Codex ticket (PASS); parser verified against the real full-test log: 72 unique failures, 25 attached exception diagnostics |
| 5 | `FakeProc.poll` leaked across tests | **DONE, committed** | commit `14f6cdcec6` in the server repo; 22 passed / 0 failed / 2 skipped on the whole file; Codex ticket (PASS); patch `0005` in the private patch repo |
| 1 | kanban half-delivered claims lost events | **CODE DONE, uncommitted** | segmented receipts in `session_notifications.py`; `test_half_delivered_claim_rewinds_only_the_refused_half` (RED→GREEN) + `test_trailing_silent_event_rewinds_to_the_full_claim_endpoint`; 73 passed / 0 failed across 7 related files; Codex FAIL(1×P2)→fix→PASS; mutation check done |
| 2 | `session_authority` unconsumed | **NOT STARTED — blocked on product** | server fills it from the same `missing` variable as `truncated`, so wiring it today is dead code |
| 4 | Queued-message steer/replace has no UI | **NOT STARTED — decided not to build** | local queue already covers the case; server FIFO only holds work when another owner holds the session |
| 6 | `specs/082` process tickets | **NOT STARTED — out of nightly scope** | `T1-*` are server-side |
| 7 | 8 Windows-only test failures | **WILL NOT FIX** | `AGENTS.md` forbids fixing them in an unrelated change; CI (ubuntu) reports 0 failures for the same suites |
| 8 | One timing-shaped flake | **WILL NOT FIX** | same code passed and failed in two full runs |
| 9 | SBOM freshness gate relaxed | **NOT STARTED — needs Linux** | `generate.py` shells out to `android/gradlew` (POSIX script); cannot be generated on Windows |

**Net:** 3 of 9 closed. 1 awaits one commit. 2 are product decisions. 3 are
deliberately out of scope.

---

## Where the code lives

| Repo | Role | Remote |
|---|---|---|
| `hermes-console` | Flutter client (this repo) | `forgetwhatmaybe/hermes-console-zh` |
| server repo | Python gateway / dashboard | `NousResearch/hermes-agent` (upstream — **never push here**) |
| patch repo | Private patch set for the server | `forgetwhatmaybe/hermes-patches` |

Server changes reach the patch repo as `patches/NNNN-*.patch` (`git format-patch`)
plus a `MANIFEST-*.md`. They are **not** pushed to upstream. Existing patches:
`0001` contracts, `0002` turn admission, `0003` round-8 mediums, `0004` docs +
usage ticker, `0005` FakeProc leak. The item-1 fix will be `0006`.

---

## Item 1 in detail (the one still open)

**Problem**: one claim spans the diagnostic half and the result half of a text.
If one half was delivered and the other hit the refusal limit, that range cannot
be rewound as a whole — rewinding replays the delivered half as duplicates, so
the refused half's events were lost.

**Fix**: the DB claim stays atomic (no change to `_cas_cursor` /
`rewind_notify_cursor`). The *receipt* is split into consecutive segments by
delivery class (diagnostic vs ordinary), and each segment rewinds on its own.
Half-delivered → the refused segment CASes back (nothing lost), the delivered
segment stays put (nothing replayed).

**Second defect found by review**: when a claim's tail carried silent events
(kinds that are claimable but produce no text), the last segment's
`claimed_cursor` was shorter than the real claim endpoint, so the rewind CAS
never matched and events still leaked. Fixed by extending the last segment to
the true claim endpoint.

**Uncommitted files** (server repo):
- `tui_gateway/session_notifications.py`
- `tests/tui_gateway/test_kanban_cursor_rewind.py`

---

## How to resume

1. `docs/REPAIR_BACKLOG.md` §「建议顺序」says what to do next.
2. This file says what is already done — do not redo it.
3. Every change needs a Codex ticket before push (`AGENTS.md` §Review channel).
   A sub-agent saying "codex passed" is not a ticket; run it yourself.
4. Server changes go to the patch repo, never to upstream.

---

## Known environment gaps (this machine)

These cost time twice already:

| Gap | Symptom | Fix |
|---|---|---|
| `ANDROID_HOME` unset | `No Android SDK found` | `C:\Android\Sdk` |
| `JAVA_HOME` points at JDK 8 | `Gradle requires JVM 17 or later` | JDK 17 at `~/.jdks/ms-17.0.18` |
| `run_repaired_env.py` undercounts tests | reports `+810 -10` where direct flutter says `+812 -8` | count failures via direct `flutter test`, not the wrapper |
