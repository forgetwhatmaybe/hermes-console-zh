# Contract with upstream (Hermes Agent / Nous Research)

Console is a **client** of a third-party, self-hosted agent (Hermes, by Nous
Research). It therefore inevitably follows Hermes: if Nous changes its API,
ports or protocol, the app must be updated. This document lists **exactly what
depends on upstream and where to change it**, so that maintenance is a one-line
change and not a treasure hunt.

Design principle: **fail soft, never crash.** Every dependency on upstream
degrades to an honest state ("not available", "needs X") instead of crashing. A
feature is shown only when the connected server offers what it needs; Console
does not invent endpoints. The adaptation and its limits are described in
[`ARCHITECTURE.md`](ARCHITECTURE.md).

Sources of truth for the contract (do not invent endpoints): Hermes Agent's own
source and the behaviour of a live Hermes server. Console talks to the Dashboard
of Hermes itself and to nothing else; the Mobile Bridge was retired in 1.2.15
(section 4) and the Gateway is no longer used (section 3).

---

## 1. Ports and endpoints

| What | Default | Where in the code |
|---|---|---|
| Gateway (API server, Bearer `API_SERVER_KEY`) | `:8642` | Not used by the app (section 3); the port field of `SavedConnection` only remains for older saved connections |
| Dashboard / admin API | `:9119` | `SavedConnection` (`dashboardPort`) |

If Hermes changes a default port, update the constants in `SavedConnection` and
the connection screen (`instance_edit_screen.dart`). The setup helper
([xP3ta/hermes-setup](https://github.com/xP3ta/hermes-setup)) uses the same
defaults and lets them be moved. The official command that opens the Dashboard
to the network is `hermes dashboard --host 0.0.0.0`; on a non-loopback bind
Hermes always requires a Dashboard sign-in.

## 2. Dashboard (what the app uses)

`ConnectionManager` and the typed clients around it. Authentication, in the order
the app prefers: a cookie session after the Dashboard login, a session token
scraped from the Dashboard HTML (`window.__HERMES_SESSION_TOKEN__`) and sent as
`X-Hermes-Session-Token`, or Basic Auth, according to what the server really
accepts.

- **Chat and live state:** the WebSocket `/api/ws` carrying JSON-RPC 2.0, the
  same channel Hermes Desktop uses (`TuiGatewayClient`, sessions, history,
  approvals, profiles, rooms, Kanban and voice methods). Unknown
  methods degrade silently.
- **REST endpoints used:** `/api/status`, `/api/profiles` (and `/{name}/soul`),
  `/api/sessions`, `/api/model/info|options|set`, `/api/cron/jobs`, `/api/logs`,
  `/api/config`, `/api/env`, `/api/mcp/servers`, `/api/plugins` and the voice
  endpoints under `/api/audio/*` (including `voice-live` for GPT-Live). Most are
  scoped by profile with `?profile=`.
- If an endpoint changes shape or name, it is centralised in
  `connection_manager.dart` (look for `apiGet`/`apiPost`) and in the typed
  clients of `lib/core/services/`.

The main model is **not isolated per profile**: `POST /api/model/set?profile=X`
changes the model of the running gateway (there is a single gateway). The app
asks for confirmation first. That is Hermes' semantics, not an app bug.

### Snapshot replay watermark

The `session.resume` / `session.activate` result — the `LiveSessionSnapshot` root — may carry
two optional fields. They are **not** on canonical `session.info`:

- `last_sequence` (int): every `/api/ws` event frame with `seq <= last_sequence`
  is already reflected in the snapshot content. A reconnecting client resumes
  from `events.since(last_seen = <that last_sequence>)` instead of re-reading the transcript
  (the wire parameter is `last_seen`, not `last_sequence`).
- `replay_epoch` (str): identifies the server process that owns the `seq`
  numbering. The client adopts it from `gateway.ready` and compares by
  **equality**; it is never incremented or reset client-side. A changed epoch
  means the counter restarted, so the client replays from its own durable
  watermark instead of trusting a stored `seq`. When the field is absent the
  client clears its watermark rather than renumbering.

Both are optional: servers that predate them omit the keys, and a cold path
answers `0` for a brand-new runtime session. Parse them defensively and keep the
existing watermark when they are absent.

`session.events.since` **accepts** a `replay_epoch` argument, but the current server accepts
and ignores it; the client does not send it. Treat a process change as something learned from
the response `epoch` (`truncated` / `latest_seq` / `epoch`), not from the request.

### Turn idempotency

`prompt.submit` accepts an optional `client_turn_id`. When present, the result
carries an ack (`accepted`, `client_turn_id`, `server_turn_id`, `state`,
`duplicate`):

- `state` is `accepted` | `running` | `terminal`. A retry of a key that already
  finished learns `terminal` instead of opening a second turn.
- `duplicate = true` means the key was already registered and this delivery was
  not executed again.
- Requests without `client_turn_id` keep the legacy result shape — the ack
  fields stay absent, so older clients are unaffected.

**When the ack is present, both are non-empty**: `duplicate` is a JSON bool and
`server_turn_id` is a non-empty string. A client may enforce both (the Console
client does, and that is correct).

How that guarantee is produced matters if you read the server: it is **ordering**,
not a self-contained check. Two claim points feed the four ack sites:

- `_lock_in_submit_turn` claims at `methods_prompt.py:1145` and is called at `:1305`.
  A refused claim returns `5038` at `:1153` and never reaches an ack. Both acks it
  precedes — `:1380` (compute dispatch) and `:1462` (inline result) — are therefore
  after a successful claim.
- The typed-stop path claims separately at `:1218` and returns `5038` at `:1221-1222`
  when the key is absent, so its ack at `:1230` is equally covered. Note this ack runs
  **before** `:1305`; the ordering claim is per-path, not one global claim ahead of
  every ack.

The two defensive defaults — `entry.get("server_turn_id") or ""` (`:1019`) and
`server_turn_id = None` (`:1434`) — therefore never land on a reachable path: a claim
either registered the key, or the request returned an error first.

Do not restate this as "the helper may emit an empty id": it cannot, on any path
that answers. If a future edit moves an ack before the claim, this becomes a real
client crash — the ordering is the invariant to preserve.

### Error codes are a coarse class, not a semantic key

Measured 2026-10-28 on the local server: **110 distinct codes across 412 call sites**
(`tui_gateway/`), and the same code carries unrelated meanings — `4001` is used for
`client_turn_id required`, `invalid_params`, `malformed server config` and
`config.set model requires a live session` alike.

So:

- Split by range only. `4xxx` (62 codes, 4000–4403) = the request or its parameters were
  rejected; `5xxx` (48 codes, 5000–5400) = the server accepted the request and failed while
  carrying it out. That is all the number tells you.
- **Do not add new branches on a specific code.** A client that special-cases `4004` will
  misfire on the next method that reuses it.
- `error.data.reason` is the discriminator, and it has **30+ values**, not a closed enum:
  local snake_case reasons (`submit_interrupted`, `invalid_params`, `send_failed`,
  `unknown_profile`, `runtime_unavailable`, `empty`, `wake_owned`), uppercase tokens passed
  up from deeper layers (`SESSION_NOT_OWNED`, `SESSION_OWNER_UNCONFIRMED`,
  `SESSION_OWNER_BUSY`, 16 `ConnectorErrorReason` values) and forwarded ledger refusals
  (`queue_full`, `runtime_draining`, `profile_mismatch`, `permission_denied`, `not_found`).
  Match the values you care about by equality and treat everything else as "no reason given".
- Otherwise the semantics live in `error.message`, which is human text and may be reworded.

**This client is currently mixed, and that is a known debt, not a pattern to copy.** It maps
reasons in `turn_error_surface.dart:241` (`_codePlans`) and `active_chat_service.dart:69`
(`SESSION_NOT_OWNED`), but it also branches on concrete codes as compatibility signals:
`tui_gateway_client.dart:8512` (`-32601` / `4000` / `4001`), `:7822` (`-32602` / `4023`) and
`:8208` (`404`). Do not extend that set — if a new case needs distinguishing, add a `reason`.

### Local admission repair: interrupted submit

The paired local server repair may answer `prompt.submit` with JSON-RPC error
`4095`, `data.reason = "submit_interrupted"` when Stop invalidated its admission
before worker handoff. The user row may already be durable. The original
`client_turn_id` remains terminal in that runtime's registry; retrying that key
must not execute it again. This is not proof of a clean pre-acceptance refusal.
Console keeps its ambiguous delivery and stable identity for explicit retry or
reconciliation; it does not switch to an unkeyed legacy submission. Existing
servers need not emit this error. No request/result/event schema changes.

## 3. Gateway (retired from the app)

The app no longer calls the Gateway REST API (`/v1/runs`, `/v1/models`,
`/v1/capabilities`, `/v1/skills`, `/v1/toolsets`, `/health` on the Gateway
port). Chat, history, approvals and every other read go through the Dashboard.
The only Gateway requests left are three liveness lines for a saved connection
that has no Dashboard; a CI test
(`test/u6_gateway_retirement/gateway_gate_test.dart`) pins that list. No
`API_SERVER_KEY` is asked for when adding a connection.

## 4. Mobile Bridge (retired in 1.2.15)

The app no longer talks to the Mobile Bridge (`:9131`). Skills, SOUL, memory,
cron and Dashboard access go through Hermes' own Gateway and Dashboard. The app
has no bridge client, provisioning or update, and no request goes to `/bridge/*`
(guarded by retirement tests).

What remains of an earlier install:

- On the phone, the Keystore secrets `bridge_url_<id>` / `bridge_token_<id>` and
  the `bridge_auto_update` preference are deleted on the first launch after
  updating (`LegacyBridgeRetirement`), after probing each instance's Dashboard
  once.
- On the server, the bridge service keeps running until its owner stops it: the
  Linux user unit `hermes-bridge.service`, the macOS LaunchAgent
  `dev.xpetalab.hermes-console.bridge`, or the Windows tasks
  `HermesConsole-MobileBridge` and `HermesConsole-Restart-MobileBridge`. The
  app shows how to remove it (the setup helper's `--retire-bridge` /
  `-RetireBridge` line); it does not remove it itself.

The Dashboard should run as a **service** (systemd user unit, LaunchAgent or
Scheduled Task), not as a manual process, or `hermes update` will take it down.
Hermes ships no service for the Dashboard itself; the published setup command
(`hermes-dashboard-setup`) creates one (systemd user unit, launchd job or
Scheduled Task).

## 5. Setup helper

The app ships no setup scripts. `HermesSetupCommands`
(`lib/core/services/hermes_setup_commands.dart`) holds the helper's four lines
per system (set up, show the code again, a new Dashboard sign-in, retire the
bridge); a test pins them so the app and the helper cannot drift apart. If the
helper's URL or arguments change, change them there. The pairing link
(`hermes://pair`) is the format of the older helper: it carries the address and
a key and, when known, the Dashboard sign-in (`dash_user`, `dash_pass`); the app
shows what a link sets up before saving anything. The Dashboard-only flow needs
no helper and no link: see [server configuration](CONFIGURATION.md).

## 6. On-device neural voice (TTS, models from GitHub releases)

The voice that reads replies can be neural and fully on-device (no cloud, no key)
through `sherpa_onnx` and a Piper/VITS model downloaded at runtime.

| What | Value | Where |
|---|---|---|
| Voice catalogue | id/url/dirName/onnxFile | `kNeuralVoices` in `tts_model_manager.dart` |
| Model source | the sherpa-onnx `tts-models` release (`.tar.bz2`) | `_ttsRelease` |
| Synthesis engine | `OnDeviceNeuralTtsEngine` | `tts_engine.dart` |

Each voice is one `.tar.bz2` with `<voice>.onnx`, `tokens.txt` and
`espeak-ng-data/`. It is downloaded with progress to disk and extracted in an
isolate. **Fail soft:** if the chosen voice is not downloaded, the app falls back
to the system voice (`DeviceTtsEngine`). To add a voice, add an entry to
`kNeuralVoices` and check that the URL exists in the release and that
`dirName`/`onnxFile` match the archive. The native libraries come from the
plugin and add roughly 30 MB per ABI, so publish as an AAB / split-per-ABI APKs,
never a universal APK.

---

## Checklist: "Hermes changed something, what do I touch?"

- A Dashboard endpoint -> `connection_manager.dart` and the typed client that
  uses it.
- A JSON-RPC method of `/api/ws` -> `tui_gateway_client.dart`.
- A port -> `SavedConnection` and `instance_edit_screen.dart` (9119 Dashboard;
  8642 is the retired Gateway).
- The helper's lines -> `hermes_setup_commands.dart` (and its test).
- The shape of a payload -> the matching `*.fromJson` (parse defensively).
