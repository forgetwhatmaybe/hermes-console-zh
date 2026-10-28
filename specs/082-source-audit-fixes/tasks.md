# Tasks and evidence ledger

Statuses refer to actual behavior; changed files are not closed defects. Detailed raw logs and synthetic harnesses are in the local source-audit task folder.

- [x] AUDIT: freeze current source, inspect three independent code areas, run initial RED probes.
- [x] REVIEW-PLAN: independent native review PASS_WITH_DEBT; sole LOW wording debt closed by requiring same-key retry after explicit unpersisted storage rejection.
- [x] T1-RED: primary rerun AUD-01/AUD-02 on real constructor + temporary SQLite; add storage failure variants and queue/busy controls.
- [ ] T1-FIX: atomically admit one worker; reconcile unpersisted keyed reservation; test same-key concurrent dedupe and rejected storage retry. Owner: server implementer.
- [ ] T1-GREEN: canonical Python 3.14 runner including prior RLock regression; concurrency fault injection and mutated old predicates must fail.
- [x] T2-RED: primary rerun held truncation and recovered request.cancel counterexamples; normal live path remains control.
- [x] T2-FIX: preserve unresolved control/tool frames, reject unsafe baseline, normalize all committed recovery events. Owner: replay implementer.
- [x] T2-GREEN: focused replay/transport suites plus mandatory reconnect/snapshot tests; exact request IDs and late-response behavior asserted.
- [x] T2-HELPER: add matching/mismatched/null epoch assertions for the unused snapshot binding helper, then replace self-comparison; do not connect new production callers.
- [x] T3-RED: primary rerun successor-draft deletion; independently add AUD-05b full-batch settlement tests before repair.
- [x] T3-FIX: clear only accepted batch A; preserve successor B's UI, encrypted text, attachments and identity even across awaits. Owner: draft implementer.
- [x] T3-GREEN: ACK before/after debounce, route disposal, automatic/manual settle, same text + new attachment, unchanged A controls; existing retry suites stay green.
- [x] T4-RED: production pure-Dart privacy counterexample and fake inner HTTP zero-dispatch assertion; additional real WebSocket connect RED.
- [x] T4-FIX: explicit literal parsing/ranges before local DNS rule and guard before WebSocket auth/socket creation. Owner: replay/privacy implementer.
- [x] T4-GREEN: IPv6 variant controls, HTTP/WS and HTTPS/WSS, public IPv4 and mapped literals; mutated broad no-dot predicate rejected.
- [ ] LIVE-01: correlate phone foreground/network state with paired 1006 disconnects; inspect proactive client close/reconnect rules; retain unresolved status if phone-side evidence missing.
- [ ] VERIFY: primary regression + `flutter analyze lib test`, compare failure names to existing baseline, update maps and architecture validation.
- [ ] REVIEW-FINAL: freeze source/diff/hash and obtain two independent native final reviews; fix HIGH findings and preserve original tickets.
- [ ] PRIVACY: scan new/modified artifacts and full relevant repository state; no credentials, private runtime data or generated binaries staged.
- [ ] DEPLOY: reviewed server backup/readback, dashboard-only restart and health/protocol checks; preserve gateway stopped. Client build only after all mandatory checks pass.

## Current evidence and closure status

| ID | Root cause / evidence | State | Required closing proof |
|---|---|---|---|
| AUD-01 | Idle check and claim split across lock scopes; two workers in deterministic barrier test | RED confirmed | single worker, second queued/busy, no overwritten identity |
| AUD-02 | 5072 unwind leaves keyed running entry; retry workers=0 | initial repair GREEN; cancellation closure open | recoverable same key and no phantom running |
| AUD-03 | validateReplay clears held before quarantine; text snapshot then accepted | primary GREEN, final review pending | held tool/control event protected and limits bounded |
| AUD-04 | committed recovery bypasses request.cancel normalization | primary GREEN, final review pending | expire/responded event and no orphan response |
| AUD-05a | pre-ACK visual release incorrectly authorizes unconditional draft clear | primary GREEN, final review pending | actual encrypted B survives |
| AUD-05b | text-only checks erase distinct attachment batch | primary RED then GREEN | both automatic/manual routes preserve new batch |
| AUD-06 | no-dot local hostname shortcut captures global IPv6 | primary HTTP/WS GREEN, final review pending | blocked before transport, private/secure controls pass |
| AUD-07 | unused helper compares epoch parameter with itself | primary GREEN, mutation rejected | same epoch allowed; changed/null epoch rejected |
| LIVE-01 | live process/health OK; repeated paired 1006 closes | investigating | discriminating phone/client/transport evidence |

## Verification update and reopened admission ownership

- Primary client regression: 463 passed, zero failed across all ten mandatory
  suites and six new focused files. Primary draft regression: 50 passed.
- `flutter analyze lib test`: three new test-only lint findings were corrected;
  the fresh full analysis reports `No issues found!`.
- Primary server regression before the final owner correction: 88 passed.
  This result does not close the additional cancellation race below.
- AUD-01R / HIGH: independent review reproduced Stop during persistence,
  followed by distinct-key B admission, then A's late success or failure.
  A's old registry entry still exists, so it cannot prove current session
  ownership. Primary rerun: three failures; final worker handoff as well as
  error cleanup must reject stale A. Repair and verification remain open.
- Retired owner/viewer tests use real ActiveChat: current empty recovery
  coverage can hold the live boundary, while terminal status and durable final
  text converge. Full-domain proof support is not a production-server claim.
- Known existing failures are retained: socket-close unhandled stream error
  reproduces on frozen/current source; the server deep-truncate fixture drops
  Windows thread arguments on both; the full server file exceeded its bounded
  timeout. Required focused regressions are separate from these baseline debts.
- LIVE-01 remains unproven. The server's old task has a pending `clarify`
  tool call and an unexpired turn lease. Restarting it now would interrupt that
  task; installation/restart is a separate final step after review.
- A8 / Stop closure: late provider interruption and request cleanup can hit B
  after A ends in a plugin hook. Primary RED reproduced B's interrupt flag and
  cancelled clarification. A counted Stop fence is being implemented across
  idle/busy and continuation paths; cancellation before worker entry and worker
  start exceptions must also release only their own slot. Preserve all earlier
  failed review probes and rerun the final lifecycle checks.
- Client 4095 compatibility: the complete idempotency suite passes 76 cases,
  including a new explicit retry proving stable identity and no unkeyed fallback;
  full analysis remains clean. This adds one distinct case to the earlier 513.


## User-directed closeout (2026-10-26)

User requested quota-saving handoff; no new audit expansion. Source frozen.
Client targeted total is 514 distinct passing cases; full analysis clean.
Primary final server admission rerun: 35 passed / zero failed. Earlier broader
regression and mutations are historical candidates, not final-source proof.

HIGH-1 remains open: busy claim -> Stop purge -> late queue commit. Primary
counterexample is RED. HIGH-2 remains open: the actual second inner prompt-turn
thread starts after Stop releases the slot and B enters; independent saved run
is RED, primary has read it but not rerun it. Preserve both tests/logs. The
correctness reviewer final response was platform-blocked; no final PASS ticket.
Safety review is BLOCKED. T1/REVIEW-FINAL/DEPLOY remain unchecked intentionally.

> **Superseded 2026-10-28 — the paragraph above describes the 2026-10-26 state.**
>
> The **server side** of HIGH-1 and HIGH-2 is closed in the backend repository: branch
> `fix/turn-admission-races-v2` (`a7b95a7`..`c23ef9680d`, patches 0001–0004 exported to the
> private `hermes-patches` repo). Both primary counterexamples are RED on the pre-fix source
> and GREEN after; 24 targeted suites report 294 passed / 2 skipped; independent read-only
> review rounds 1–8 ran (1–7 FAIL, each fixed and re-reviewed; 8 PASS with no HIGH), plus a
> ninth PASS round covering the round-8 MEDIUM items. Deployed on the
> dashboard host (2026-10-27 20:42, commit `c23ef9680d`).
>
> **Still true for 082 itself**: this spec's own REVIEW-FINAL has no PASS ticket, and its
> T1-FIX / T1-GREEN / VERIFY / DEPLOY checkboxes stay open until the client half is rerun.
>
> Client-side items still open:
> - **T1-FIX / T1-GREEN** — the client half has not been rerun RED→GREEN. `flutter test`
>   cannot start in this environment (`flutter_tester` needs `PowerShell.exe` and `wsl.exe`,
>   both blocked), so there is no client test evidence for this batch.
> - **VERIFY** — `flutter analyze lib test` is clean (`No issues found`); `flutter test` was
>   not executed. Compare by failure NAME once a working runner is available.
> - **DEPLOY** — server deployed on the dashboard host. No APK rebuild: this work does not change the
>   client protocol, so the existing build remains valid.
>
> Cross-repo plan and remaining items: `docs/PLAN-2026-10-28-cross-repo.md`.

Privacy scanner covered both worktrees/indexes plus 2 Console and 3 backend
pending commits, with zero newly introduced task-sensitive matches at scan time.
Existing findings are debt. Latest APK 20023 is a local candidate; backend was
not restarted because its old real task is waiting for clarify. Canonical
current state: docs/HANDOFF-2026-10-26-source-audit-closeout.md.
