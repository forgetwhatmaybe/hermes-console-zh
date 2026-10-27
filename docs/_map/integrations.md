# 集成面地图（服务 / 非 chat 页面 / bot 与房间 / 宠物）

只读梳理，未改动 `lib/` 与 `test/`；本次只新建本文件。所有行号基于当前工作区（2026-10-26 快照），逐条用 `grep -n` / `sed -n` 核对；凡未核对到的一律不写入。

> 行号基准是**工作区文件**，不是 `HEAD`。`lib/core/services/` 下多个目标文件处于已修改未提交状态，提交或回滚后引用请重新核对。

范围（抽样，重点职责与边界）：

- `lib/core/services/` 排除 `active_chat_service.dart`、`tui_gateway_client.dart`、`replay_coordinator.dart`、`turn_outbox_store.dart`（只在链路闭合需要时引用，标注「范围外」）。
- `lib/core/screens/` 非 chat 页面：设置 / 模型 / 通知 / 定时任务 / 关于 / 引导（含 `permissions`、`voice_settings`、`backup_restore`、`credential_pool`）。
- `lib/core/bots/`、`lib/core/companion/`：只看入口与网络边界。

---

## 0. 结论速览

1. **外部流量只有三条腿**，且没有 Console 后端、没有 FCM/推送服务：
   ① 你自己那台 Hermes 的 **Dashboard REST**（`DashboardClient`，`connection_manager.dart:2115`）；
   ② 同一台 Hermes 的 **Desktop WS JSON-RPC `/api/ws`**（`tui_gateway_client.dart`，范围外）；
   ③ 两个**可选**第三方：Petdex 目录 manifest（`petdex_remote_service.dart:71`）与「用户自己 gateway 的 `/v1/images/generations`」（`hermes_hatch_provider.dart:6-14`）。
   其余全是本地：SharedPreferences、sqflite（只用于通知投递账本）、私有目录文件、Keystore。
2. **通知是纯本地通知**，链路三段：`ActiveChat` → `NotificationService` → `flutter_local_notifications.show`（`notification_service.dart:2655`）。
   但有**两个生产者**：主 isolate 的 `NotificationService`（`main.dart:366`）与 FGS isolate 里自建的一份（`background_listener.dart:1549`）。两者共用同一套文案与同一条 SQLite 账本。
3. **文案归属极不均衡**：设置 / 模型 / 通知设置 / 定时任务 / 关于 / 引导这些页面**已经 100% 走 gen-l10n**（页面内残留只有 `debugPrint`；例外是 `screens/companion/companion_playground_screen.dart` 的 6 个动画按钮，见 5.1）；
   真正的硬编码西语集中在**拿不到 `BuildContext` 的三层**——通知（`NotifL10n` 手写 es/en）、`AdminIntegrationsCopy`（手写 es/en）、语音与宠物服务（纯西语或 es/en 手写）。
4. **中文用户会踩到的三处硬伤**（详见 5.2 / 5.3）：
   - `AdminIntegrationsCopy.of` 用 `languageCode == 'en'` 二值判定（`admin_integrations_copy.dart:12-15`）→ **zh 界面整页回落到西班牙语**；
   - `voiceDownloadFailed(e.toString())`（`voice_settings_screen.dart:767`、`:864`）把西语异常串拼进中文句子；
   - 另有 22 个范围内的 key 在 `app_zh.arb` 里**值仍是英文原文**（`voiceProblem*` 一族、`chaAttachmentBatchTooBig` 等）。
5. **bot 与房间都不是「另一套网关」**：bot 是同一网关上标题固定为 `Bot Chat` 的会话（`bot_chat_target.dart:5`）；房间是同一网关上 `groups.*` 的托管会话。
   区别在 socket：主聊天用 `acquireChat` 的**多路复用 chat socket**，房间用**观察者池 socket + 一次性 RPC**（`shared_gateway_pool.dart:23-26`、`room_launcher.dart:12`）。

---

## 1. 服务分层图

### 1.1 分层

```text
┌─ 表现层 ────────────────────────────────────────────────────────────────┐
│ screens/settings · models · notification_settings · cron(+detail)       │
│ about · onboarding · permissions · voice_settings · backup_restore      │
│ credential_pool · admin_integrations · screens/companion/*              │
│ bots/ui/room/* · bots/ui/roster/*                                       │
│   文案：Strings.of(context)（gen-l10n，en/es/zh 各 4441 key）           │
└───────────────────────────┬─────────────────────────────────────────────┘
                            │ 只经构造函数注入的服务对象，不直接 new 传输
┌─ 装配层 ──────────────────▼─────────────────────────────────────────────┐
│ main.dart:366  NotificationService(prefs)                               │
│ main.dart:375  ActiveChatService(notifications: notifications, …)       │
│ screens/backup_restore_screen.dart:107  DashboardBackupGateway(dashboard)│
│ screens/cron_screen.dart:146            CronRepository(_client)         │
│ screens/mission_control_screen.dart:4427 CallbackRoomGateway(...)        │
└───────────────────────────┬─────────────────────────────────────────────┘
        ┌───────────────────┼────────────────────┬──────────────────────┐
        ▼                   ▼                    ▼                      ▼
  网络 A（REST）      网络 B（WS）         网络 C（第三方）         本地
  DashboardClient     /api/ws JSON-RPC     assets.petdex.dev       prefs / sqlite
  :2115               (tui_gateway_client) /v1/images/generations   文件 / Keystore
```

### 1.2 逐服务定性

| 服务 | 定性 | 传输 / 端点 | 谁调用（入口行号） |
| --- | --- | --- | --- |
| `notifications/notification_service.dart` | 网络（读）+ 本地（写） | WS/REST 由调用方喂；自身写 `sqflite` 与系统通知插件 | `main.dart:366`（装配）、`active_chat_service.dart:28372/29201/27104`（范围外触发）、`notification_settings_screen.dart:210`（权限） |
| `notifications/background_listener.dart` | 网络（WS + REST） | FGS isolate；`groups.state`/`groups.log`、cron、kanban、`SharedGatewayPool` | `background_listener.dart:1549` 自建 `NotificationService`；`groups.*` 见 `room_watcher.dart:1-3` |
| `notifications/rich_notifications.dart` | 本地（纯文案/构建器） | 无 IO；`NotifL10n` 的 extension（`rich_notifications.dart:45-46`） | `notification_service.dart:619-624` 注入 `strings:` |
| `notifications/notification_delivery_store.dart` | 本地 | `sqflite`，WAL + `busy_timeout`（`:20-31`） | `notification_service.dart:622` 经 coordinator |
| `voice/voice_service.dart` | 网络（可选，服务端 TTS/STT）+ 本地（sherpa/ONNX） | `stt_hermes_server.dart` / `stt_remote.dart` 走用户 gateway；模型文件落私有目录 | `voice_settings_screen.dart`、`chat_screen.dart:16561`（范围外入口）、`room_dictation.dart:116` |
| `voice/tts_model_manager.dart`、`voice/stt_sherpa.dart` | 本地（下载/解包） | `http` 拉模型包 + 校验/解 tar（`:263-297`、`:351-640`） | `voice_settings_screen.dart:767`、`:864` |
| `generated_image_service.dart` | 网络（读）+ 本地（缓存） | `/api/media`（`:21`）或结构化结果里的 HTTPS URL；20 MiB / 100 MiB 上限 | `generated_image_fetch.dart`、chat 渲染（范围外） |
| `generated_media_service.dart` | 本地（缓存/清理） | 私有目录；`stripDirectives` 也在这里被通知预览复用 | `active_chat_service.dart:28367`（范围外） |
| `attachment_uploader.dart` | 网络（写） | `POST files/upload`（`:158`、`:801`），base64 data URL | chat composer、房间同一套限制（`:12-16`） |
| `cron_repository.dart` | 网络（REST） | `cron/jobs`（`:63`）、`cron/delivery-targets`（`:171`）、`cron/blueprints`（`:191`） | `cron_screen.dart:146`、`:285`、`:722` |
| `cron_runs_client.dart` | 网络（REST，**死代码**） | `GET /api/cron/jobs/:id/runs`（`:88`） | 无任何调用方（全库仅自身引用） |
| `dashboard_backup_gateway.dart` | 网络（REST） | `/api/ops`：`ops/backup/download`（`:37`）、`:50` post、`:74` 下载、`:92` 多部分上传 | `backup_restore_screen.dart:107` |
| `backup_restore_flow.dart` / `backup_zip_summary.dart` | 本地（纯逻辑） | 读 zip 中央目录，只用枚举拒绝原因（`backup_zip_summary.dart:25`） | `backup_restore_screen.dart:87-109` |
| `credential_pool_api.dart` | 网络（REST） | `credentials/pool`（`:91`），`?profile=` | `credential_pool_screen.dart:43` 经 `apiGet` |
| `custom_endpoints_api.dart` | 网络（REST） | `apiGet`（`:171`）、`apiPost`（`:185` 等）、`apiDelete`（`:213`） | `custom_endpoints_section.dart` |
| `secure_storage.dart` | 本地（Keystore） | `flutter_secure_storage`（`:6-12`） | `SshManager`、`VoiceService`（`:207`）、连接凭据 |
| `native_session_store.dart` + `mobile_oauth.dart` | 网络（REST）+ 本地（Keystore） | OAuth 换票、`/api/auth/me`（`mobile_oauth.dart:363`） | 连接登录流程 |
| `local_models_client.dart` | 网络（REST） | `/api/local-models` 的 `status`、`catalog`、`jobs`（`:54-74`） | `local_models_screen.dart` |
| `huggingface_client.dart` | 网络（第三方，**死代码**） | 只读 HF 公共 API（`:1-5`） | 无引用 |
| `model_presets_store.dart`、`dock_preferences_store.dart`、`chat_preference_store.dart`、`pinned_prompt_prefs.dart`、`hermes_update_preferences.dart` | 本地（prefs） | `SharedPreferences` | 设置页各分区 |
| `bot_profile_client.dart`、`bot_room_link.dart`、`bot_roster_store.dart`、`bot_section_service.dart`、`bot_identity_mutation_service.dart`、`bot_widget_activity.dart` | 网络（WS/RPC，除 roster 缓存） | 全部经注入的 `BotProfileRpc`（`bot_profile_client.dart:6-9`），即 `/api/ws` | `bots/ui/*`、`bot_profile_settings_screen.dart` |
| `companion/data/companion_repository.dart` | 本地 | 只读 assets 与导入目录，**明确不联网**（`:18-20`） | `companion_controller.dart` |
| `companion/data/petdex_remote_service.dart` | 网络（第三方） | `https://assets.petdex.dev/manifests/petdex-v1.json`（`:71`，仅此 host） | `petdex_gallery_screen.dart:114` |
| `companion/hatch/hermes_hatch_provider.dart` | 网络（用户 gateway） | `/v1/images/generations`（`:6-8`），probe 失败即不可用 | `CompanionController.hatch`（`:854`）—— 当前**无 UI 入口** |
| `bots/ui/room/room_gateway.dart` | 网络（间接） | 接口；实现 `CallbackRoomGateway`（`room_launcher.dart:12`）→ Mission Control 的池化回调 | `mission_control_screen.dart:4427` |

### 1.3 关键调用链（带行号）

1. 装配 → 触发：`main.dart:366` 建 `NotificationService`，`main.dart:375` 把它交给 `ActiveChatService`；`ActiveChat` 在终态发通知 `active_chat_service.dart:28372`（`replyReady`）、失败 `:29201`（`replyFailed`）、审批 `:27104`、后台任务 `:23254`。
2. 通知落地：`NotificationService` 构造时建协调器 `notification_service.dart:622`；真正展示只有 `_plugin.show`（`:2655`、`:2684`、`:2714`、`:3273`），取消 `:657`。
3. 第二个生产者：`background_listener.dart:1549` 在 FGS isolate 里 `NotificationService(prefs)..appInForeground = false`；它不轮询 REST（文件头 `:1-7` 明说不轮询 runs，会话走 `SessionAttentionSink`）。
4. 页面 → REST：`cron_screen.dart:146` → `CronRepository` → `client.apiGetList('cron/jobs…')` `cron_repository.dart:63`；备份 `backup_restore_screen.dart:107` → `dashboard_backup_gateway.dart:37`。
5. 房间 → WS：`mission_control_screen.dart:4427` 建 `CallbackRoomGateway`，approve/retry 走 `pooledRoomApprove`（同文件 `:4435`），成员提问走 `pooledRoomPromptRequest`（`:4465`）。
6. 聊天 vs 观察者 socket 的分工写在 `shared_gateway_pool.dart:23-26`：观察者租约一个 socket，`acquireChat` 另一个 socket 按 `session_id` 多路复用。

---

## 2. 通知链路：ActiveChat → NotificationService → 系统通知

### 2.1 三段

```text
① 触发（App 内进程）                         ② 判据（本地持久化）              ③ 展示
ActiveChat._completeRun / _failRun  ──┐
ActiveChat._onDesktopEvent(approval) ─┼→ NotificationService.<event>  ──→ NotificationDeliveryCoordinator ──→ SQLite 账本 ──→ _plugin.show(...)
_activeChats 的 questionPending ─────┘        （开关 / 前台抑制 / 静音 / 去重 / 富卡片）        (:622)              (:2655)
BackgroundListener（FGS isolate）──────┘  同上，另一份实例（:1549）
```

- 开关是**读时判据**：`replyReady` 第一行 `if (!notifyReplies) return`（`notification_service.dart:2196`），失败同理 `:2331`。
- 前台抑制：`appInForeground` 由装配方设置；FGS 侧固定 `false`（`background_listener.dart:1549`）。
- 静音/去重：`notification_mute_store.dart`（按 jobId / taskId，`notification_service.dart:885-889`）+ `notification_delivery_store.dart` 的账本（保留 30 天 / 4096 墓碑，`notification_delivery_coordinator.dart:26-30`）。
- 富卡片：`rich_notifications.dart:618` 的 `RichNotificationBuilder` 与 `:1131` 的平台实现，在 `notification_service.dart:619-624` 被注入。

### 2.2 消息文案从哪来（四类来源）

| 来源 | 例子 | 位置 |
| --- | --- | --- |
| ① 模板（手写 es/en，无 zh） | 「Hermes respondió en $s」「El agente no pudo completar la tarea.」 | `notification_strings.dart:128`、`:143`；富卡片同族 `rich_notifications.dart:45-46`（`NotifL10n` 的 extension） |
| ② 会话/实例标签（服务器数据） | `connection.label`、`sessionTitle`、`compactSessionLabel`（`notification_service.dart:2538`，截 56 rune 见 `:2549-2553`），再拼 `_replyIdentity`（`:2551`） | `active_chat_service.dart:28376-28377` |
| ③ 助手正文预览（服务器内容） | 去指令后截 140 字 + `…` | 生产：`active_chat_service.dart:28368-28375`（`GeneratedMediaService.stripDirectives` + 140 字截断）；消费：`notification_service.dart:2245`、`:2254`（空则回落 `replyReadyBody`） |
| ④ 事件字段（服务器内容） | 工具名/命令：`event['command'] \| event['tool'] \| event['description']`，**兜底常量是西语 `'una herramienta'`** | 范围外但决定通知正文：`active_chat_service.dart:27096-27099` |

失败通知**故意不带 detail**：`body: t.replyFailedBody`（`notification_service.dart:2347`），原因「detail 可能含部分输出、路径、传输错误」写在 `:2344-2346`。
本地代理装卸载相反，会优先用 `detail` 覆盖正文（`notification_service.dart:2566-2580`，判断在 `:2574-2578`）——这条路径会把服务器原文直接塞进通知。

### 2.3 权限与渠道

- 权限**不在启动时问**：`NotificationPermissionMoment`（`notification_permission_moment.dart:12-45`）等到「存在一条连接且首启页面已退出」才请求一次；入口 `notification_service.dart:1052`，实际请求 `:1264`。
- 设置页三处开关都会补问权限：`notification_settings_screen.dart:77`、`:124`、`:168`、`:444`、`:700`。
- 渠道名/描述也是 es/en 手写：`notification_strings.dart:41-66`（通知/执行/传输/语音/本地操作），后台服务渠道 `:184-190`。
- 渠道被系统屏蔽时另有一套 `ChannelStatus{active,blocked,missing}`（`notification_service.dart:46-58`，查询 `:1291`），设置页据此提示。

---

## 3. 语音 / 媒体

### 3.1 入口

| 入口 | 位置 | 说明 |
| --- | --- | --- |
| 输入框麦克风 | `chat_screen.dart:16561`（范围外） | 先 `prepareForMicrophoneCapture()`，再开听写 |
| 语音设置页 | `voice_settings_screen.dart` | 引擎选择、模型下载、按键测试（`:1083`、`:1088` 为停止测试的日志） |
| 房间听写 | `room_dictation.dart:116` | 房间内独立听写实例 |
| 通知卡片的语音控件 | `notification_service.dart` 语音渠道 + `voice_notification_card_adapter.dart:15-32` | FGS 拉起 `microphone` + `mediaPlayback`（`background_listener.dart:3143`、`:3470-3540`） |
| 读 aloud | `read_aloud_session.dart`、`read_aloud_voice_route.dart` | 与语音会话共享 `VoiceService` 租约（`voice_service.dart:421-446`） |

### 3.2 权限

| 能力 | 声明 | 运行时 |
| --- | --- | --- |
| 录音 | `android/app/src/main/AndroidManifest.xml:12` `RECORD_AUDIO` | 由引擎插件询问：`speech_to_text` / `record`（`stt_engine.dart:308`、`:499`、`:659` 的 `hasPermission()`），首次触发即系统弹窗 |
| 麦克风前台服务 | `android/app/src/main/AndroidManifest.xml:51` `FOREGROUND_SERVICE_MICROPHONE` | Android 14+ 不允许后台启动 `microphone` 类型，注释见 `chat_screen.dart:17176`、`background_listener.dart:3470-3476` |
| 通知 | `android/app/src/main/AndroidManifest.xml:41` `POST_NOTIFICATIONS` | 见 2.3 |
| 相机 | `android/app/src/main/AndroidManifest.xml:25` `CAMERA` | 仅扫码页（`qr_scan_screen.dart`） |

`VoiceService.prepareForMicrophoneCapture()` 的默认实现直接返回 `true`（`voice_service.dart:421`），`false` 由平台桥接层给出。调用方对 `false` 只有一条文案（`local_voice_conversation_controller.dart:366-368`），因此**权限被拒与麦克风尚未释放，在 UI 上不可区分**。

### 3.3 失败时用户看到什么

| 场景 | 用户看到（原文） | 语言 | 位置 |
| --- | --- | --- | --- |
| STT 未就绪 | `El reconocimiento de voz no está listo (<status>).` | es/en（按**语音语言**，非界面语言） | `local_voice_conversation_controller.dart:2921-2923` |
| 麦克风仍被占用 | `El micrófono todavía se está liberando.` | es/en | 同上 `:366-368` |
| 识别器异常 | `No pude entender el micrófono.` | es/en | `:429-431` |
| 说话太短/静音 | `No te he oído.`（三处） | es/en | `:446`、`:554`、`:825` |
| 麦克风启动失败 | `No se pudo iniciar el micrófono.` | es/en | `:460-462` |
| 发送失败 | `No se pudo enviar el mensaje.` | es/en | `:651` |
| 回答被打断 | `La respuesta se interrumpió.` | es/en | `:1186` |
| 服务端语音不可用 | `La voz del servidor Hermes no está disponible. Voz se ha pausado.` | es/en | `:1678` |
| 需要审批 / 需要回答 | `Hermes necesita tu aprobación. Abre la aplicación para revisarla.` / `…tu respuesta…` | es/en | `:2005`、`:2008` |
| 停止保存失败 | `No se pudo guardar Stop de forma segura. Reinténtalo.` | es/en | `:2452` |
| 模型下载失败 | 本地化外壳 `下载失败：{error}` + **西语异常文本** | 外壳 zh、内层 es | `voice_settings_screen.dart:767`、`:864`；`app_zh.arb:1273` |
| 语音状态异常 | `voiceErrorUnavailable` 等 | **zh 值是英文**（见 5.3） | `app_zh.arb:3041` |

媒体（图片/附件/生成媒体）侧则相反，失败是**完整本地化**的：卡片用 `chaAttachmentFailed`（`app_zh.arb:3105`）、生成媒体用 `genMediaError`（`app_zh.arb:623`），异常文本不上屏（`attachment_card.dart:424`、`:636`）。
例外是批大小超限 `chaAttachmentBatchTooBig`——key 存在但 zh 值仍是英文（`app_zh.arb:3110`）。

---

## 4. bot / 房间 / companion 的边界

### 4.1 bot 与房间

| 维度 | 主聊天 | bot 聊天 | 房间（hosted group） |
| --- | --- | --- | --- |
| 会话身份 | `session_id` 由网关分配 | 同网关上**标题恰为 `Bot Chat`** 的会话（`bot_chat_target.dart:5`），无则建草稿（`BotChatTargetSource.create`，`:17-22`） | `room_id` + `groups.state` / `groups.log since_seq`（`room_watcher.dart:1-3`） |
| 网关 | 同一 `/api/ws` | 同一 `/api/ws`，但 `surface: bot`（`notification_service.dart:36-47` 枚举） | 同一 `/api/ws`，走 `groups.*`（`room_gateway.dart:20-48`） |
| socket | `acquireChat` 多路复用（`shared_gateway_pool.dart:23-26`） | 同主聊天 | 观察者池租约 + 一次性 RPC（`room_launcher.dart:12`、`mission_control_screen.dart:4435`） |
| 只读性 | 连接级 `readOnly` | 同左 | `canApprove = writable && widget.canSend`（`mission_control_screen.dart:4450`） |
| 通知 | `NotificationChatSurface.normal` | `surface: bot` → 富卡片直接落在该 bot 的会话地址（`notification_service.dart:2207-2241`） | `surface: room`；房间通知由 FGS 的 `RoomWatcher` 产生，**不经过 ActiveChat** |
| 草稿 | `chat_draft_store` | 同左 | `room_prefs` |

**边界总结**：三者共享**同一份连接、同一套凭据、同一个网关**；不共享的是 socket 复用策略、会话身份与通知表面。
`canRetry` 被硬置 `false`、`canCompressMembers` 也 `false`（`mission_control_screen.dart:4453`、`:4457`），即房间在当前版本只读得比服务端能力更保守。
`docs/hosted_identity_transition_matrix.md` 是这条边界的正式说明。

### 4.2 companion

| 层 | 是否联网 | 证据 |
| --- | --- | --- |
| `CompanionRepository`（本地资产 + 用户导入目录） | 否 | `companion_repository.dart:18-20`「只读 assets/ficheros locales; no hace red」 |
| `PetdexRemoteService`（目录） | 是（第三方，只读） | 仅允许 `assets.petdex.dev`（`petdex_remote_service.dart:67-71`），307 跳转已记入注释 `:50-51` |
| `CompanionImportService`（校验 zip / atlas / pet.json） | 否 | 全本地校验，失败抛 `CompanionImportException`（`:76-651`） |
| `HermesHatchProvider`（孵化） | 是（**用户自己的 gateway**） | `POST /v1/images/generations`（`:6-14`），探活失败即 `unavailable`（`:44`） |
| 渲染（`render/*`） | 否 | 纯 widget / spritesheet |

宠物导入失败的用户可见文案 = **本地化外壳 + 西语明细**：`str.petdexInstallFailed(e.message)`（`petdex_gallery_screen.dart:171-175`），zh 外壳见 `app_zh.arb:2654`「无法安装：{msg}」。
孵化链路当前没有 UI 入口（`CompanionController.hatch` `:854` 无调用方），所以 `hatch_service`/`prompt_safety` 的西语文案属于**潜在可见**。

---

## 5. 用户可见文案清单

### 5.0 口径与复现

- 扫描方式：先按 `[áéíóúñÁÉÍÓÚÑ¿¡]` 抓重音，再用西语词表（`No se…`、`Cancelar`、`Reintentar`、`Micrófono`…）补抓无重音句子，最后人工剔除 `debugPrint`、注释与纯标识符（例如 `'á': 'a'` 这种折叠表）。
- 判定「用户可见」= 出现在 `SnackBar` / `HermesNotice`（本仓库统一走 `AppFeedback`，`feedback_policy.dart:49-90`；范围内直接 `showSnackBar` 只有 `guided_tours_screen.dart:143` 一处，内容也是 `strings.*`）/ `Text` / `title·label·hintText` / 通知标题正文 / 错误卡片 / 浏览器页。
- 状态列：`❌` = 只有西语，无 en、无 zh，必须抽取；`es/en` = 手写双语、**没有 zh**，需补第三语或迁 ARB。
- 行号 = 该西语字面量**所在行**（`grep -n`），一行一条。

复现命令（范围内，排除调试日志后人工过一遍）：

```bash
grep -rnE "'[^']*[áéíóúñÁÉÍÓÚÑ¿¡][^']*'" \
  lib/core/services lib/core/companion lib/core/bots lib/core/screens \
  | grep -v chat_screen      # 四个 chat 核心文件与 chat_screen 在本次范围外，仅作链路引用
```

### 5.1 A 表：只有西语（必须抽取）

#### `lib/core/services/voice/tts_model_manager.dart`（下载路径的**任何**异常都会被 `voice_settings_screen.dart:764-769` 的 `catch (e)` 拼进 `voiceDownloadFailed`，含下方 `StateError`）

| file:line | 原文 | 场景 | 已本地化 |
| --- | --- | --- | --- |
| tts_model_manager.dart:238 | `La descarga de esta voz ya está en curso.` | 重复下载同一条语音 | ❌ |
| tts_model_manager.dart:263 | `El tamaño publicado del modelo TTS no coincide.` | 模型大小校验 | ❌ |
| tts_model_manager.dart:278 | `La descarga del modelo TTS supera el tamaño esperado.` | 下载超限 | ❌ |
| tts_model_manager.dart:297 | `La descarga del modelo TTS está truncada.` | 下载截断 | ❌ |
| tts_model_manager.dart:393 | `Catálogo local del modelo TTS inválido.` | 本地目录损坏 | ❌ |
| tts_model_manager.dart:414 | `El archivo BZip2 del modelo TTS está dañado.` | 解包失败 | ❌ |
| tts_model_manager.dart:547 | `El extractor TTS ya está cerrado.` | 已关闭后继续解包 | ❌ |
| tts_model_manager.dart:550 | `El modelo TTS expandido supera el límite.` | 解包超限 | ❌ |
| tts_model_manager.dart:609 | `Checksum del tar TTS inválido.` | 校验和 | ❌ |
| tts_model_manager.dart:679 | `Campo tar $field inválido.` | tar 头字段 | ❌ |
| tts_model_manager.dart:715 | `El tar del modelo TTS está truncado.` | tar 截断 | ❌ |
| tts_model_manager.dart:728 | `El modelo TTS contiene archivos vacíos.` | 空文件 | ❌ |

#### `lib/core/services/voice/stt_sherpa.dart`

| file:line | 原文 | 场景 | 已本地化 |
| --- | --- | --- | --- |
| stt_sherpa.dart:351 | `Catálogo local del modelo STT inválido.` | 目录损坏 | ❌ |
| stt_sherpa.dart:370 | `El archivo BZip2 del modelo está dañado.` | 解包失败 | ❌ |
| stt_sherpa.dart:453 | `El extractor STT ya está cerrado.` | 已关闭 | ❌ |
| stt_sherpa.dart:456 | `El modelo STT expandido supera el límite.` | 解包超限 | ❌ |
| stt_sherpa.dart:514 | `Checksum del tar STT inválido.` | 校验和 | ❌ |
| stt_sherpa.dart:531 | `Metadato de nombre largo del modelo STT inválido.` | tar 长名 | ❌ |
| stt_sherpa.dart:549 | `Entrada requerida del modelo STT inválida.` | tar 必需项 | ❌ |
| stt_sherpa.dart:572 | `Metadato de nombre largo del modelo STT inválido.` | 重复条目（同 531） | ❌ |
| stt_sherpa.dart:578 | `Metadato de nombre largo del modelo STT vacío.` | tar 长名为空 | ❌ |
| stt_sherpa.dart:604 | `Campo tar $field inválido.` | tar 头字段 | ❌ |
| stt_sherpa.dart:640 | `El tar del modelo STT está truncado.` | tar 截断 | ❌ |

#### `lib/core/services/voice/tts_engine.dart` / `lib/core/services/mobile_oauth.dart`

| file:line | 原文 | 场景 | 已本地化 |
| --- | --- | --- | --- |
| tts_engine.dart:707 | `El servidor devolvió audio vacío.` | 服务端 TTS 返回空音频 | ❌ |
| mobile_oauth.dart:449 | `Sesión iniciada` | 浏览器回跳页标题 | ❌ |
| mobile_oauth.dart:450 | `Puedes cerrar esta pestaña y volver a Console.` | 同上正文 | ❌ |
| mobile_oauth.dart:457 | `No se pudo completar el acceso` | 失败页标题 | ❌ |
| mobile_oauth.dart:458 | `Vuelve a Console e inténtalo de nuevo.` | 失败页正文 | ❌ |

#### `lib/core/services/generated_image_service.dart`（异常串，当前 UI 不上屏；一旦复用 `e.toString()` 即泄漏）

| file:line | 原文 | 场景 | 已本地化 |
| --- | --- | --- | --- |
| generated_image_service.dart:305 | `imagen vacía o demasiado grande` | 图片校验 | ❌ |
| generated_image_service.dart:343 | `la fuente de imagen HTTPS no es válida` | 图片来源 | ❌ |
| generated_image_service.dart:454 | `redirección sin destino` | 重定向 | ❌ |
| generated_image_service.dart:458 | `redirección de imagen no segura` | 重定向降级 | ❌ |
| generated_image_service.dart:466 | `respuesta de imagen no válida (${response.statusCode})` | HTTP 非 200 | ❌ |
| generated_image_service.dart:490 | `imagen vacía` | 落盘前校验 | ❌ |

#### `lib/core/companion/data/companion_import_service.dart`（导入失败明细，经本地化外壳上屏）

> 2026-10-26 更新：本节及「宠物其余文件」的西语明细已被批次 3 替换 —— 服务层改抛
> `CompanionErrorCode`（见 `companion_error_codes.dart`），绘制边界经
> `companion_error_localization.dart` 映射为 zh/en/es；下表行号仅作历史索引。

| file:line | 原文 | 场景 | 已本地化 |
| --- | --- | --- | --- |
| companion_import_service.dart:76 | `el spritesheet remoto está ausente o supera el límite` | 远程 atlas | ❌ |
| companion_import_service.dart:90 | `el spritesheet remoto no es base64 válido` | 远程 atlas | ❌ |
| companion_import_service.dart:95 | `el spritesheet remoto supera el tamaño máximo` | 远程 atlas | ❌ |
| companion_import_service.dart:103 | `el spritesheet remoto no es un PNG/WebP válido` | 远程 atlas | ❌ |
| companion_import_service.dart:121 | `la geometría de frame remota es inválida` | 远程 atlas | ❌ |
| companion_import_service.dart:130 | `no se pudo validar el atlas remoto` | 远程 atlas | ❌ |
| companion_import_service.dart:139 | `las dimensiones del atlas remoto son inválidas` | 远程 atlas | ❌ |
| companion_import_service.dart:146 | `la rejilla del atlas remoto está fuera de límites` | 远程 atlas | ❌ |
| companion_import_service.dart:153 | `la taxonomía de filas remota no coincide con el atlas` | 远程 atlas | ❌ |
| companion_import_service.dart:160 | `la taxonomía de filas remota es inválida` | 远程 atlas | ❌ |
| companion_import_service.dart:301 | `el archivo está vacío` | 本地 zip | ❌ |
| companion_import_service.dart:305 | `el ZIP supera el tamaño máximo permitido` | 本地 zip | ❌ |
| companion_import_service.dart:316 | `no es un ZIP válido` | 本地 zip | ❌ |
| companion_import_service.dart:347 | `"pet.json" no es UTF-8 válido` | manifest | ❌ |
| companion_import_service.dart:355 | `"pet.json": la raíz no es un objeto` | manifest | ❌ |
| companion_import_service.dart:359 | `"pet.json" no es JSON válido` | manifest | ❌ |
| companion_import_service.dart:372 | `nombre de spritesheet inválido` | manifest | ❌ |
| companion_import_service.dart:407 | `el ZIP no contiene ningún spritesheet (.webp/.png)` | 本地 zip | ❌ |
| companion_import_service.dart:412 | `el spritesheet está vacío` | 本地 atlas | ❌ |
| companion_import_service.dart:415 | `el spritesheet supera el tamaño máximo` | 本地 atlas | ❌ |
| companion_import_service.dart:418 | `el spritesheet no es un WebP/PNG válido` | 本地 atlas | ❌ |
| companion_import_service.dart:442 | `slug inválido o no permitido` | 身份 | ❌ |
| companion_import_service.dart:481 | `nombre de spritesheet inválido` | 远程 zip | ❌ |
| companion_import_service.dart:488 | `el spritesheet está vacío` | 远程 zip | ❌ |
| companion_import_service.dart:491 | `el spritesheet supera el tamaño máximo` | 远程 zip | ❌ |
| companion_import_service.dart:494 | `el spritesheet no es un WebP/PNG válido` | 远程 zip | ❌ |
| companion_import_service.dart:501 | `"pet.json": la raíz no es un objeto` | 远程 zip | ❌ |
| companion_import_service.dart:505 | `"pet.json" no es JSON válido` | 远程 zip | ❌ |
| companion_import_service.dart:513 | `slug inválido o no permitido` | 远程 zip | ❌ |
| companion_import_service.dart:630 | `el pet.json no es un formato reconocido (sin grid/states ni id válido)` | manifest | ❌ |
| companion_import_service.dart:638 | `no se pudieron leer las dimensiones del spritesheet` | atlas | ❌ |
| companion_import_service.dart:645 | `se espera múltiplo de ${_petdexFrameW}x$_petdexFrameH` | 帧尺寸 | ❌ |
| companion_import_service.dart:651 | `rejilla de spritesheet inválida` | 网格 | ❌ |

#### 宠物其余文件

| file:line | 原文 | 场景 | 已本地化 |
| --- | --- | --- | --- |
| companion_manifest_parser.dart:35 | `la raíz no es un objeto JSON` | manifest 解析 | ❌ |
| companion_manifest_parser.dart:39 | `JSON inválido: ${e.message}` | manifest 解析 | ❌ |
| companion_manifest_parser.dart:63 | `dimensiones de "grid" inválidas` | manifest 解析 | ❌ |
| companion_manifest_parser.dart:158 | `"$field" debe ser numérico` | manifest 字段 | ❌ |
| petdex_remote_service.dart:95 | `el manifest no es JSON válido` | Petdex 目录 | ❌ |
| petdex_remote_service.dart:106 | `el manifest no contiene mascotas válidas` | Petdex 目录 | ❌ |
| petdex_remote_service.dart:161 | `el recurso supera el tamaño máximo` | Petdex 资源 | ❌ |
| petdex_remote_service.dart:167 | `el recurso supera el tamaño máximo` | Petdex 资源 | ❌ |
| companion_repository.dart:119 | `identidad remota inválida` | 远程宠物入库 | ❌ |
| companion_repository.dart:130 | `el gateway omitió un atlas que no está en caché` | 同上 | ❌ |
| companion_repository.dart:140 | `caché de mascotas remotas no disponible` | 同上 | ❌ |
| companion_repository.dart:151 | `la mascota remota materializada no es válida` | 同上 | ❌ |
| companion_repository.dart:183 | `la revisión remota no superó la validación previa a promoción` | 同上 | ❌ |
| companion_repository.dart:193 | `caché de mascotas remotas no disponible` | 同上 | ❌ |
| companion_controller.dart:827 | `La generación de mascotas no está disponible en esta conexión.` | 孵化不可用 | ❌ |
| companion_controller.dart:842 | `No se pudo comprobar la generación de mascotas.` | 孵化探活 | ❌ |
| companion_controller.dart:857 | `La generación de mascotas no está disponible.` | 孵化异常 | ❌ |
| hatch_service.dart:47 | `La imagen generada no es válida.` | 孵化结果校验 | ❌（无 UI 入口） |
| hatch_service.dart:51 | `La imagen generada tiene dimensiones inválidas.` | 同上 | ❌（无 UI 入口） |
| hermes_hatch_provider.dart:44 | `El gateway conectado no expone generación de imágenes.` | 孵化不可用原因 | ❌（无 UI 入口） |
| hermes_hatch_provider.dart:59 | `la generación en el gateway falló: $e` | 孵化失败 | ❌（无 UI 入口） |
| hermes_hatch_provider.dart:62 | `el gateway devolvió una imagen vacía` | 孵化失败 | ❌（无 UI 入口） |
| prompt_safety.dart:24 | `Escribe una descripción para tu mascota.` | 孵化输入校验 | ❌（无 UI 入口） |
| prompt_safety.dart:27 | `La descripción es demasiado larga.` | 同上 | ❌（无 UI 入口） |
| prompt_safety.dart:33 | `Esa descripción no está permitida. Prueba con algo cosmético.` | 同上 | ❌（无 UI 入口） |

#### 宠物 UI 与尺寸标签

| file:line | 原文 | 场景 | 已本地化 |
| --- | --- | --- | --- |
| companion_scale.dart:41 | `Pequeña` | 宠物尺寸的无障碍标签 | ❌ |
| companion_scale.dart:43 | `Mediana` | 同上 | ❌ |
| companion_scale.dart:45 | `Grande` | 同上 | ❌ |
| companion_playground_screen.dart:25 | `Reposo` | 动画试玩按钮（从 `mascotas_screen.dart:560` 进入） | ❌ |
| companion_playground_screen.dart:26 | `Correr` | 同上 | ❌ |
| companion_playground_screen.dart:27 | `Esperar` | 同上 | ❌ |
| companion_playground_screen.dart:28 | `Saludar` | 同上 | ❌ |
| companion_playground_screen.dart:29 | `Saltar` | 同上 | ❌ |
| companion_playground_screen.dart:30 | `Fallo` | 同上 | ❌ |

#### 通知链路的西语兜底（文件在范围外，但直接进通知正文）

| file:line | 原文 | 场景 | 已本地化 |
| --- | --- | --- | --- |
| active_chat_service.dart:27099 | `una herramienta` | 审批事件缺 `tool/command/description` 时的工具名兜底，进通知正文 | ❌ |

**A 表合计：102 条**（tts 12 + stt 11 + tts_engine 1 + oauth 4 + image 6 + import 33 + 其余宠物 25 + UI 9 + 兜底 1）。

> 注：`stt_sherpa.dart:97/110/123` 与 `tts_model_manager.dart:62-127` 还有一批 `quality:` 西语标签，但该字段在全库**没有任何读取点**（`grep -rn "\.quality" lib` 只命中定义），当前不上屏，故不计入。

### 5.2 B 表：手写 es/en、**缺 zh**

判定：`_('es','en')`（`notification_strings.dart:27`）或 `_t('es','en')`（`rich_notifications.dart:46`）或三元 `_english ? en : es`（`admin_integrations_copy.dart:18`）。es 侧就是下表的「原文」。

#### `lib/core/services/notifications/notification_strings.dart`（90 条）

| file:line | 原文（es） | 场景 | 已本地化 |
| --- | --- | --- | --- |
| notification_strings.dart:32 | `Nueva actividad en Hermes` | 隐私模式通知标题 | es/en（无 zh） |
| notification_strings.dart:33 | `Toca para verla` | 隐私模式通知正文 | es/en |
| notification_strings.dart:38 | `$n avisos recientes` | 通知组摘要 | es/en |
| notification_strings.dart:41 | `Aprobaciones` | 渠道名 | es/en |
| notification_strings.dart:43 | `Permisos que el agente necesita de ti` | 渠道描述 | es/en |
| notification_strings.dart:46 | `Respuestas` | 渠道名 | es/en |
| notification_strings.dart:48 | `Cuando el agente termina de responder` | 渠道描述 | es/en |
| notification_strings.dart:51 | `Ejecuciones` | 渠道名 | es/en |
| notification_strings.dart:53 | `Estado de las tareas en ejecución` | 渠道描述 | es/en |
| notification_strings.dart:54 | `Transferencias` | 渠道名 | es/en |
| notification_strings.dart:56 | `Progreso de subidas y descargas SFTP` | 渠道描述 | es/en |
| notification_strings.dart:59 | `Modo voz` | 渠道名 | es/en |
| notification_strings.dart:61 | `Estado del modo voz activo` | 渠道描述 | es/en |
| notification_strings.dart:62 | `Operaciones locales` | 渠道名 | es/en |
| notification_strings.dart:64 | `Progreso de operaciones locales que has iniciado` | 渠道描述 | es/en |
| notification_strings.dart:70 | `Hermes necesita tu atención` | 审批标题 | es/en |
| notification_strings.dart:72 | `Toca para responder` | 审批正文 | es/en |
| notification_strings.dart:75 | `Terminó` | 运行结束标题 | es/en |
| notification_strings.dart:76 | `No pudo terminar` | 运行失败标题 | es/en |
| notification_strings.dart:80 | `Terminó en otro dispositivo` | 跨端活动 | es/en |
| notification_strings.dart:82 | `Falló en otro dispositivo` | 跨端活动 | es/en |
| notification_strings.dart:84 | `Se detuvo en otro dispositivo` | 跨端活动 | es/en |
| notification_strings.dart:86 | `Toca para ver el resultado` | 跨端活动正文 | es/en |
| notification_strings.dart:90 | `Terminó una tarea en segundo plano` | 后台任务 | es/en |
| notification_strings.dart:92 | `Falló una tarea en segundo plano` | 后台任务 | es/en |
| notification_strings.dart:94 | `Toca para ver el resultado` | 后台任务正文 | es/en |
| notification_strings.dart:96 | `Tarea programada terminada` | cron | es/en |
| notification_strings.dart:98 | `Falló una tarea programada` | cron | es/en |
| notification_strings.dart:99 | `Tarea terminada` | kanban | es/en |
| notification_strings.dart:100 | `Tarea bloqueada` | kanban | es/en |
| notification_strings.dart:102 | `Una tarea te necesita` | kanban | es/en |
| notification_strings.dart:103 | `Tarea actualizada` | kanban | es/en |
| notification_strings.dart:105 | `Una tarea falló y se va a reintentar` | kanban | es/en |
| notification_strings.dart:109 | `Una tarea tardó demasiado y se va a reintentar` | kanban | es/en |
| notification_strings.dart:112 | `Tarea detenida` | kanban | es/en |
| notification_strings.dart:114 | `Una tarea necesita que decidas` | kanban | es/en |
| notification_strings.dart:117 | `Objetivo cumplido` | 长期目标 | es/en |
| notification_strings.dart:118 | `Objetivo en pausa` | 长期目标 | es/en |
| notification_strings.dart:119 | `Objetivo bloqueado` | 长期目标 | es/en |
| notification_strings.dart:120 | `Objetivo en espera` | 长期目标 | es/en |
| notification_strings.dart:122 | `Sin título` | 目标无标题兜底 | es/en |
| notification_strings.dart:127 | `Hermes respondió` | 回答就绪标题（无会话名） | es/en |
| notification_strings.dart:128 | `Hermes respondió en $s` | 回答就绪标题 | es/en |
| notification_strings.dart:132 | `Respuesta lista. Toca para abrir.` | 回答就绪正文 | es/en |
| notification_strings.dart:137 | `Hermes encontró un problema` | 失败标题（无会话名） | es/en |
| notification_strings.dart:139 | `Problema en $s` | 失败标题 | es/en |
| notification_strings.dart:143 | `El agente no pudo completar la tarea.` | 失败正文 | es/en |
| notification_strings.dart:149 | `Hermes local instalado` | 本地代理 | es/en |
| notification_strings.dart:151 | `Error al instalar Hermes local` | 本地代理 | es/en |
| notification_strings.dart:153 | `El agente Hermes local se instaló en el dispositivo.` | 本地代理正文 | es/en |
| notification_strings.dart:157 | `No se pudo completar la instalación.` | 本地代理正文 | es/en |
| notification_strings.dart:161 | `Hermes local eliminado` | 本地代理 | es/en |
| notification_strings.dart:163 | `Error al eliminar Hermes local` | 本地代理 | es/en |
| notification_strings.dart:165 | `El agente Hermes local se eliminó del dispositivo.` | 本地代理正文 | es/en |
| notification_strings.dart:169 | `No se pudieron eliminar algunos archivos.` | 本地代理正文 | es/en |
| notification_strings.dart:176 | `Las notificaciones funcionan. Te avisaré cuando Hermes termine o te necesite.` | 测试通知正文 | es/en |
| notification_strings.dart:181 | `Abrir` | 通知动作按钮 | es/en |
| notification_strings.dart:184 | `Servicio en segundo plano` | FGS 渠道名 | es/en |
| notification_strings.dart:186 | `Mantiene a Hermes activo con la app cerrada` | FGS 渠道描述 | es/en |
| notification_strings.dart:190 | `Activo en segundo plano` | FGS 常驻卡片 | es/en |
| notification_strings.dart:193 | `Conectado a Hermes` | FGS 常驻卡片 | es/en |
| notification_strings.dart:194 | `Detener` | FGS 卡片动作 | es/en |
| notification_strings.dart:197 | `Modo voz` | 语音通知标题 | es/en |
| notification_strings.dart:198 | `Escuchando…` | 语音状态 | es/en |
| notification_strings.dart:199 | `Transcribiendo…` | 语音状态 | es/en |
| notification_strings.dart:200 | `Pensando…` | 语音状态 | es/en |
| notification_strings.dart:201 | `Ejecutando una herramienta…` | 语音状态 | es/en |
| notification_strings.dart:202 | `Necesita aprobación` | 语音状态 | es/en |
| notification_strings.dart:203 | `Hablando…` | 语音状态 | es/en |
| notification_strings.dart:204 | `Error en modo voz` | 语音状态 | es/en |
| notification_strings.dart:206 | `Puedes seguir hablando · toca para abrir Hermes` | 语音卡片正文 | es/en |
| notification_strings.dart:210 | `Conversación en pausa · pulsa Continuar o abre Hermes` | 语音卡片正文 | es/en |
| notification_strings.dart:214 | `Hermes necesita aprobación · pulsa Revisar` | 语音卡片正文 | es/en |
| notification_strings.dart:218 | `Sigue hablando · toca para abrir Hermes` | 语音卡片正文 | es/en |
| notification_strings.dart:222 | `Pulsa Continuar o toca para abrir Hermes` | 语音卡片正文 | es/en |
| notification_strings.dart:226 | `Pulsa Revisar para aprobar en Hermes` | 语音卡片正文 | es/en |
| notification_strings.dart:229 | `Escuchando` | 语音卡片状态 | es/en |
| notification_strings.dart:230 | `En pausa` | 语音卡片状态 | es/en |
| notification_strings.dart:232 | `Necesita aprobación` | 语音卡片状态 | es/en |
| notification_strings.dart:233 | `Micrófono activo` | 语音卡片 | es/en |
| notification_strings.dart:234 | `Micrófono pausado` | 语音卡片 | es/en |
| notification_strings.dart:236 | `Estado de voz de Hermes` | 无障碍描述 | es/en |
| notification_strings.dart:238 | `Duración de la conversación` | 无障碍描述 | es/en |
| notification_strings.dart:239 | `Pausar` | 语音动作 | es/en |
| notification_strings.dart:240 | `Continuar` | 语音动作 | es/en |
| notification_strings.dart:241 | `Revisar` | 语音动作 | es/en |
| notification_strings.dart:242 | `Terminar` | 语音动作 | es/en |
| notification_strings.dart:244 | `Terminar conversación` | 语音动作 | es/en |
| notification_strings.dart:245 | `Leyendo respuesta` | 朗读通知 | es/en |
| notification_strings.dart:246 | `Lectura en pausa` | 朗读通知 | es/en |

#### `lib/core/services/notifications/rich_notifications.dart`（39 条，富卡片行文案）

| file:line | 原文（es） | 场景 | 已本地化 |
| --- | --- | --- | --- |
| rich_notifications.dart:51 | `¿Permitir «$cmd»?` | 审批卡标题 | es/en |
| rich_notifications.dart:55 | `Pide permiso · $what` | 审批卡副行 | es/en |
| rich_notifications.dart:57 | `Pide permiso` | 审批卡副行 | es/en |
| rich_notifications.dart:61 | `Tiene una pregunta` | 提问卡 | es/en |
| rich_notifications.dart:63 | `$who te necesita` | 需要你 | es/en |
| rich_notifications.dart:64 | `Nueva actividad` | 通用 | es/en |
| rich_notifications.dart:66 | `Ronda terminada` | 房间轮次 | es/en |
| rich_notifications.dart:70 | `Ronda terminada · $names respondió` | 房间轮次 | es/en |
| rich_notifications.dart:86 | `$head y $rest más` | 成员列表折叠 | es/en |
| rich_notifications.dart:94 | `Falló una respuesta en la sala · ábrela para verla` | 房间失败 | es/en |
| rich_notifications.dart:98 | `$who está trabajando…` | 房间活动 | es/en |
| rich_notifications.dart:100 | `$who está pensando…` | 房间活动 | es/en |
| rich_notifications.dart:103 | `La sala está trabajando…` | 房间活动 | es/en |
| rich_notifications.dart:110 | `$bot terminó` | bot 结果 | es/en |
| rich_notifications.dart:111 | `$bot terminó · $firstLine` | bot 结果 | es/en |
| rich_notifications.dart:112 | `Tú` | 发送者标签 | es/en |
| rich_notifications.dart:129 | `Reintentar` | 通知动作 | es/en |
| rich_notifications.dart:154 | `Ya había terminado` | 竞态提示 | es/en |
| rich_notifications.dart:158 | `Marcar leído` | 通知动作 | es/en |
| rich_notifications.dart:164 | `No pudo terminar` | 结果行 | es/en |
| rich_notifications.dart:169 | `Ya no está pendiente` | 过期提示 | es/en |
| rich_notifications.dart:171 | `No se pudo enviar · abre Hermes` | 回复失败 | es/en |
| rich_notifications.dart:175 | `No se pudo enviar · abre para reintentar` | 回复失败 | es/en |
| rich_notifications.dart:187 | `$who respondió` | 成员步骤 | es/en |
| rich_notifications.dart:195 | `Terminó «$routine»` | 例行任务 | es/en |
| rich_notifications.dart:196 | `Terminó «$routine» · $line` | 例行任务 | es/en |
| rich_notifications.dart:198 | `No pudo terminar «$routine»` | 例行任务 | es/en |
| rich_notifications.dart:221 | `Falló; se va a reintentar` | 状态行 | es/en |
| rich_notifications.dart:223 | `Tardó demasiado; se va a reintentar` | 状态行 | es/en |
| rich_notifications.dart:228 | `Terminada` | 状态映射 | es/en |
| rich_notifications.dart:245 | `Terminó` / `Falló` | 状态行 | es/en |
| rich_notifications.dart:248 | `Terminó` | 公开状态 | es/en |
| rich_notifications.dart:249 | `No pudo terminar` | 公开状态 | es/en |
| rich_notifications.dart:264 | `Respondió` | 行标签 | es/en |
| rich_notifications.dart:265 | `Respondió · $after` | 行标签 | es/en |
| rich_notifications.dart:269 | `No pudo terminar` | 行标签 | es/en |
| rich_notifications.dart:273 | `$who respondió` | 行标签 | es/en |
| rich_notifications.dart:274 | `$who respondió · $after` | 行标签 | es/en |
| rich_notifications.dart:284 | `falló` | 结果强调词 | es/en |

#### `lib/core/services/notifications/live_turn_notifications.dart`（2 条）

| file:line | 原文（es） | 场景 | 已本地化 |
| --- | --- | --- | --- |
| live_turn_notifications.dart:101 | `Permiso` | 实时回合阶段标签 | es/en |
| live_turn_notifications.dart:119 | `$who está trabajando` | 实时回合副行 | es/en |

#### `lib/core/services/voice/conversation/local_voice_conversation_controller.dart`（13 条）

| file:line | 原文（es） | 场景 | 已本地化 |
| --- | --- | --- | --- |
| local_voice_conversation_controller.dart:368 | `El micrófono todavía se está liberando.` | 语音提示条 | es/en（按语音语言） |
| local_voice_conversation_controller.dart:431 | `No pude entender el micrófono.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:446 | `No te he oído.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:462 | `No se pudo iniciar el micrófono.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:554 | `No te he oído.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:651 | `No se pudo enviar el mensaje.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:825 | `No te he oído.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:1186 | `La respuesta se interrumpió.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:1678 | `La voz del servidor Hermes no está disponible. Voz se ha pausado.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:2005 | `Hermes necesita tu aprobación. Abre la aplicación para revisarla.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:2008 | `Hermes necesita tu respuesta. Abre la aplicación para continuar.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:2452 | `No se pudo guardar Stop de forma segura. Reinténtalo.` | 语音提示条 | es/en |
| local_voice_conversation_controller.dart:2923 | `El reconocimiento de voz no está listo (${check.status.name}).` | 语音提示条 | es/en |

#### `lib/core/screens/admin_integrations_copy.dart`（72 条，设置 → 服务器集成）

| file:line | 原文（es） | 场景 | 已本地化 |
| --- | --- | --- | --- |
| admin_integrations_copy.dart:18 | `Integraciones del servidor` | 页面标题 | es/en（zh 落 es） |
| admin_integrations_copy.dart:20 | `Integraciones del servidor` | 设置入口标题 | es/en（zh 落 es） |
| admin_integrations_copy.dart:23 | `MCP manual, OAuth, webhooks y estado A2A del servidor.` | 入口副标题 | es/en |
| admin_integrations_copy.dart:28 | `Servidor` | 分段标签 | es/en |
| admin_integrations_copy.dart:31 | `Esta instancia es de solo lectura. Puedes consultar el estado, pero los cambios del servidor están desactivados.` | 只读横幅 | es/en |
| admin_integrations_copy.dart:33 | `Reintentar` | 失败动作 | es/en |
| admin_integrations_copy.dart:34 | `Cancelar` | 弹窗动作 | es/en |
| admin_integrations_copy.dart:35 | `Cerrar` | 弹窗动作 | es/en |
| admin_integrations_copy.dart:39 | `Eliminar` | 危险动作 | es/en |
| admin_integrations_copy.dart:40 | `Más opciones` | 菜单 | es/en |
| admin_integrations_copy.dart:44 | `Añade un servidor con el mismo contrato de alta individual de Hermes Desktop. Los valores introducidos se envían una vez y la app no los guarda.` | MCP 说明 | es/en |
| admin_integrations_copy.dart:46 | `Añadir servidor MCP manualmente` | MCP 表单标题 | es/en |
| admin_integrations_copy.dart:49 | `Configuración guiada para un comando local o un endpoint HTTP.` | 表单说明 | es/en |
| admin_integrations_copy.dart:52 | `Los servidores existentes nunca se editan reemplazando el mapa MCP completo, porque podrían perderse credenciales redactadas.` | 约束说明 | es/en |
| admin_integrations_copy.dart:55 | `Esta versión de Hermes no publica el alta individual de MCP.` | 能力缺失 | es/en |
| admin_integrations_copy.dart:56 | `Nuevo servidor MCP` | 表单标题 | es/en |
| admin_integrations_copy.dart:67 | `Un argumento por línea. No se interpreta mediante un shell.` | 输入提示 | es/en |
| admin_integrations_copy.dart:72 | `Los valores solo permanecen en memoria hasta enviar o cerrar este formulario.` | 隐私说明 | es/en |
| admin_integrations_copy.dart:75 | `Añadir variable` | 动作 | es/en |
| admin_integrations_copy.dart:80 | `HTTPS, o HTTP únicamente en una dirección privada LAN/Tailscale.` | 输入提示 | es/en |
| admin_integrations_copy.dart:81 | `Autenticación` | 字段标签 | es/en |
| admin_integrations_copy.dart:88 | `Se envía una vez a Hermes y la app nunca lo guarda.` | 隐私说明 | es/en |
| admin_integrations_copy.dart:89 | `Añadir servidor` | 提交按钮 | es/en |
| admin_integrations_copy.dart:91 | `Servidor MCP añadido.` | 成功提示 | es/en |
| admin_integrations_copy.dart:101 | `Autorizar servidor MCP` | OAuth 标题 | es/en |
| admin_integrations_copy.dart:104 | `Hermes recibe el callback. Esta app solo abre la página de autorización y comprueba el flujo temporal mientras esta ventana está visible.` | OAuth 说明 | es/en |
| admin_integrations_copy.dart:106 | `Abrir página de autorización` | OAuth 动作 | es/en |
| admin_integrations_copy.dart:109 | `Android no pudo abrir la página de autorización.` | OAuth 失败 | es/en |
| admin_integrations_copy.dart:111 | `Esperando autorización…` | OAuth 进行中 | es/en |
| admin_integrations_copy.dart:113 | `Autorización completada.` | OAuth 成功 | es/en |
| admin_integrations_copy.dart:116 | `Hermes indicó un error de autorización.` | OAuth 失败 | es/en |
| admin_integrations_copy.dart:119 | `Este flujo de autorización caducó. Inícialo de nuevo.` | OAuth 过期 | es/en |
| admin_integrations_copy.dart:122 | `Hermes devolvió un estado de autorización desconocido.` | OAuth 未知态 | es/en |
| admin_integrations_copy.dart:125 | `$count` + 单复数分支（herramienta disponible / herramientas disponibles） | 能力计数 | es/en |
| admin_integrations_copy.dart:129 | `Webhooks es una plataforma oficial del Gateway de Hermes. Las suscripciones se recargan en caliente cuando el receptor está activo.` | Webhook 说明 | es/en |
| admin_integrations_copy.dart:132 | `Esta versión de Hermes no publica la administración de webhooks.` | 能力缺失 | es/en |
| admin_integrations_copy.dart:135 | `No se pudieron cargar los webhooks.` | 加载失败 | es/en |
| admin_integrations_copy.dart:141 | `Actívalo para aceptar eventos HTTP entrantes. Hermes puede necesitar reiniciar el Gateway.` | 开关说明 | es/en |
| admin_integrations_copy.dart:146 | `¿Activar el receptor de webhooks?` | 确认标题 | es/en |
| admin_integrations_copy.dart:149 | `Hermes puede reiniciar el Gateway. Los chats activos podrán reconectarse mientras arranca el receptor.` | 确认正文 | es/en |
| admin_integrations_copy.dart:154 | `Webhooks activados; el Gateway se está reiniciando.` | 状态提示 | es/en |
| admin_integrations_copy.dart:159 | `Webhooks están activados, pero el Gateway todavía necesita reiniciarse.` | 状态提示 | es/en |
| admin_integrations_copy.dart:160 | `Nueva suscripción` | 动作 | es/en |
| admin_integrations_copy.dart:163 | `Crea una ruta autenticada y copia su secreto de una sola visualización.` | 说明 | es/en |
| admin_integrations_copy.dart:166 | `Todavía no hay suscripciones webhook.` | 空状态 | es/en |
| admin_integrations_copy.dart:168 | `Nueva suscripción webhook` | 表单标题 | es/en |
| admin_integrations_copy.dart:169 | `Descripción` | 字段标签 | es/en |
| admin_integrations_copy.dart:172 | `Qué hace esta ruta (opcional)` | 输入提示 | es/en |
| admin_integrations_copy.dart:180 | `Separados por comas; vacío acepta todos los eventos` | 输入提示 | es/en |
| admin_integrations_copy.dart:187 | `Entregar solo el payload` | 选项 | es/en |
| admin_integrations_copy.dart:192 | `Solo registro` | 选项 | es/en |
| admin_integrations_copy.dart:200 | `Crear` | 提交按钮 | es/en |
| admin_integrations_copy.dart:202 | `Suscripción creada.` | 成功提示 | es/en |
| admin_integrations_copy.dart:205 | `Ya existe un webhook con ese nombre. Elimínalo de forma explícita antes de crear otro.` | 冲突错误 | es/en |
| admin_integrations_copy.dart:211 | `Hermes solo muestra este secreto una vez. Al cerrar este recibo se elimina de la app y no podrá recuperarse aquí.` | 一次性密钥说明 | es/en |
| admin_integrations_copy.dart:214 | `Secreto de un solo uso` | 标题 | es/en |
| admin_integrations_copy.dart:216 | `¿Eliminar webhook?` | 确认标题 | es/en |
| admin_integrations_copy.dart:219 | `Esto elimina la suscripción de forma permanente. Las integraciones existentes dejarán de funcionar.` | 确认正文 | es/en |
| admin_integrations_copy.dart:231 | `A2A funciona íntegramente en el host de Hermes. Android solo muestra el estado oficial de la plataforma y no añade otro cliente de protocolo.` | A2A 说明 | es/en |
| admin_integrations_copy.dart:234 | `Este servidor no publica su catálogo de plataformas.` | 能力缺失 | es/en |
| admin_integrations_copy.dart:237 | `Esta instalación de Hermes no publica A2A.` | 能力缺失 | es/en |
| admin_integrations_copy.dart:240 | `Sin configurar` | 状态标签 | es/en |
| admin_integrations_copy.dart:241 | `Gateway en ejecución` | 状态标签 | es/en |
| admin_integrations_copy.dart:243 | `Activo` | 状态标签 | es/en |
| admin_integrations_copy.dart:250 | `Sin configurar` | 状态映射 | es/en |
| admin_integrations_copy.dart:252 | `Error al iniciar` | 状态映射 | es/en |
| admin_integrations_copy.dart:256 | `Estado no disponible` | 状态映射 | es/en |
| admin_integrations_copy.dart:261 | `Esta operación no está disponible en la versión de Hermes conectada.` | 错误分类 | es/en |
| admin_integrations_copy.dart:264 | `Las credenciales actuales del Dashboard no permiten esta operación.` | 错误分类 | es/en |
| admin_integrations_copy.dart:267 | `Hermes no pudo completar la operación ahora mismo.` | 错误分类 | es/en |
| admin_integrations_copy.dart:270 | `Hermes devolvió una respuesta de integración no válida.` | 错误分类 | es/en |
| admin_integrations_copy.dart:273 | `Hermes rechazó los valores o cambió el estado del servidor.` | 错误分类 | es/en |

**B 表合计：216 条**（notification_strings 90 + rich_notifications 39 + live_turn 2 + voice controller 13 + admin_integrations_copy 72）。

> B 表最要紧的不是「翻译」，而是**机制**：这 216 条根本不在 `app_*.arb` 里，`flutter gen-l10n` 覆盖不到，加 zh 只能改代码。`admin_integrations_copy.dart:12-15` 还把 `zh` 判成西语（`languageCode == 'en'` 为假 → es），是本仓库对中文用户最直接的一处错误。

### 5.3 C 表：key 已存在，但 `app_zh.arb` 的值仍是英文（范围内 22 条）

| key（app_zh.arb 行号） | 当前 zh 值 | 场景 |
| --- | --- | --- |
| `voiceDisclosureBody`（1256） | `The app converts your voice to text and sends the conversation to…` | 语音隐私披露 |
| `nativeVoiceConsentBody`（1258） | `This Hermes offers the same voice engines the desktop app uses…` | 原生语音授权 |
| `voiceServerFallbackNote`（2917） | `If the server fails, the conversation stays on the Hermes route…` | 语音降级说明 |
| `voiceServerProviderChangeFailed`（2953） | `The provider could not be changed. The previous selection remains active.` | 语音服务商切换失败 |
| `voiceServerNoParameters`（3021） | `Hermes manages this provider automatically and publishes no more…` | 语音参数说明 |
| `voiceErrorUnavailable`（3041） | `The selected voice service is not available for the active instance.` | 语音错误 |
| `voiceProblemDictationModel`（7059） | `The dictation model is not downloaded` | 语音问题清单 |
| `voiceProblemDictationServer`（7060） | `Dictation cannot use the server right now` | 语音问题清单 |
| `voiceProblemVoiceModel`（7061） | `The voice is not downloaded` | 语音问题清单 |
| `voiceProblemServerAccess`（7062） | `The server needs you to sign in` | 语音问题清单 |
| `voiceProblemServerUnavailable`（7063） | `The server is not offering voice right now` | 语音问题清单 |
| `voiceChatModeSaveFailed`（7064） | `Could not change the voice conversation on the server.` | 语音模式保存失败 |
| `voiceServerAddKey`（7065） | `Add key` | 语音密钥 |
| `voiceServerKeyTitle`（7066） | `{provider} key` | 语音密钥 |
| `voiceServerKeyMessage`（7074） | `It is saved on your Hermes server, not on this phone.` | 语音密钥 |
| `voiceServerKeyHint`（7075） | `Paste the key here` | 语音密钥输入 |
| `voiceServerAlsoListens`（7076） | `In voice conversation, the server also listens to you.` | 语音说明 |
| `voiceRowProvider`（7077） | `Provider` | 语音设置行标签 |
| `voiceRowModel`（7078） | `Model` | 语音设置行标签 |
| `voiceRowVoice`（7079） | `Voice` | 语音设置行标签 |
| `chaAttachmentBatchTooBig`（3110） | `The selected attachments exceed the total limit of {limit}.` | 附件批量超限 |
| `chaModelSheetEmpty`（392） | `No authenticated providers with models. Configure a provider in Hermes…` | 模型选择器空态 |

全库共 73 条 zh 值无 CJK（含 `MCP`、`ID`、`GitHub / Obtainium`、`{count} tokens` 等合理项）；上表是范围内的 22 条，其余 51 条散在 chat / mission control / 主题 / 诊断等范围外面。
key 完整性本身没问题：`app_en/es/zh.arb` 各 4441 个非 `@` key，三方无缺项。

### 5.4 已确认「不用管」的项（避免下一批重复扫）

| 项 | 位置 | 理由 |
| --- | --- | --- |
| 设置 / 模型 / 通知设置 / 定时任务 / 关于 / 引导 / 权限 / 备份 / 凭据 页面的按钮与错误 | 各 `screens/*.dart` | 全部 `Strings.of(context)`；提示统一走 `AppFeedback`（唯一裸 `SnackBar` 也是本地化文案） |
| 上述页面里的西语 | 仅 `debugPrint` / `_log` / 注释 | 例：`about_screen.dart:69`、`settings_screen.dart:2789`、`voice_settings_screen.dart:1083` |
| 通知服务的失败路径 | `notification_service.dart:1039-3366` 的 `_log(...)` | 全是调试日志 |
| `notification_action_ops.dart:194`、`full_duplex_barge_in_monitor.dart:134/183/210` 一类 `StateError` | — | 不出现在任何 `catch` 上报路径，属编程期不变量 |
| `cron_runs_client.dart:76-129` 的英文 reason | 死代码（全库无调用方） | 若要复活需先决定语言，别翻译后再删 |
| `huggingface_client.dart` | 死代码 | 无引用 |
| `notification_strings.dart:30` `brand` / `:174` `testTitle` | 品牌名 | 保留原文 |
| `local_voice_command_detector.dart:349-369`、`voice_response_policy.dart:233-239`、`roster_model.dart:284-299` | 重音折叠表 | 不是文案 |
| `stt_sherpa.dart:97/110/123`、`tts_model_manager.dart:62-127` 的 `quality:` | 西语标签 | 字段无任何读取点，当前不上屏；哪天接上 UI 就变成 A 表条目 |
| ARB 中的 `MCP`/`ID`/`URL` 类值 | `app_zh.arb` | 术语，可保留英文 |

---

## 6. 建议的 i18n 批次（按「能否只改 ARB」排序）

| 批次 | 内容 | 条数 | 改动面 | 风险 |
| --- | --- | --- | --- | --- |
| 1 | C 表 22 条 zh 值补译 | 22 | 只改 `app_zh.arb` | 无 |
| 2 | A 表语音 24 条（tts 12 / stt 11 / tts_engine 1）+ `voice_settings_screen.dart:767/864` 改为映射错误码 | 24 | 服务 + 页面 | 中：`e.toString()` 是唯一出口，改码要同时改 3 个文件（tts/stt/engine）里的 throw 点 |
| 3 | A 表宠物 58 条（import 33 / manifest 4 / petdex 4 / repository 6 / controller 3 / hatch 系 8）+ 宠物 UI 9 条（`companion_scale` 3、`companion_playground_screen` 6） | 67 | 服务 + 2 页面 | 低：明细只被 `petdexInstallFailed(msg)` 拼接，可整体改成错误码 + ARB 映射 |
| 4 | A 表 11 条杂项（`mobile_oauth` 4 + `active_chat_service:27099` 1 + `generated_image_service` 6） | 11 | 服务 + 范围外 1 行 | 低：图片异常当前不上屏，先定语言再决定是否改 |
| 5 | B 表 216 条迁到 ARB（或给 `NotifL10n` 加 zh 分支） | 216 | 通知层 + 集成页 | 高：`NotifL10n` 无 `BuildContext`，要么接受 `app_locale` 直读（已有 `:19-25`），要么整层注入 locale |

顺序建议按 1 → 4 → 3 → 2 → 5：先修「已建 key 却漏译」，再修「外壳已本地化、内层漏译」，最后动需要重构语言解析的两大坨。

---

## 7. 范围外、但同一模式的问题（供后续排期，不在本次范围）

| 位置 | 现象 |
| --- | --- |
| `lib/core/screens/mission_control_copy.dart`、`mission_bot_task_sheet.dart`、`mission_control_screen.dart` | 同一套 `_english ? …` 手写双语（`grep -rl "_english ?"` 命中 4 个文件），zh 同样落西语 |
| `lib/core/screens/mission_bot_routine_sheet.dart:83-108` | `static const es = MissionBotRoutineSheetCopy(...)` 整块西语常量，23 条 |
| `lib/core/screens/tasks_screen.dart`、`mission_bot_routine_sheet.dart` | 仍有西语字面量，本次未核实是否上屏 |
| `lib/core/screens/external_provider_screen.dart:698`、`lock_screen.dart:218`、`models_api_keys_section.dart:235` | `label/hintText` 硬编码（`Base URL`、`PIN`、`sk-…`），属术语可接受 |
| `chat_screen.dart` | 错误气泡只翻译 8 条服务端常量（见 `docs/_map/ui_layer.md` §0.4），其余原样透出 |
