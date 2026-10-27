# 聊天页 UI 层地图（只读梳理）

> 范围：`lib/core/screens/chat_screen.dart`（渲染分派、错误气泡、composer、状态条、token 页脚、通知岛）、
> `lib/core/widgets/chat_event_cards.dart`、`chat_turn_activity.dart`、`chat/chat_message_frame.dart`、
> `message_avatar_header.dart`、`chat_render_projection.dart`、`chat_content_screen.dart`、
> `lib/l10n/app_zh.arb`（结构与 key 规则）。
>
> 本文只做记录，不修改 `lib/` 与 `test/`。所有行号均用 `grep -n` / `sed -n` 逐条核对（2026-10-26 快照），
> 不确定处显式标「未验证」。

## 0. 结论速览

1. 一条消息要经过 **三种形态**：`Map<String, dynamic>` → `ChatRenderUnitPlan`（结构索引）→ `_ChatListEntry`（可切片行）→ `Widget`。
   分组与折叠发生在第一、二步，**不在** widget 层做。
2. 状态条只有 **两个生产挂载点**（`chat_screen.dart:23463`、`:23942/:23946`），且互斥；
   仓库里 **没有 `TurnStatusScope`**，等价物是 `LiveTurnScope`（`chat_turn_activity.dart:117`，全局唯一实例在 `chat_screen.dart:15461`）。
3. 「正文 → 状态 → token → 输入框」不是一条专门的布局代码，而是
   `ChatMessageFrame` 的 `children`（正文）→ `Wrap(time, trailing)`（状态 + token）顺序，
   加上 composer 恰好是页面底部 Column 的最后一个子项。**状态条会随最新气泡一起滚走**，不是固定悬浮层。
4. 错误气泡的主文案在 **绘制边界**才本地化：`localizedChatError(activeChatStoredErrorUiMessage(content))`（`chat_screen.dart:19526-19530`）。
   只有 8 条服务端西班牙语常量能翻译，其余原样透出。
5. 本范围内仍硬编码西语并会直达用户的只有两处正文（`chat_screen.dart:3922`、`:3925`，经通知岛展开可见）；
   另有服务端 `active_chat_service.dart` 的一批 prompt 失败文案穿透未本地化（范围外，但落在同一错误气泡里）。

---

## 1. 聊天页渲染管线

### 1.1 五个阶段

| 阶段 | 位置 | 产物 | 说明 |
|---|---|---|---|
| ① 数据快照 | `chat_screen.dart:18696`（`final entries = _currentListEntries`）| `List<_ChatListEntry>` | 取 `_messages`（`ActiveChat.messages`，已做隐私/编辑投影）|
| ② 结构投影 | `chat_render_projection.dart:253` `ChatRenderProjection.build` | `List<ChatRenderUnitPlan>`（`units`，**newest-first**，`:439` 处 reversed）| 归并 assistant 连续行、聚合工具事件、合流 steer |
| ③ 切片/兜底 | `chat_screen.dart:9928` `_currentListEntries` | `_Whole / _AssistantSlice / _Failed / _RetainedTerminalError` 四种 entry | 长回答按 chunk 拆多行（`:9998-10005`）；渲染计划异常降级为失败行（`:9982-9993`）|
| ④ 物化 | `chat_screen.dart:19209` `_materializeRenderUnit` | `Map` / `_UserTurnGroup` / `List<ChatEventInfo>` | 只回填「当前这一帧」的 map，不缓存 map（`:49-51` 注释说明原因）|
| ⑤ 分派 | `chat_screen.dart:19385` `_buildRenderUnit` | `Widget` | 真正的角色/形态分支，见 1.2 |

列表本身：`ListView.custom`（`:18924`）+ `SliverChildBuilderDelegate`（`:18884`），`reverse: true`，
每一行统一被 `KeyedSubtree(key: ('chat-render-entry', durableEntryIds, sliceIndex))` 包裹（`:18870-18876`），
保证「活行转终态」时不换槽位。

行级前置分支（在进 `_buildRenderUnit` 之前）：

- `_RetainedTerminalErrorChatListEntry` → `_buildRetainedTerminalErrorEntry`（`:18710-18712`，实现 `:19114-19129`）
  这是「流式结束瞬间保留旧 error 行」的特殊合并行。
- `_FailedChatListEntry` → `_chatRowFailure`（`:18715`，实现 `:19188`，卡片 `ChatRowFailureCard`（`lib/core/widgets/chat_row_boundary.dart:78`））
- 任何 `buildRow` 抛异常 → `_chatRowFailure(..., 'index:$index')`（`:18886-18893`）

### 1.2 `_buildRenderUnit` 分派顺序（严格自上而下，命中即 return）

| # | 条件 | 产物 | 行号 |
|---|---|---|---|
| 1 | `unit is List<ChatEventInfo>` | `ToolActivityGroup`（整段工具调用折叠条） | `chat_screen.dart:19392-19394` |
| 2 | `unit is _UserTurnGroup` 且 `_jobChipLabel` 命中且无补充消息 | `_SystemBlobChip`（cron/skill/压缩摘要 chip） | `:19399-19405`（`_UserTurnGroup` 定义 `:20338`，`_jobChipLabel` `:22160`）|
| 3 | `unit is _UserTurnGroup` 且正文/附件/补充全空 | `SizedBox.shrink()` | `:19411-19415` |
| 4 | `unit is _UserTurnGroup` 其余情况 | `_UserMessage`（含 `sent/queued` 状态、编辑态） | `:19418-19453`（类定义 `:22880`）|
| 5 | 非以上，取 `msg['role'] ?? 'assistant'` | — | `:19456-19457` |
| 6 | 子代理完成信封（`historicalSubagentCompletionOf`） | `SubagentCompletionCard` | `:19471-19480` |
| 7 | `role == 'user' && display_kind == 'process_complete'` 且能解析 carrier | `_ProcessNotificationRow` | `:19485-19490`（类 `:22582`）|
| 8 | `_timelineSystemEventPresentation(...) != null`（`async_delegation_complete` / `process_complete` / `side_answer` …）| `_TimelineSystemEventRow`（系统时间线行） | `:19492-19501`（类 `:22729`，分类函数 `:22185`）|
| 9 | `_jobChipLabel(content)` 命中（**任意 role**，含压缩摘要落到 assistant 的情况）| `_SystemBlobChip` | `:19507-19510`（类 `:22523`）|
| 10 | `role == 'assistant_error'` | `ChatErrorBubble` | `:19513-19577`（类 `:21013`）|
| 11 | 流式头 或 `_messageKeepsLiveHost` 且存在 live frame | `_wrapLiveAssistantViewport(_buildLiveAssistantHost(...))` | `:19596-19604`（host `:19817`）|
| 12 | `assistant + _pipeline + 无正文 + 无活动轨迹` 且仍是活头 | `_buildActiveThinkingState()` → `_AssistantLiveHeader` | `:19620-19633`（`_buildActiveThinkingState` `:19373`，header `:23446`）|
| 13 | `assistant + isStreaming + 正文投影为空 + 无活动轨迹` | 同上 | `:19644-19649` |
| 14 | `assistant` 终态但「无正文、无技术细节、无生成媒体、无可展开轨迹」| `SizedBox.shrink()` | `:19695-19712` |
| 15 | `assistant + _cancelled + 有正文` | `_AssistantMessageWithMark(mark: cancelled)` | `:19713-19730`（类 `:21782`）|
| 16 | 其余 | `_MessageBubble` → `isUser ? _UserMessage : _AssistantMessage` | `:19734-19794`；二选一在 `:22020-22063` |

补充：

- 系统 chip 不区分 role，这是刻意的（`:19503-19506` 注释：压缩摘要有时以 `role=assistant` 到达）。
- 「系统时间线行」优先于 chip，因为 `process_complete` 的 `display_kind` 在 chip 判定之前被判走。
- 渐进揭示（`_revealedChars`）只在自动跟随且未减弱动效时裁剪正文（`:19609-19614`）。

### 1.3 分组 / 折叠发生在哪里（结构层）

`ChatRenderProjection.build`（`chat_render_projection.dart:253-447`）从 **旧到新** 遍历（`:307`），最后整体 reversed（`:439`）：

- **assistant 连续行合并成一条气泡**：`addAssistantUnit`（`:269-292`）；判定条件 `_joinsResponseGroup`（`:84-88`）＝ assistant + 无 `display_kind` + 未 cancelled/stopped；
  另有两条硬边界：`_responseGroupStart == true`（`:278`，新回合自成气泡）、流式头无可见 prompt 时另起（`:282-284`）。
- **steer 用户消息并入上一轮**：`:341-354`（`ChatUserTurnUnitPlan(primary, supplements)`）。
- **工具/审批事件聚合成一个 `ChatToolActivityUnitPlan`**：`flushTools`（`:294-303`）+ 分类（`:388-399`）。
- **编辑信封**：`display_kind` 非空且非 `hidden` 时自成一单元（`:331-339`）；`hidden` 丢弃。
- **空文本行丢弃**：`:401-405`（但带 reasoning 或 activity trace 的保留）。
- **纯结构复用**：`canReuseFor`（`:452`）让 token flush 不重算分组。

合并后的文本/轨迹在 widget 侧再拼：
`_olderResponseGroupRows`（`chat_screen.dart:12040`）、`_responseGroupMetadata`（`:12058`）、
`_joinResponseGroupText` / `_responseGroupTextPrefix`（`:19468-19469` 处调用），
纯函数实现见 `chat_render_projection.dart:94` `mergeAssistantResponseGroup`。

折叠 UI 全部在 `chat_turn_activity.dart`：`TurnFoldLine`（`:1053`）、`TurnTasksLive`（`:900`）、
`TurnTasksHistory`（`:1015`）、`TurnReasoningQuote`（`:576`）、`TurnToolRow`（`:672`）、
`turnTasksFoldLabel`（`:1045`）；工具流卡片在 `chat_event_cards.dart:571` `ToolActivityGroup`。

---

## 2. 状态条与 token 页脚

### 2.1 名字纠正

- 仓库中 **没有 `TurnStatusScope`**（`grep -rn TurnStatusScope lib/ test/` 零命中）。
  实际存在的是 `LiveTurnScope`（`chat_turn_activity.dart:117-136`，`InheritedWidget`，按 `status` 值比较决定是否通知）。
- 状态条本体：`TurnStatusLine`（`chat_turn_activity.dart:194-280`），文案生成 `turnStatusWords`（`:162-189`），
  文案裁剪 `_trimStatus`（`:152`，去尾部 `.`/`…`），左侧方块 `_StatusMark`（`:283`）。

### 2.2 挂载点（生产代码仅两处）

| 场景 | 挂载点 | 结构 |
|---|---|---|
| 回合已开始但**还没有正文**（pipeline 占位 / 流式空正文） | `chat_screen.dart:23463`（`_AssistantLiveHeader.build`，类 `:23446-23469`）| `_AssistantNameHeader` → `TurnStatusLine` → `LiveTurnTasks`，包裹 `Padding(12, 5/11, 16, 0)`，与正文 `ChatMessageFrame` 内边距刻意一致（`:23454-23457`）|
| **有正文且在流式**（或终态只要 token 页脚） | `chat_screen.dart:23942`（流式）/ `:23946`（流式无页脚）/ `:23948`（终态 token）| 作为 `ChatMessageFrame.trailing` 传入 |

`_AssistantMessage.build` 的装配（`chat_screen.dart:23932-24019`）：

```dart
Widget? trailing;
if (isStreaming) {
  trailing = showFooter
      ? Column(children: [const TurnStatusLine(), ?_turnUsageTrailing(context, metadata, live: true)])
      : const TurnStatusLine();
} else if (showFooter) {
  trailing = _turnUsageTrailing(context, metadata, live: false);
}
return ChatMessageFrame(... header: ..., children: [...正文...], trailing: trailing);
```

### 2.3 唯一性约束（为什么当前全屏只有一条）

1. **单例注入**：`LiveTurnScope` 全仓只有一处实例化（`chat_screen.dart:15461-15478`），
   位于 `Stack` 内层、`_buildBody()` 之上，与 `_LiveTurnUsageScope`（`:23348`）嵌套；键盘帧复用同一 widget（`:15449-15455` 注释）。
2. **两挂载点互斥**：`_AssistantLiveHeader` 只在「正文为空」时返回（`:19630-19632`、`:19644-19648`）；
   一旦有正文就走 `_AssistantMessage` 的 `trailing`。二者不会同帧共存。
3. **切片约束**：`showFooter` 只有最后一个 chunk 为真（`_AssistantRenderSlice.showFooter`，`:959`），
   所以长回答被虚拟化切成 N 行时，**只有末片**带状态条与 token。
4. **旧的 composer dock 已删除**：测试断言 `find.byKey('composer-status-dock')` 为 `findsNothing`（`test/chat_screen_test.dart:33889`）。
5. **活动卡片不得再重复**：`ThinkingTraceCard` 内部不得出现 `TurnStatusLine`
   （`test/live_status_single_line_test.dart:276-282`）。

> 注意：这里说的「唯一」是**树里只有一个**，不是「固定在输入框上方」。
> 状态条在气泡内部（`ChatMessageFrame` 的 trailing），所以用户向上滚动时它会跟着最新气泡一起离开视口。
> 这一点与测试断言一致（断言的是 y 坐标关系，不是「跟随输入框」）。

### 2.4 「正文 → 状态 → token → 输入框」的物理实现

- 气泡内顺序：`ChatMessageFrame` 的 `Column`＝`header` → `children`（正文）→ `Wrap(time, trailing)`（`chat/chat_message_frame.dart:79-97`）。
  `trailing` 字段语义见 `:47-49`；`time` 与 trailing 同处一个 `Wrap(spacing: 6, runSpacing: 2)`，320 dp / 130% 字号时换行而不溢出（`:86-91` 注释）。
- 页面底部顺序（`chat_screen.dart:15915-15940`，从下往上）：
  `_buildStopStatusStrip`（`:15915`）→ `_buildBackgroundTaskStrip`（`:15916`）→ `_buildQueueStrip`（`:15917`）
  → 语音带 / 语音返回条（`:15919-15927`）→ **`_buildInputBar()`（`:15936`，`ConsoleComposer` 在 `:18283`）**。
- token 页脚：`_turnUsageTrailing`（`:24441-24464`）→ `_turnUsageText`（`:24467-24507`）。
  结算值读 `_turn_output_tokens` / `_turn_avg_tps` / `_turn_usage_source`（`:24472-24494`）；
  流式中订阅 `_LiveTurnUsageScope.usage`（`:24449-24463`，`isLive` 由 `_chat.isStreaming` 决定，`:15468`）。
  特例：实时通道 `null` = 本回合无 tick（不占位），`0` = 有 tick 但增量为 0（要显示「0 tokens」，`:24473-24476`）。
  样式：`fontSize 10`、`monospace`、`textSecondary`（`:24496-24505`）；文案 key `turnTokens` / `turnRate`（`app_zh.arb:430`、`:438`）。

### 2.5 状态条的数据来源

`LiveTurnScope.status` = `LiveTurnStatus.of(_buildActivitySnapshot())`（`chat_screen.dart:15462-15464`），
`LiveTurnStatus.of`（`chat_turn_activity.dart:51-65`）从 `ActivitySnapshot` 投影出
`active / startedAt / headline / waitingForUser / noActivityHint / step / tasks`，`==` 按值比对（`:83-96`），
所以「只改计时秒数」不会让整行重建。计时器由 `ActivityTicker`（`:269-272`）驱动，使用 `scope.clock`（`_chat.wallNow`）。

---

## 3. 错误气泡

### 3.1 文案取值链（三层）

```
active_chat_service：_failRun(error) → _messages[0] = {'role':'assistant_error','content': error}
        （active_chat_service.dart:29169-29176；有部分正文时插在 :29188-29195）
        ↓
chat_screen._buildRenderUnit（绘制边界，:19526-19530）
        error: localizedChatError( activeChatStoredErrorUiMessage(content), Strings.of(context) )
        ↓
ChatErrorBubble.error（:21013+）→ _ErrorBubbleState 直接绘制 widget.error（:21214-21222）
```

- `localizedChatError` 定义：`lib/core/utils/chat_error_localization.dart:24-50`（**范围外依赖，但它是唯一一层翻译**）。
  它只做 **整串/前缀精确匹配**（8 条常量，`:5-17`），命中即换成 `strings.err*`；
  其余（远端原因、自由文本）**原样返回**，绝不改写散文（`:25-26` 注释）。
- `activeChatStoredErrorUiMessage`：`lib/core/services/active_chat_service.dart:424-440`，只清理旧版本存下的技术格式
  （`TuiGatewayRpcError(prompt.submit, 4090):` 前缀、`hermes reported an error`、socket/websocket 关闭），
  其返回值仍是西语，必须再过 `localizedChatError`。
- 因此：**翻译发生在「渲染前一行」**，服务层无 `BuildContext`，也不感知语言。

### 3.2 两层气泡 UI

`_ErrorBubbleState.build`（`chat_screen.dart:21129-21299`）先分流：

| 条件 | 卡片 | 行号 |
|---|---|---|
| `surface != null || billing != null`（网关给了 `error_surface` / `billing`）| `_PlannedErrorCard`（恢复计划卡，含单主操作 + 详情 + 复制）| `:21133-21135`，类 `:21305` |
| 否则（老服务器）| 文本分类卡：`_ErrorKind` 标题 + 提示 + 动作 | `:21136-21299` |

老卡细节：
- 分类：`_classifyError(widget.error)`（`:21138`）；`_ErrorKind` 只是 **typedef**（`:21004-21005` `typedef _ErrorKind = ChatErrorKind;`），
  枚举本体在 `lib/core/utils/chat_error.dart:6`，分类函数 `classifyChatError` 在同文件 `:61`。
  标题/提示全走 i18n：`_kindLabel`（`:21101-21113`）、`_kindHint`（`:21115-21127`）。
- 摘要截断 140 字符（`:21145-21149`），超长/多行/鉴权失败才有「查看详情」（`:21150-21154`、`:21282-21290`）。
- 正文直出 `widget.error`（`:21214-21222`），展开时切 `monospace`。
- 动作顺序：重新鉴权 → Dashboard 登录 / 新会话 → 重试 → 重启网关 → 查看详情（`:21240-21291`）。
- 署名 `'▸ hermes'` 是硬编码（`:21168`），属品牌名，不入 i18n。

### 3.3 本范围内仍硬编码西语的地方

1. `chat_screen.dart:3922` 与 `:3925`（`_recoveredTurnMessage`，`:3911-3926`）
   —— 手写 `english ? ... : '西语'` 三元，**中文用户拿到西语**。展示位置是通知岛的展开详情
   （`IslandEvent.more`，事件构造 `:7655-7698`，`.more` 组装在 `:7689-7692`）。
2. `'▸ hermes'`（`:21168`）—— 品牌署名，可接受但确实是硬编码。
3. 服务端穿透文案（范围外、但渲染在本范围的气泡里）：见 §5 第 4-9 行。
   `localizedChatError` 的常量表覆盖不到它们（`chat_error_localization.dart:5-17`），所以原样显示。

> 已核对：`chat_event_cards.dart`、`chat_turn_activity.dart`、`chat/chat_message_frame.dart`、
> `message_avatar_header.dart`、`chat_render_projection.dart`、`chat_content_screen.dart`
> **没有任何带西语重音符号的字符串字面量**（`grep -nE "'[^']*[áéíóúñ¿¡][^']*'"` 全部零命中，注释除外）。

---

## 4. 改动手册

### 4.1 改「状态条位置」

| 想改的东西 | 改哪里 | 备注 |
|---|---|---|
| 状态条**在气泡尾部**的位置 / 与 token 的上下关系 | `chat_screen.dart:23932-23949`（`trailing` 组装）| 目前是 `Column(status, token)`；想「token 在上」就换 `children` 顺序 |
| 状态条**在空正文回合**的位置（名字下方） | `chat_screen.dart:23446-23469`（`_AssistantLiveHeader`）| 内边距需与 `ChatMessageFrame.padding`（`:23958-23963`）保持一致，否则「第一段文字到达时名字会跳」|
| 状态条**文案**（Pensando / Trabajando / 步骤词） | `chat_turn_activity.dart:162-189`（`turnStatusWords`）+ `:167-188` 的分支 | 词条：`chaTurnStillWorking` / `liveWaitingForUser` / `liveHeaderWorking` / `chaPipelineThinking`（`app_zh.arb:2747`、`:4061`、`:4118`、`:601`）|
| 状态条**视觉**（字号、方块、换行） | `chat_turn_activity.dart:194-280`；字号常量 `TurnType.status = 13`（`:27`）| `maxLines: 3`（`:243`）|
| 状态条**是否出现**（例如终态也保留） | `chat_screen.dart:23936-23949` 的 `if (isStreaming)` 条件 | 改这里等于改「唯一性」语义，必须同步测试 |
| 状态条**数据**（新状态词/新步型） | `chat_turn_activity.dart:37-113`（`LiveTurnStatus`）+ `chat_screen.dart:15461-15478`（注入）| `==` / `hashCode` 需同步，否则要么多重建要么不刷新 |
| 彻底改到「悬浮在输入框上方」 | 不建议在 `trailing` 里改；应新增 overlay 并**删掉** `:23942`、`:23463` 两处，否则会有两条 | 历史上 `composer-status-dock` 已因此被删除（`test/chat_screen_test.dart:33889` 断言它不存在）|

**必跑测试**（全部与「只有一条 + 顺序」直接相关）：

- `flutter test test/live_status_single_line_test.dart`
  （A `:249`、B `:323`、C `:364`：一条状态条 + `body.bottom ≤ status.top`、`status.bottom ≤ token.top`、`token.bottom ≤ input.top`，断言在 `:289-314`）
- `flutter test test/chat_replying_1215_test.dart`（group `ct1215 status line of the live turn`，`:373`；`statusLine()` finder `:289`；「失败/停止后不留活行」`:776`、`:799`）
- `flutter test test/ct1215_turn_in_transcript_test.dart`（group `status line`，`:214`；`when it ends` `:695`；320 dp / 2x 字号 `:948`、`:1012`）
- `flutter test test/chat_screen_test.dart --plain-name "turn status line"`（`:3986` dock 位置、`:4028` 空闲时不存在）
- 相关唯一性断言：`test/chat_screen_test.dart:33889`、`:21987`、`:27031`

### 4.2 改「错误文案」

| 想改的东西 | 改哪里 |
|---|---|
| **新增**一条服务端常量 → 要翻译 | ① `lib/core/utils/chat_error_localization.dart:5-17` 加常量 → ② `:29-42` 加 `case` → ③ 三个 arb 加 key（模板是 `app_es.arb`，见 `l10n.yaml`）→ ④ `flutter gen-l10n` |
| 改**已有** 8 条之一的措辞 | `app_zh.arb:7281-7288`（`err*` 段）+ `app_en.arb` + `app_es.arb`（模板，`@` 元数据在 es） |
| 改**气泡标题/提示/按钮**（「连接错误」「查看详情」「重试」…） | `chat_screen.dart:21101-21127`（映射）+ arb 的 `chaErr*` / `chaRetry` / `chaErrViewDetails`（`app_zh.arb:518-586`）|
| 改**新式恢复卡**（`error_surface` 驱动） | `chat_screen.dart:21305` `_PlannedErrorCard` + `lib/core/models/turn_error_surface.dart:42` `TurnErrorSurface` / `:127` `TurnBillingBlock` |
| 改**分类逻辑**（哪些文本算连接/模型/工具错） | `lib/core/utils/chat_error.dart:61` `classifyChatError`（枚举 `:6` `ChatErrorKind`；`chat_screen.dart:21005` 只是 `typedef _ErrorKind = ChatErrorKind`）|
| 改**服务端句式**（prompt 失败） | `lib/core/services/active_chat_service.dart:370-419` `activeChatPromptFailureUiMessage`；注意它只有 `en/es` 两支，**新增语言要同时补 `localizedChatError` 或改签名** |

**必跑测试**：

- `flutter test test/chat_screen_test.dart --plain-name "te1215"`（group `te1215 failed turn cards follow the recovery plan`，`:37961`；
  用例 `:38027` 用量限制 + 重置时间、`:38106` 新回合撤销重试、`:38218` 无 `error_surface` 走老卡、`:38239` 无错误不显示、`:38388` OAuth 撤销、`:38950` 非鉴权失败、`:38971` 412×915 截图）
- `flutter test test/chat_screen_test.dart --plain-name "a provider wait shows on the turn status"`
  （`:38257`，错误态与状态条联动）
- 改了 `localizedChatError` 常量表时，加一条「zh 断言」：现有测试用 `es` locale 跑（`test/live_status_single_line_test.dart:147-148`），
  **不会**替你验证中文；需要另外用 `Locale('zh')` 断言。

### 4.3 改「消息分组 / 折叠」

| 想改的东西 | 改哪里 |
|---|---|
| assistant 连续行是否合并成一条气泡 | `chat_render_projection.dart:84-88`（`_joinsResponseGroup`）+ `:269-292`（`addAssistantUnit` 的边界条件）|
| steer 用户消息是否并入上一轮 | `chat_render_projection.dart:341-354` |
| 工具事件是否聚合成一条 | `chat_render_projection.dart:294-303`、`:388-399`；渲染 `chat_screen.dart:19392-19394` → `chat_event_cards.dart:571` |
| 长回答切几片（虚拟化粒度） | `chat_screen.dart:10015` `_assistantRenderPlanFor`（`_assistantChunkMaxChars`）、`:9998-10005` 展开、`:951-960` `_AssistantRenderSlice`（`showHeader = index == 0`、`showFooter = last`）|
| 折叠行样式 / 展开交互 | `chat_turn_activity.dart:1053` `TurnFoldLine`；折叠内容 `TurnTasksHistory` `:1015`、`TurnReasoningQuote` `:576`、`TurnToolRow` `:672` |
| 活动轨迹卡（「Pensó ⌄」）| `chat_event_cards.dart:1715` `ThinkingTraceCard`；在气泡里的挂载 `chat_screen.dart:23970-23994`（`showTrace` 分支）|
| 合并后的元数据/时间/身份取哪一行 | `chat_screen.dart:19467`（`_responseGroupMetadata`，取最新行）+ `chat_render_projection.dart:94-` `mergeAssistantResponseGroup` |
| 列表缓存失效 | `chat_render_projection.dart:452` `canReuseFor`；`chat_screen.dart:9930-9933` 的 `identical(_listEntriesProjection, projection)` 快路径 |

**必跑测试**：

- `flutter test test/ct1215_turn_in_transcript_test.dart`（`when it ends` `:695`、`:714` 两条安静行、`:736` 展开后顺序、`:867`「完成的计划一行说完」、`:878` 只思考的回合）
- `flutter test test/chat_replying_1215_test.dart`（`:635` 完成后折成两行并可展开、`:733` 旧回合保留折叠行、`:891`「回合状态只有一个主人」）
- `flutter test test/chat_screen_test.dart --plain-name "historial fallido usa error estático en cabecera y actividad"`（`:27120`）
- `flutter test test/chat_screen_test.dart --plain-name "turno detenido conserva trace con estado neutral veraz"`（`:27189`）
- 大改分组后建议加跑：`test/chat_scroll_1215_test.dart`（`:855` 有 `turn-status-line` 断言）

---

## 5. 用户可见错误文案清单（本范围）

> 「已本地化」= 经过 `localizedChatError` 或 `Strings` 词条；「否」= 直接显示西语。

| # | file:line | 原文（截断） | 触发场景 | 本地化 |
|---|---|---|---|---|
| 1 | `lib/core/screens/chat_screen.dart:3922` | `Hermes no pudo reanexar un turno que aún podría seguir activo. Enviar repite la comprobación; descarta solo tras verificar Hermes porque esto no cancela el turno remoto.` | 恢复回合 `state ∈ {accepted, running}`（`_showHiddenRecoveredTurn` → 通知岛 `recovered-turn` 展开详情，`:7661-7692`）| **否**（手写 en/es 三元，`:3916-3922`）|
| 2 | `lib/core/screens/chat_screen.dart:3925` | `Se recuperó un turno pendiente. Descarta la recuperación para continuar.` | 恢复回合，状态既非 `ambiguous` 也非 `accepted/running`（`:3917-3925` 的最后一个 else；en 版本 `:3924`）| **否**（同上）|
| 3 | `lib/core/screens/chat_screen.dart:21168` | `▸ hermes` | 所有老式错误气泡署名 | **否**（品牌名，可不译）|
| 4 | `lib/core/services/active_chat_service.dart:385-386` | `Hermes está ocupado (por ejemplo, compactando la conversación). Tu mensaje sigue en el composer: inténtalo en un momento.` | `prompt.submit` 返回 4009 且无 reason（会话正忙/正在压缩）| **否**（只有 en/es；且不匹配 `localizedChatError` 常量表）|
| 5 | `lib/core/services/active_chat_service.dart:395-397` | `No se puede continuar en directo porque esta conversación pertenece a otro gateway o proceso…` | `prompt.submit` 失败，`reason == sessionNotOwned` | **否**（与 `_ownershipConflict` 常量字面不同，`chat_error_localization.dart:12-13` 不匹配）|
| 6 | `lib/core/services/active_chat_service.dart:402-403` | `Hermes alcanzó el límite configurado de sesiones activas…` | `reason == maxConcurrentSessions` | **否** |
| 7 | `lib/core/services/active_chat_service.dart:408-409` | `Hermes no pudo reservar esta conversación con seguridad…` | `reason == sessionCoordinationUnavailable` | **否** |
| 8 | `lib/core/services/active_chat_service.dart:413` / `:418` | `No se pudo enviar el mensaje. Inténtalo de nuevo.` | `prompt.submit` 其他 reason / 未知 RPC 失败 | **否**（不在 8 条常量表内）|
| 9 | `lib/core/services/active_chat_service.dart:19938` / `:19940` | `No se pudo conservar el estado de un adjunto.` / `El lote de adjuntos cambió durante la subida.` | 附件暂存/批次变化 | **否** |
| 10 | `lib/core/services/active_chat_service.dart:21814` | `Hermes confirmó que el turno falló tras reconectar.` | 重连后 Desktop 回合终态为 failed | **否** |
| 11 | `lib/core/services/active_chat_service.dart:20468` | `El envío perdió su autorización antes de entregarse.` | 发送前授权丢失 | **是**（与 `_sendAuthLost` 完全一致，`chat_error_localization.dart:17` → `errSendAuthLost`）|
| 12 | `lib/core/utils/chat_error_localization.dart:5-17`（8 条常量）| `No se pudo recuperar el turno…` 等 | 服务端各类固化失败 | **是**（`app_zh.arb:7281-7288`）|

其余用户可见文案（状态条、token 页脚、错误分类标题/提示/按钮）全部走 `Strings`，已本地化：

- 状态：`chaTurnStillWorking`(`app_zh.arb:2747`)、`liveWaitingForUser`(`:4061`)、`liveHeaderWorking`(`:4118`)、`chaPipelineThinking`(`:601`)
- 页脚：`turnTokens`(`:430`)、`turnRate`(`:438`)
- 错误标题/提示：`chaErr*`（`app_zh.arb:518-586` 区间，具体 11+9 条由 `chat_screen.dart:21101-21127` 映射）

### `app_zh.arb` 结构与 key 规则（速查）

- 顶层 `"@@locale": "zh"` + 扁平 key；占位符紧跟在同名 `@key` 对象里（`app_zh.arb:10-18` 示例）。
- key 命名：`小写区段缩写 + 驼峰语义`，区段缩写例：`cha`(chat)、`tc1215`/`ct`/`rp1215`/`fh1215`/`cs1215`/`sp1215`(按批次/评审代号)、`sa`(shared attachments)、`te`(turn error)、`err`(错误常量)、`turn`(用量)、`live`(活回合)。
  末尾 `1215` 为批次/代号（确切含义**未验证**，但从 `tc1215`/`rp1215`/`fh1215` 并存看是「同一轮评审的不同子域」）。
- 生成物：`l10n.yaml` 指定模板 `app_es.arb`、输出类名 `Strings`；三份语言 `app_es.arb`(9477 行，含 `@` 元数据)、`app_en.arb`、`app_zh.arb`(7289 行)。
- 新增 key 必须同时改三份 arb，否则 `flutter gen-l10n` 会缺字段（`Strings` 的 getter `nullable-getter: false`）。

---

## 6. 相关测试地图（只列渲染/错误/状态）

| 文件 | 关注点 | 关键行 |
|---|---|---|
| `test/live_status_single_line_test.dart` | **唯一性与顺序的权威用例**：A 有正文流式、B 首 token 前、C 无 token 页脚 | A `:249`、B `:323`、C `:364`；断言 `:274`、`:289-314`、`:339`、`:382` |
| `test/chat_replying_1215_test.dart` | 活回合状态行/思考引用/工具行/等待用户；回合结束后折叠；「状态只有一个主人」 | 辅助 `:287-300`；group `:373`；折两行 `:635`；旧回合 `:733`；失败/停止不留活行 `:776`、`:799`；`rp1215` group `:843`、`:891` |
| `test/ct1215_turn_in_transcript_test.dart` | 状态行文案/计时/Semantics、工具与任务行顺序、折叠展开、320 dp + 2x 不溢出 | group `status line` `:214`；`while it works` `:324`；`when it ends` `:695`；失败工具用错误色 `:673`；小屏 `:948`、`:979`、`:1012`；`findsNothing` `:724`、`:901` |
| `test/chat_screen_test.dart` | 状态条位置（`:3986`）、空闲不存在（`:4028`）、te1215 错误卡全套（`:37961` 起）、用量限制/重试归属、错误卡截图、状态行唯一性（`:33889`、`:21987`、`:27031`）| 见 §4.1 / §4.2 的 `--plain-name` 列表 |

`test/chat_screen_test.dart` 文件极大（约 42k 行），**不要整跑**；用 `--plain-name` 过滤（上方命令已按用例标题给出）。

---

## 7. 未验证 / 需要留意

- `_classifyError`（`chat_screen.dart` 内）的具体实现行号未逐条核对——**未验证**；但其输入输出类型已确认是 `ChatErrorKind`（`:21005`）。
- `ChatErrorKind` / `classifyChatError`（`lib/core/utils/chat_error.dart:6`、`:61`）既服务错误气泡，也服务刷新提示
  （`chat_screen.dart:18974-18977` 的 `errorMessage`）；气泡里的 `_ErrorKind` 就是它的别名（`:21005`），**是同一套分类**。
- `active_chat_service.dart` 中 `_failRun` 的文案是否会被上层替换（例如 `terminalText` 覆盖）取决于 `hasPartial` 分支（`:29153-29196`）；上表按「无部分正文」路径判定为可见——**未验证**「有部分正文时是否也一定会显示同一句」。
- `chat_content_screen.dart` 是「会话内容（链接/图片/文件）」独立页（`:26-50`），只读 `widget.transcript()`（`:66-74`），**不参与**聊天流渲染；若要做「消息分组」相关工作不必动它。
- 通知岛本体在 `lib/core/widgets/island.dart:1120` `ChatIsland`，挂载在 `chat_screen.dart:8064-8131`（`_buildFloatingHeader`），
  notices 来自 `HermesNotice.feedOf(context)`（`:8118-8120`），抽屉打开时置 null（避免压住抽屉）。
