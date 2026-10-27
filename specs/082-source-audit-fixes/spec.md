# 082 — Source audit fixes

Owner authorization: 2026-10-26, audit current source and directly repair confirmed defects; native sub-agent review is authorized. This supersedes the earlier planning-only scope. Preserve unrelated dirty work. No publication is included.

## Goal and scope

Restore correctness of prompt admission, reconnection, draft ownership and transport privacy on the current Console / Hermes Dashboard working trees. Diagnose the newly reported mid-use disconnect separately; do not call any discovered defect its cause without evidence.

Source baseline: Console `4e5fbdf` plus existing working changes; Hermes `a7b95a7` plus existing working changes (including the reviewed reentrant-lock repair). The local audit manifest freezes 2,709 source/test/doc files; detailed synthetic counterexamples live in the task evidence folder, outside Git.

## Required invariants and acceptance

- A1: One session has at most one executing user-turn worker. Distinct concurrent keyed submissions queue or receive the existing busy response; no overwritten live identity.
- A2: A rejected, unpersisted submission must not become a phantom accepted/running duplicate. Retrying its key after storage recovers safely admits exactly once; no permanent terminal rejection and no silent stuck state. Do not erase an already-durable admission on ambiguous failure.
- A3: Failed/truncated replay retains unrepresented held frames and quarantine. A text-only snapshot cannot authorize discarding tool/control events below its baseline. Capacity exhaustion stays fail-closed.
- A4: Every committed recovery frame undergoes the same request-cancel adaptation and request-registry cleanup as the ordinary live/replay path, with valid channel/generation metadata.
- A5: ACK or transcript settlement of batch A may clear only A's draft. A successor B, including attachment-only B or equal text with different attachments, remains visible and recoverable in encrypted storage. Compare complete batch ownership after awaits.
- A6: Public IPv6 HTTP/WS is rejected before network dispatch. Preserve HTTPS/WSS, current supported LAN/Tailscale/local addresses and consistent IPv4-mapped IPv6 treatment.
- A7: Live disconnect claims are evidence-bound: record process/health/WS timeline, investigate transport and client close paths, obtain phone-side evidence if needed. Server health alone does not prove chat recovery works.
- A8: Stop owns its cleanup through provider interruption and pending-request
  cancellation. New admissions cannot begin or receive a new queued receipt
  while any overlapping Stop cleanup remains in flight. Existing keys retain
  their receipts; after cleanup, a previously busy key may safely execute once.

## Constraints

- Keep a logical turn's `client_turn_id` stable on ambiguous outcomes. Do not change BUSY to clean rejection without upstream proof.
- Existing RLock construction and lock-order protections remain. No replacing a lock in a running session.
- No voice/STT refactor, no unrelated UI/l10n work, no broad god-file split.
- Tests use synthetic data and isolated server homes; never invoke a real model/tool or send real user prompts.
- Keep all pre-existing modifications; path-specific staging only. No commit/push/release without the applicable independent review and publication authorization.
- Server changes are applied and dashboard restarted only after regression and independent review; leave the intentionally stopped messaging gateway stopped.

## Observed issue ledger

| ID | Priority | Evidence before repair | Closure |
|---|---|---|---|
| AUD-01 | P1 | Real session fixture: two simultaneous different keys start two workers | A1 |
| AUD-02 | P1 | Storage returns 5072; retry says duplicate/running with zero workers and zero user rows | A2 |
| AUD-03 | P2 | Pure Dart production coordinator: truncated replay erases held tool.start then adopts baseline | A3 |
| AUD-04 | P2 | Real transport + fake socket: recovered cancel emits raw request.cancel and permits orphan reply | A4 |
| AUD-05a | P1 | Widget RED: A ACK leaves B on screen but erases B encrypted draft | A5 |
| AUD-05b | P1 | Primary widget RED reproduced text-only settlement deleting successor attachment batch and consuming a new Send gesture | A5 |
| AUD-06 | P1 | Production guard permits global IPv6 HTTP and WS; public IPv4 control blocked | A6 |
| AUD-07 | P3 | Unwired snapshot-binding helper compares incoming epoch with itself | different epoch must refuse; no claimed live impact |
| LIVE-01 | investigating | Dashboard healthy; phone sockets repeatedly close 1006 together | A7 |

Audit findings are not proof that any one caused the reported phone disconnect. No claim of data exfiltration; IPv6 reproductions use no real network.
