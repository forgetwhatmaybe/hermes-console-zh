# Error strings — localization inventory

User-visible errors are still partly written in Spanish at the service layer (no
`BuildContext` there). This file tracks what is left, in the order it should be
fixed. The full per-line table lives in
[`_map/integrations.md`](_map/integrations.md) §5; the chat slice in
[`_map/chat_core.md`](_map/chat_core.md) §6.

Rule: localize at the paint boundary or through a stable error code. Never
rewrite free-form remote text, never translate the cause embedded in a message.

## Current state

| Area | Strings | State |
| --- | --- | --- |
| Chat error bubble (send / recovery / gateway / attachment / auth) | 8 constants + 1 cause prefix | localized (zh/en/es) via `core/utils/chat_error_localization.dart` |
| ARB values present but still English in `app_zh.arb` | 22 | fixed 2026-10-26 |
| Notification layer (`NotifL10n`, `BotNotificationCopy`) | 216 | es/en only — **no zh** |
| Voice (tts / stt / engine) | 24 | localized at the paint boundary: 8 causes mapped, the rest collapse to a localized fallback (no Spanish cause reaches the screen) |
| Pets / companion (import, manifest, petdex, hatch) | 58 + 9 | localized via `CompanionErrorCode` + `core/utils/companion_error_localization.dart` |
| Misc (mobile oauth, image service, one chat line) | 11 | Spanish |
| Chat service constants not yet mapped | 11 | Spanish |

## Batches

| # | Scope | Count | Change surface | Status |
| --- | --- | --- | --- | --- |
| 1 | `app_zh.arb` values still in English | 22 | ARB only | **done** |
| 2 | Voice: `voice_settings_screen` no longer splices `e.toString()`; 8 causes mapped, unknowns get a localized fallback | 24 | screen + `core/utils/voice_error_localization.dart` | **done** (2026-10-26) |
| 3 | Pets: 90 throw sites now carry a stable `CompanionErrorCode`; paint boundary maps code → zh/en/es (40 strings, unknown code gets a localized fallback) | 67 | services + 2 screens + ARB 42 keys | **done** (2026-10-26) |
| 4 | Misc: `mobile_oauth` 4, one `active_chat_service` line, `generated_image_service` 6 | 11 | services | pending |
| 5 | Notifications: `NotifL10n` / `BotNotificationCopy` / `LiveTurnCopy` now three-state (es/en/zh); 208 zh strings added, locale read directly in the FGS isolate | 208 | notification layer | **done for the 3 notification copy classes** (2026-10-26). The old 216-item table counted different scopes: 90 base + 98 rich + 20 live turn are covered; 13 voice-controller strings and 72 `AdminIntegrationsCopy` strings are **not** and stay tracked below |

Order: 1 → 4 → 3 → 2 → 5. Batch 5 is the only one that needs a design decision
(`NotifL10n` has no `BuildContext`; it already reads `app_locale` at `:19-25`).

## How to fix a batch

1. Add keys to `lib/l10n/app_es.arb` (template), `app_en.arb`, `app_zh.arb`;
   run `flutter gen-l10n`.
2. Keep a stable code in the service (`errorKey`/enum), never a sentence, when
   the string crosses layers.
3. Map code → `Strings` at the paint boundary; unknown codes keep the original
   text.
4. Tests: one per language for the mapped set, plus a pass-through case for
   free text. Run `flutter analyze lib test` (must be 0).
5. Update this file's status column.

## Known gaps outside the batches

- Still Spanish for zh (not covered by any batch yet):
  `AdminIntegrationsCopy` 72 strings (its `languageCode == 'en'` check sends
  zh to Spanish), voice conversation controller 13 strings,
  `mobile_oauth` browser pages 4 strings.
- Two more screens still splice `e.toString()` into a localized sentence:
  `chat_screen.dart:12477` (`chaRestartGatewayFail`) and
  `settings_screen.dart:3262` (`setMigrateError`). Both need the same
  paint-boundary treatment as batch 2.
- `mission_control_copy.dart`, `mission_bot_task_sheet.dart`,
  `mission_control_screen.dart`, `mission_bot_routine_sheet.dart` use the same
  hand-written `_english ? …` pattern.
- 51 further `app_zh.arb` values have no CJK outside the batches above (some are
  legitimate, e.g. `MCP`, `ID`, `{count} tokens`).
