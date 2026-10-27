# chat 核心链路地图（发送 / 幂等 / 断线回补）

只读梳理，未改动 `lib/`、`test/`。下列行号基于当前工作区（2026-10-26）逐条用 `grep -n` / `sed -n` 核对过；未能核对的会标「未验证」（本文所有行号均已核对，无此类条目）。

> 行号基准是**工作区文件**（`lib/` 下多个目标文件处于已修改未提交状态），不是 `HEAD`；提交或回滚后再引用请重新核对。

关于范围：`chat_screen.dart` 不在指定范围，但幂等键的**生成**与 durable 读的**入口**只存在于该文件，相关行已单独标注「范围外」，只作链路闭合用。

---

## 1. 模块职责

| 文件 | 一句话 | 关键类 / 入口（行号） |
| --- | --- | --- |
| `lib/core/services/active_chat_service.dart` | 单个会话的运行态：发送、outbox 生命周期、流式投影、终态、恢复状态机；同时是 `ActiveChat` 的装配器。 | `ActiveChat`（4599）、`send`（15435）、`_send`（15676）、`ActiveTurnDelivery`（2897）、`_recoverDesktopTurn`（21613）、`_completeRun`（28153）、`_failRun`（29100）、`_onDesktopEvent`（23065）、`ActiveChatService.attach`（32746，内部 32846 构造 `ActiveChat`） |
| `lib/core/services/tui_gateway_client.dart` | Desktop JSON-RPC/WebSocket 传输层：持有**唯一** `ReplayCoordinator`，做 epoch/watermark 准入、replay 拉取、quarantine、恢复凭证铸造与边界采纳。 | `TuiGatewayClient`（1519）、`events`（1903）、`connect`（1959）、`_replayCoordinator`（1845）、`_fetchReplay`（2818）、`_requestRuntimeRehydration`（3397）、`_requestPromptSubmit`（3693）、`recoveryProofForSnapshot`（5707）、`commitRecovery`（5766）、`adoptViewerSnapshotBoundary`（5800）、`_submitIdempotent`（8444） |
| `lib/core/services/replay_coordinator.dart` | 纯内存乱序/缺口裁决器：watermark、quarantine、held 帧、replay 批次、恢复凭证（proof）与快照边界。无 IO。 | `ReplayCoordinator`（96）、`acceptLive`（232）、`validateReplay`（319）、`commitRecovery`（548）、`adoptSnapshotBoundary`（610）、`releaseForNewTurn`（465）、`quarantine`（487）、`_recordWatermark`（821） |
| `lib/core/services/turn_outbox_store.dart` | 加密 outbox（单键 `chat_turn_outbox_v1`）：按 `clientTurnId` 持久化未确认批次，"未确认即 ambiguous"，另有丢弃墓碑（discard tombstone）与附件所有权协调。 | `TurnOutboxStore`（313）、`save`（593）、`loadAllForChat`（665）、`loadForChat`（796）、`delete`（903）、`discardFailedBeforeAcceptance`（926）、`AttachmentOwnershipCoordinator`（127） |
| `lib/core/models/desktop_session_snapshot.dart` | `session.resume` 快照模型：消息、inflight、`last_sequence`/`replay_epoch` 边界与身份证据。 | `DesktopSessionSnapshot`（11）、`lastSequence`（29）、`replayEpoch`（34）、`withoutPersistedMessages`（106）、`fromJson`（138）、边界解析（274-276）、`_positiveInt`（934）、`_exactNonEmptyIdentity`（892） |
| `lib/core/services/desktop_control_gateway.dart` | Desktop 控制面接口集合（进程停止、recovery center、扩展、项目等），不参与消息链路。 | `HermesDesktopControlGateway`（37）、`HermesDesktopProcessStopGateway`（33） |
| `lib/core/services/desktop_gateway_capabilities.dart` | 连接级、带 TTL 的可选能力记忆（内存 only，重连/过期回 `unknown`）。 | `DesktopGatewayCapability`（1）、`DesktopGatewayCapabilityCache`（38） |

补充事实：`maxAge`（`turn_outbox_store.dart:317`）在仓库内无任何引用（仅 `discardTombstoneMaxAge` 在 473 生效），即 **outbox 条目没有 30 天老化**，不要按常量名假设。

---

## 2. 一条消息的完整生命周期

### 2.1 输入 → 准备 / outbox

1. 输入层（范围外）：`chat_screen.dart:11216` 为「排队发送」构造 `PreparedTurn`，`:11313-11318` 为「正常发送」构造；两处都将 `clientTurnId` 冻结在此刻（`const Uuid().v4()`，11219 / 11318）。
2. 排队路径：`ActiveChat.enqueuePreparedTurn`（25434）→ 分配 `queueOrder`（25450-25452）→ **先** `persistPrepared()`（25468）→ 落盘成功后才进内存队列（25482）；owner 状态 `pendingSave → queued`（25461 / 25481）。
3. 落盘：`TurnOutboxStore.save`（593）加密写单键；写入前检查丢弃墓碑（640-644），并用 `_mutationGeneration` 丢弃「已被 delete/discard 抢先」的迟到写（634）；附件走 `AttachmentOwnershipCoordinator`（623、657）。
4. 直接发送路径：`send`（15435）→ `_send`（15676），`delivery` 携带同一个 `clientTurnId`（15459-15465）。

### 2.2 提交（幂等键如何生成 / 复用 / 何时失效）

- 生成：见上，UI 手势处生成一次。
- 复用：`PreparedTurn.matchesBatch`（`prepared_turn.dart:210-232`）比对 text/model/profile/restoresComposer/附件源；命中则 `sameRecoveredBatch` 为真并**连同 `createdAtMs`** 复用旧 id（`chat_screen.dart:11301-11319`）。outbox 恢复同样把原 id 交回（`turn_outbox_store.dart:665`，返回带原 `clientTurnId` 的 `PreparedTurn`）。
- 上线：`_beginTurnTransport`（15996；20193 调用）先把状态写 `submitting`（3249-3267，落盘失败直接失败不发），随后 `_canUseTurnIdempotency`（23039）通过才走 `submitPromptIdempotent`（`tui_gateway_client.dart:8444`），参数 `client_turn_id` 在 8455。
- ACK：网关侧 `DesktopTurnAck.fromJson` 校验 `accepted==true` 且回显同一 `client_turn_id`、`server_turn_id` 非空、state 合法、`duplicate` 为 bool（1272-1313）；服务侧再核一遍（20326-20335），不一致即抛错。
- 键**不会**因以下情形失效：超时、断链、`failureKind`、带码内部错误（20580-20590 只认 -32601；19570-19574 同理）。
- 键**会**失效的两种情形：
  1. 网关明确 -32601（不支持 `client_turn_id`）→ `_turnIdempotencyInvalid = true`（20589），此后本会话不再带 id；
  2. 语音打断路径 `voicePlaybackInterrupted` 直接绕过幂等（20267-20272），该次提交不带键。
- 4001 拒收：先 `markRejectedBeforeAcceptance`（20592、20206、20377）再换 runtime 重提，**仍是同一个 id**（20321-20325）。
- 主动放弃：`ActiveTurnDelivery.discardFailedBeforeAcceptance`（926）写墓碑并递增 mutation generation（941），同一身份后续 save 变 no-op（640-644）。

### 2.3 流式事件

传输层收帧（`tui_gateway_client.dart:2467-2484`）：有 `sequence` 的帧先过 `acceptLive`，只有 `dispatch` 才进 `_events`（1903）；全局帧（`sessions.changed` 等）无 sequence，直接投递（2455-2465），不参与水位。

`ActiveChat._onDesktopEvent`（23065）分派：`message.start`（23432）→ `message.delta`（23459，进 `_enqueueToken`）→ `tool.*`（23483-23536）→ `message.complete`（23546）。

### 2.4 终态

- 正常：`message.complete` → `_completeRun`（23593 → 28153）。
- 失败：`message.complete` 带 `status=error`（23560-23584）或 `error` 帧（23600-23612）→ `_failRun`（29100）。
- 取消：`_cancelRunState`（29905）。
- outbox 收敛：`_finishTurnDelivery`（15964）→ `markAccepted`（3435）/ `markRunning`（3452）/ `markTerminalAndDelete`（3467，先 save terminal 再 delete）；已确认的收尾见 `_finalizeAcceptedTurnDelivery`（15989-15994）。

### 2.5 断线恢复的三条路径

**（a）replay（有水位、同 epoch）**
`_fetchReplay`（2818）以 `last_seen = watermark` 发 `session.events.since`（2842-2846），`validateReplay`（2855）判：连续同 epoch → `ReplayBatchCommit`，批量投递 replay+held（2868-2872）；截断/异 epoch/空洞 → 保留 quarantine 并通知 viewer 候选（2873-2877）。并发 4 路（`_maxConcurrentReplayRequests`，1847）。

**（b）durable（REST 转录）**
传输恢复边沿 → `noteTransportRecoveredForDurableRead`（5999）自增 epoch；范围外入口 `chat_screen.dart:6985` 的被动读者据此**强制整页读**（6994-6997、7042-7052），成功且 epoch 未被更新边沿取代才 `noteTransportRecoveryDurableReadCompleted`（7069-7074）。自有 turn 期间整段被跳过（`chat_screen.dart:7018`，注释 7014-7017）。

**（c）snapshot（`session.resume` 权威快照）**
- 自有 turn：`_recoverDesktopTurn`（21613）循环 connect → `resumeExistingForRecovery`（19000）→ `getTurnStatus`（19491；21710-21717）→ 按 `accepted/running/terminal/failed/cancelled` 分支（21724-21821）。`running` 必须先 `_prepareDesktopRecoverySnapshot`（19032）→ `validateRecovery` → `commitRecovery`（21782-21785），任一步失败 `continue` 重来。
- viewer（只观察）：coordinator 通知截断（`tui_gateway_client.dart:2876`）→ `_onTruncatedReplay`（21095）→ `_fetchViewerTurnSnapshotForTruncatedReplay`（21112）：校验绑定/epoch/身份 → 应用快照（21169）→ **之后**才 `adoptViewerSnapshotBoundary`（21171）。

### 2.6 去重 / 水位

`acceptLive`（232-317）的裁决顺序：quarantine 中 → held（239-274）；有 replay 事务 → held（276-301）；无水位 → 建立并 dispatch（304-308）；`seq <= watermark` → ignored（310）；`seq != watermark+1` → quarantine（311-313）；否则推进水位并 dispatch（315-316）。水位写入口 `_recordWatermark`（821-829，写入前再查 quarantine）。

`quarantine` 会**删除水位**（493），所以隔离期的 `since(0)` 永远像缺口——因此 watchdog 对隔离 runtime 改走 roster 探测（`tui_gateway_client.dart:3305-3308`、3359-3390），不再循环读 `/messages`。

### 2.7 本次源码修复边界（2026-10-26）

- **ACK 与 durable settlement 按批次身份收尾。** ACK 核对提交时的正文与附件，只删除该 `clientTurnId` 的持久化草稿；settlement 通过 `matchesBatch` 核对完整批次，并在存储等待后复核归属。后继草稿即使正文相同但附件不同，或尚未触发 debounce，也必须保留（`chat_screen.dart:11523`、`chat_screen.dart:3944`）。
- **同一 wire 的 replay 失败保留 held。** 非 commit 结果把 held 转入绑定原 socket generation/channel/epoch 的 recovery transaction；合法截断之外的失败会 poison，不能借文本快照放行（`replay_coordinator.dart:319`、`replay_coordinator.dart:487`）。
- **退役旧 wire 后不能用文本快照掩盖丢帧。** 若退役时存在 held、poison 或既有丢失标记，保留 `requiresFullRecovery`，拒绝 viewer 的文本 snapshot boundary（`replay_coordinator.dart:390`、`replay_coordinator.dart:610`）。当前生产网关仍铸造空 coverage，无法提供 full-domain recovery proof（`tui_gateway_client.dart:5748`）；viewer 此时依赖 durable 终态收敛。自有 turn 在服务端仍 running 时可保持 connecting，随后通过 terminal status 与 durable final 收敛。手机上的实际断线恢复仍需单独验收。
- **恢复后释放的事件统一分派。** `_publishCommittedRecoveryEvents` 走 `_dispatchSessionEvent`，让 `request.cancel` 等控制事件得到与 live/replay 相同的归一化处理（`tui_gateway_client.dart:5787`、`tui_gateway_client.dart:2490`）。

---

## 3. 不变量清单

1. **幂等键在第一个网络字节之前冻结，重试只复用不重生。** `chat_screen.dart:11316-11318`；`prepared_turn.dart:210-232`；`active_chat_service.dart:20267-20325`。
2. **幂等能力只有 -32601 能作废，超时/断链不算。** `active_chat_service.dart:20580-20590`、`19570-19574`；`tui_gateway_client.dart:8503-8515`。
3. **ACK 必须回显同一 `client_turn_id` 且 `accepted/state` 合法，否则整条提交视为失败。** `tui_gateway_client.dart:1276-1305`；`active_chat_service.dart:20326-20335`。
4. **水位单调：等于或小于即丢弃，跳号即 quarantine，绝不允许"补着接"。** `replay_coordinator.dart:302-316`、`821-829`。
5. **quarantine 期间新帧只能 held，不能投影（不能出现"半截流"）。** `replay_coordinator.dart:239-274`；`tui_gateway_client.dart:2480-2484`。
6. **held 有硬上限：每 runtime 64 帧、总数 32×64，超限即 poison/quarantine（宁可重读不可泄漏）。** `replay_coordinator.dart:100-101`、`267-271`、`293-297`。
7. **快照必须"先完整应用、后 adopt 边界"；应用不完整就不动水位。** `active_chat_service.dart:21169-21175`；`replay_coordinator.dart:593-609`（文档）、`610-680`（实现）。
8. **快照只覆盖 assistant 文本（`message.start`/`message.delta`）；基线之下的 tool/activity 帧一律拒绝 adopt。** `replay_coordinator.dart:107-110`、`646-651`。
9. **自有 turn 期间不读 durable transcript（viewer 才读）。** `chat_screen.dart:7014-7018`；`active_chat_service.dart:5969-5974`。
10. **viewer 只"加行"：只改无 durable 身份的那一条 live 行，durable 行追加在其后，已闭合的答案永不被覆盖。** `active_chat_service.dart:21230-21241`、`21271`、`13733`、`21309-21358`；测试 `console_desktop_transcript_reconcile_test.dart:577`。

---

## 4. 改动手册

### 4.1 改「发送 / 重试 / 去重」

改这些：
- 提交与失败分类：`active_chat_service.dart:20193-20424`（提交与 4001 重绑）、`20440-20626`（失败分类、是否置 `_turnIdempotencyInvalid`）、`15964-15994`（ACK 后的状态收敛）。
- outbox 状态机：`active_chat_service.dart:2897-3545`（`beginTransport` 3249 / `markAccepted` 3435 / `markUnaccepted` 3483 / `markRejectedBeforeAcceptance` 3505 / `markTerminalAndDelete` 3467）。
- 持久化与墓碑：`turn_outbox_store.dart:593`（save 的墓碑检查 640）、`926`（discard）、`903`（delete）。
- 键生成/复用（范围外）：`chat_screen.dart:11212-11322`。
- 能力探测：`active_chat_service.dart:23039`；`tui_gateway_client.dart:8495`。

必跑：
`flutter test test/duplicate_send_repro_test.dart test/turn_idempotency_contract_test.dart`

### 4.2 改「断线回补」

改这些：
- 准入与水位：`replay_coordinator.dart:232-317`、`821-829`。
- replay 拉取：`tui_gateway_client.dart:2818-2894`。
- 通知与降级：`tui_gateway_client.dart:3397-3438`（rehydration / withheld turn end）。
- 恢复凭证：`tui_gateway_client.dart:5707-5781`；`active_chat_service.dart:19032-19114`。
- viewer 边界：`active_chat_service.dart:21095-21302`；`tui_gateway_client.dart:5800-5817`；`replay_coordinator.dart:610-680`。
- 新 turn 解隔离：`tui_gateway_client.dart:3693-3725`；`replay_coordinator.dart:465-485`。
- durable 强制整页读（范围外）：`chat_screen.dart:6985-7079`。

必跑：
`flutter test test/truncated_replay_snapshot_boundary_test.dart test/viewer_truncated_replay_test.dart`
`flutter test test/desktop_disconnect_recovery_test.dart test/transport_recovery_durable_read_test.dart`
`flutter test test/console_desktop_transcript_reconcile_test.dart`

（`desktop_disconnect_recovery_test.dart` 12.5k 行、`turn_idempotency_contract_test.dart` 3.9k 行，改动恢复/幂等核心时这两个文件是最慢也是必须的一个闸门。）

---

## 5. 用户可见错误文案（本范围内的西语字符串）

`tui_gateway_client.dart`、`replay_coordinator.dart`、`turn_outbox_store.dart`、`desktop_*`：**0 条西语 UI 文案**（其中的消息是英文协议层文本，如 2991 `'Hermes Desktop connection lost'`，作为 `TuiGatewayRpcError` 进入服务层后再被替换，不直接进 UI；`turn_outbox_store` 只有英文 `StateError`）。

以下全部位于 `active_chat_service.dart`。"是否本地化"的判定依据：`chat_screen.dart:21141` 只对**稳定错误码**做本地化，普通文本原样打印（21145-21149）。

| file:line | 原文 | 触发场景 | 已本地化 |
| --- | --- | --- | --- |
| `active_chat_service.dart:135` | `No se pudo recuperar el turno. Inténtalo de nuevo.` | 自有 turn 恢复循环耗尽（21838 调用） | 否（硬编码西语，忽略 locale） |
| `active_chat_service.dart:139` | 同上（`activeChatDesktopSnapshotFailureUiMessage`） | 恢复快照报告失败（22532） | 否 |
| `active_chat_service.dart:142` | `No se pudo completar la respuesta. Inténtalo de nuevo.` | 事件失败且无可用 cause（23607 / 23568 兜底） | 否 |
| `active_chat_service.dart:175` | `No se pudo completar la respuesta: $projected` | 网关 `error.message` 脱敏后并入（调用点 23568 / 23607） | 否 |
| `active_chat_service.dart:385-386` | `Hermes está ocupado (por ejemplo, compactando la conversación). Tu mensaje sigue en el composer: inténtalo en un momento.` | `prompt.submit` 4009 无 reason（压缩中/忙） | 部分：es/en 手写分支（372-374），非 ARB |
| `active_chat_service.dart:395-397` | `No se puede continuar en directo porque esta conversación pertenece a otro gateway o proceso. El historial se conserva y puedes iniciar un chat nuevo.` | 4090 `SESSION_NOT_OWNED`（20603-20607 进入只读冲突态） | 部分（es/en 分支） |
| `active_chat_service.dart:402-403` | `Hermes alcanzó el límite configurado de sesiones activas. Espera a que termine una sesión o ajusta el límite.` | 4090 `MAX_CONCURRENT_SESSIONS` | 部分（es/en 分支） |
| `active_chat_service.dart:408-409` | `Hermes no pudo reservar esta conversación con seguridad. Revisa el servidor y vuelve a intentarlo.` | 4090 `SESSION_COORDINATION_UNAVAILABLE` | 部分（es/en 分支） |
| `active_chat_service.dart:413` / `418` | `No se pudo enviar el mensaje. Inténtalo de nuevo.` | `prompt.submit` 其它码 / 非 RPC 失败（20620-20624） | 部分（es/en 分支） |
| `active_chat_service.dart:427-428` | `No se puede continuar esta conversación en directo. El historial se conserva y puedes iniciar un chat nuevo.` | 重载历史时读到旧版持久化的 4090 文本（`chat_screen.dart:19528` 调用） | 否 |
| `active_chat_service.dart:432` | `No se pudo completar la respuesta. Inténtalo de nuevo.` | 旧版持久化的 `hermes reported an error` | 否 |
| `active_chat_service.dart:437-438` | `Se perdió la conexión con Hermes. El mensaje no se confirmó; revisa el borrador y reintenta.` | 旧版持久化的 socket/WebSocket 错误文本 | 否 |
| `active_chat_service.dart:16006` | `No se pudo conservar el turno antes de enviarlo.` | `beginTransport` 落盘失败，批次未发出 | 否 |
| `active_chat_service.dart:19915` | `No se pudo leer un adjunto local.` | 本地附件读取失败（发前） | 否 |
| `active_chat_service.dart:19938` / `20006` | `No se pudo conservar el estado de un adjunto.` | 附件状态写盘失败 | 否 |
| `active_chat_service.dart:19940` / `20049` | `El lote de adjuntos cambió durante la subida.` | 上传期间附件批次被改，放弃该次提交 | 否 |
| `active_chat_service.dart:20468` | `El envío perdió su autorización antes de entregarse.` | 本地写权限在提交前被撤回（`LocalConversationWriteRejected`） | 否 |
| `active_chat_service.dart:21814` | `Hermes confirmó que el turno falló tras reconectar.` | 重连后 `turn.status` 返回 `failed` | 否 |

对照：真正走本地化的是两个稳定码 —— `dashboard_sign_in_required`（`chat_error.dart:26`）与 `official_channel_unavailable`（`chat_error.dart:30`），由 `chat_screen.dart:21141-21142` 判定后按语言渲染；它们由 `active_chat_service.dart:19637-19639`、`20620-20623` 产生。若要一次性消除上表的西语泄漏，正确做法是把这些字面量也换成稳定码，而不是继续在服务层拼西语句子。
