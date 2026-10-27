# Spec 081 — CJK dictation survives the STT hallucination filter

Status: fix implemented 2026-10-24, pending on-device acceptance.

## Problem

`VoiceResponsePolicy.isLikelySttHallucination` treated any transcript with no
ASCII `[a-z0-9]` after normalization as "noise/hallucination". Every pure-CJK
(Chinese/Japanese/Korean) dictation turn was silently dropped before reaching
the composer: the server transcribed correctly, the App discarded the text.

## Decision

- The "nothing useful was said" test is per-script, not per-alphabet: a
  transcript is empty only when it has no letters of ANY script.
- Full-width CJK punctuation (U+FF01..U+FF5E) is punctuation, not a letter —
  a transcript made only of it is still noise.
- Whisper outro hallucination markers ("thanks for watching", "amara.org",
  "[Music]") keep working unchanged; they are matched on the ASCII-normalized
  form which CJK turns never reach.

## Changes

| File | Change |
|---|---|
| `lib/core/services/voice/voice_response_policy.dart` | add `_cjkOrOtherLetters` (letter ranges of CJK/Hangul/Kana/other scripts, no full-width punctuation); skip the ASCII-only emptiness verdict when the raw transcript keeps non-ASCII letters |
| `test/voice_pro_rc_test.dart` | new group `transcripciones chinas NO se descartan`: 7 valid CJK turns are NOT dropped, 2 punctuation-only CJK strings still are |

## Acceptance

1. `flutter test test/voice_pro_rc_test.dart` — 18/18 green (verified).
2. Full `flutter test` suite green (verified, see CHANGELOG entry for the run).
3. On-device: dictation engine = Hermes server, speak Chinese, text appears
   in the composer; server gui.log shows `transcribe done ... transcript=...`.

## Out of scope

- Local (on-device) sherpa models for Chinese — server dictation already
  covers the user's need; model download remains an upstream issue.
- Any server-side change (server verified healthy end-to-end).
