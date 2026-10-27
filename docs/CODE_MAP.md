# Code map — where to change what

Entry point for anyone touching this repository. It is a map, not the contract:
the protocol lives in [`UPSTREAM_CONTRACT.md`](UPSTREAM_CONTRACT.md), the
architecture narrative in [`ARCHITECTURE.md`](ARCHITECTURE.md), the rules in
[`../AGENTS.md`](../AGENTS.md).

The detailed inventories are generated from the code and kept next to this file:

| Doc | What it answers |
| --- | --- |
| [`_map/chat_core.md`](_map/chat_core.md) | sending, idempotency, replay/durable recovery, outbox, invariants |
| [`_map/ui_layer.md`](_map/ui_layer.md) | message render pipeline, status line, token footer, error bubble |
| [`_map/integrations.md`](_map/integrations.md) | notifications, voice/media, bots, cron, and the full error-string inventory |
| [`ERROR_STRINGS.md`](ERROR_STRINGS.md) | which user-visible strings are still not localized, in batches |

## Layers

```
screens/            widgets only; one BuildContext, one locale
  chat_screen       chat page: render plan + composer + status/footer + errors
core/widgets/       presentational pieces (message frame, trace card, status line)
core/services/      state + transport (ActiveChat, TuiGatewayClient, coordinators)
core/models/        wire and domain models (snapshot, turn, events)
l10n/               gen-l10n ARB (es = template, en, zh); class `Strings`
```

No Console backend: the phone talks to the Hermes Dashboard the person added
(plus optional pets/voice downloads). Live turns ride the Desktop gateway
(`/api/ws`); REST serves history, files and admin.

## One message, end to end

1. Composer claims the gesture (`chat_screen._sendMessage`), freezes
   `clientTurnId`, writes the batch to the outbox before the wire.
2. `ActiveChat.send` → `_beginTurnTransport` marks the turn `submitting`.
3. Prompt is submitted with `client_turn_id`; the ACK is validated twice
   (shape + identity).
4. Gateway events stream in; `_publish*` projects them into rows.
5. Terminal: `_completeRun` / `_failRun`; the outbox entry is deleted.
6. A broken socket opens a replay edge: epoch increases, frames are held, and
   the client validates the replay batch (commit or quarantine).
7. Truncated replay: `session.resume` snapshot is applied whole, and only then
   the boundary is adopted; held frames after the baseline are released.
8. Viewer turns may read durable while streaming, but only add rows.
9. An own turn never reads durable mid-turn.
10. Every retry of an ambiguous turn reuses its `client_turn_id`.
11. An ACK/settlement clears only its full batch and submitted draft identity;
    a successor draft survives both debounce and awaited storage cleanup.

## Invariants (do not break)

| Invariant | Where |
| --- | --- |
| One logical turn = one `client_turn_id`; it may only be dropped on a coded `-32601` refusal | `active_chat_service.dart` (`_promptSubmitContradictsIdempotency`, submit loop) |
| A refused snapshot never moves the watermark, drops held frames or clears quarantine | `replay_coordinator.dart` (`adoptSnapshotBoundary`) |
| Snapshot continuation is adopted only after the whole snapshot was applied | `active_chat_service.dart` (`_applyViewerTurnSnapshotWithBoundary`) |
| Only text frames may be discarded under a snapshot baseline | `replay_coordinator.dart` (`_snapshotCoveredReplayTypes`) |
| A durable read while a viewer streams may only add rows | `active_chat_service.dart` (`_settleLiveUsersAlreadyRepresentedByDurableTail`) |
| The client's recovery epoch increases per edge; the server `replay_epoch` is compared, never reset | `active_chat_service.dart` (`transportRecoveryDurableReadEpoch`), `tui_gateway_client.dart` |
| Exactly one live status line per screen | `chat_screen.dart` (`_AssistantLiveHeader`, message `trailing`), `chat_event_cards.dart` |
| Same-wire failed replay retains held events; retired-wire loss cannot be hidden by a text-only cut | `replay_coordinator.dart` (`quarantine`, `retireTransport`, `adoptSnapshotBoundary`) |
| Recovered request cancellation performs normal registry and approval cleanup | `tui_gateway_client.dart` (`_publishCommittedRecoveryEvents`, `_dispatchSessionEvent`) |
| Settlement of A cannot clear successor B's attachments or encrypted draft | `chat_screen.dart` (`_retireSettledComposerDraft`, `_clearSubmittedTurnDraft`, `_sendMessage`) |

## Change manual

| Task | Touch | Must run |
| --- | --- | --- |
| Send / retry / duplicate turns | `active_chat_service.dart` (send, submit loop, delivery), `chat_screen.dart` (`_sendMessage`, `_retryLastPrompt`) | `turn_idempotency_contract_test`, `duplicate_send_repro_test` |
| Reconnect, replay, durable backfill | `tui_gateway_client.dart` (`_fetchReplay`), `replay_coordinator.dart`, `active_chat_service.dart` (recovery, viewer snapshot) | `desktop_disconnect_recovery_test`, `console_desktop_transcript_reconcile_test`, `transport_recovery_durable_read_test`, `truncated_replay_snapshot_boundary_test`, `viewer_truncated_replay_test` |
| Message rendering / grouping | `chat_screen.dart` (render plan), `chat_event_cards.dart` | `chat_replying_1215_test`, `ct1215_turn_in_transcript_test`, `chat_screen_test` (baseline 8) |
| Status line / token footer | `chat_screen.dart` (`_AssistantLiveHeader`, `trailing`), `chat_turn_activity.dart` | `live_status_single_line_test`, `chat_screen_test --plain-name "status"` |
| User-visible error text | `core/utils/chat_error_localization.dart` (chat bubble), ARB + `NotifL10n` elsewhere | `chat_error_localization_test`, `chat_screen_test --plain-name "error"` |
| Notifications | `notification_service.dart`, `NotifL10n`, `BotNotificationCopy` | `notification_*_test`, `notifications/*` |

## Known traps (verified while mapping)

- `TurnOutboxStore.maxAge` has no caller: the outbox does **not** expire after
  30 days. Do not assume it does.
- There is no `TurnStatusScope`; the live status comes from `LiveTurnScope`.
- The status line is part of the newest message's `trailing`, not a fixed
  overlay: it scrolls with the transcript. A second fixed instance would break
  the "one line per screen" rule.
- `assistant_error` text is localized at paint time from 8 service constants.
  Free-form remote causes are shown as-is on purpose; do not translate them.
- `AdminIntegrationsCopy` picks Spanish for every non-`en` locale, including
  `zh` — a known gap tracked in `ERROR_STRINGS.md`.
- When the messaging gateway process owns a chat's turn, `prompt.submit` is
  refused with `4090 / SESSION_OWNER_BUSY`. The client shows a specific line
  but keeps the delivery **ambiguous**: the forwarder can answer success
  without an `admission_id` before ending in BUSY, so "nothing was sent" is not
  guaranteed. Do not classify it as a clean rejection until the server tags the
  two cases differently.
