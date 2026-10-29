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
| 1 | kanban half-delivered claims lost events | **DONE, committed** | commit `a98c30ece5` in the server repo; patch `0006` in the patch repo; segmented receipts in `session_notifications.py`; `test_half_delivered_claim_rewinds_only_the_refused_half` (RED→GREEN) + `test_trailing_silent_event_rewinds_to_the_full_claim_endpoint`; 8 passed on the file, 73 across 7 related files; Codex FAIL(1×P2)→fix→PASS; mutation check done |
| 2 | `session_authority` unconsumed | **NOT STARTED — blocked on product** | server fills it from the same `missing` variable as `truncated`, so wiring it today is dead code |
| 4 | Queued-message steer/replace has no UI | **NOT STARTED — decided not to build** | local queue already covers the case; server FIFO only holds work when another owner holds the session |
| 6 | `specs/082` process tickets | **OPEN — verification gap, not an unfixed defect** | `specs/082-source-audit-fixes/tasks.md` records the server-side T1 fixes as reviewed and deployed at `c23ef9680d`; the unchecked `T1-FIX`/`T1-GREEN` boxes are this spec's **client-side verification** still outstanding, not a live double-send race. `LIVE-01` is genuinely unresolved: paired 1006 disconnects with phone-side recovery unproven |
| 7 | 8 Windows-only test failures | **WILL NOT FIX** | `AGENTS.md` forbids fixing them in an unrelated change; CI (ubuntu) reports 0 failures for the same suites |
| 8 | One timing-shaped flake | **WILL NOT FIX** | same code passed and failed in two full runs |
| 9 | SBOM freshness gate relaxed | **NOT STARTED — needs Linux** | `generate.py` shells out to `android/gradlew` (POSIX script); cannot be generated on Windows |

**Net:** 4 of 9 closed (1, 3, 5 and the 8-item baseline is excluded). 2 are product
decisions. 3 are deliberately out of scope or blocked.

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

## Item 1 in detail (done — kept for the rationale)

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

## What to do next (priority)

`AGENTS.md` § *Fix priority — user-visible first* is the ranking.

Still open **and user-visible**:
- `LIVE-01` — paired 1006 disconnects; whether the phone recovers on its own is
  unproven. A dropped connection the app does not come back from is category 2
  (stuck state) in the ranking above.
- `#6 / T1-FIX` — but read the row above first: the server fix is deployed, so
  what is open is verification, not a known race. Treating an unticked box as a
  live defect would send the next implementer into already-repaired code.

Still open **and invisible**: `#2` has no consumer, `#4` is a multi-device
convenience, `#9` is compliance, `#7`/`#8` are local test noise.

Before touching anything, ask the ranking question: *can the person holding the
phone feel this?* If no, it waits behind anything that is yes.

## Tried and reverted — do not repeat

**2026-10-29**: added silent retries around the first read of a conversation
(`_fetchWithRetry`, 600 ms then 1800 ms, only when `_error` was set). Codex
reviewed it and caught a real race (a manual Retry pressed during the delay
would be superseded by the automatic one); that was fixed, review passed.

**It broke 15 tests.** `chat_screen_test.dart` went from 812 passed / 8 failed
to 797 / 23. The failures were not incidental:

- `404 de sesion persistida muestra error estable y permite reintentar`
- `fallo de apertura fria muestra error aunque hidratacion siga pendiente`
- `Bot Chat desbloquea composer al publicar tras dos fallos aunque resume siga pendiente`
- `Bot Chat recupera foco y texto tras fallar y reintentar`

Those four assert the product contract: **a failed open must show the error and
offer retry immediately**. An automatic retry delays or erases `_error`, so the
contract breaks. "Show the error, let the person press Retry" is deliberate, not
a missing retry.

Reverted in full (`git checkout -- lib/core/screens/chat_screen.dart`). If this
is revisited, the fix has to reduce the *failure rate*, not hide the failure:
the open question is why the first read fails at all. Candidates from the code
read: hydration not finished when a non-empty session answers with empty
history, or a transient transport error. Both need one failing device log — the
log distinguishes them, guessing does not.

## Owner decisions

- **2026-10-29**: `#6 / T1-FIX` is **not being changed** right now — there is no
  multi-phone usage at present. The verification gap stays recorded above; do
  not reopen the server code for it without a concrete trigger (a second device
  in use, or a reproduced double-send).
- **2026-10-29**: `#9` SBOM stays `continue-on-error`. Only the diff logging
  landed (`deb34e1`); regenerating the SBOM is not worth CI minutes while it has
  no effect on what the person using the app sees.

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
