# 跨仓修改计划（2026-10-28）

审计两侧源码后得出的待修项。**本文件是计划，不是执行记录**；每条都带 `file:line` 证据。

审计方式：两个只读子 agent 分别扫服务端契约面与客户端消费面，主 agent 逐条核实关键结论。

各节标题的方括号标记是**执行状态**，不是审计状态：`[已修]` = 代码或文档已落地并提交；
`[已核实 · 未修]` = 事实确认成立但没动代码；`[部分已修]` = 见备注。没有任何标记的条目
说明还没核实。

## 进度（2026-10-28 11:30）

| 项 | 状态 |
|---|---|
| P0-1 服务端 `ARCHITECTURE.md` 的 Do-not-deploy | **已修**（2026-10-28 提交 `950d9cc416`） |
| P0-2 客户端契约文档两处事实错 | **已修**（提交 `ffebc0b`） |
| P2-1 `chat_core.md` 行号 | **部分**：表格 9 个入口按 `977966f` 重核；正文仍是 10-26 快照，已在头部标注偏移不统一 |
| P2-2 ack 必填字段 | **已修（文档）**：`duplicate` 确为 bool，`server_turn_id` 在可达路径上必非空——保证来自**顺序**（`:1305` 的 claim 先于 `:1380`/`:1462` 两处 ack；typed-stop 走 `:1218` 自己的 claim，`:1221` 守卫），`or ""` 与 `= None` 是不可达防御默认。已写进契约 |
| AGENTS.md 两条规则（文档同步 / 改前审核） | **已完成**（两侧） |
| P1-1 `user_row_id` 未消费 | **已修**：ack 解析 + 写进 `_desktopRowId`（只补空缺）；4 条解析测试 |
| P1-2 排队消息转向/改写 | **RPC 层已修**：queued 返回 `admission_id`、新增 `steerQueuedPrompt`/`replaceQueuedPrompt`（4 条测试）。**UI 未接线**，用户仍无入口 |
| P1-3 `snapshot_required` / `session_authority` | **部分**：`snapshot_required` 已消费（缺键=不需要）；`session_authority` 判定不做——与 `truncated` 同源同值、今天接入零收益，且无消费点 |
| P2-3 `_fetchReplay` 不回传 `replay_epoch` | **已修**：`session.events.since` 带上 epoch（authority 路径用它判 missing） |
| P3-1 kanban 丢弃批次不回退游标 | **已修**：按 claim 段从新到旧 CAS 回退 + 300s hold 防 retry storm；6 条测试（含真实 sqlite 游标断言）。**已知隐患**：一条 claim 横跨 diagnostic/result 两半时，被拒那半仍会丢（退回必重复），日志会报 |
| P3-2 错误码语义 | **已修（文档）**：实测 **110 个码 / 412 处**（grep 只数 `_err(rid, NNNN` 会漏常量、三元、dict 查表），同码多义（4001 有 4 种含义），故不建表；写清「4xxx 62 个 / 5xxx 48 个 + `data.reason` 有 30+ 个值（含大写与转发的 ledger refusal）」 |

标题里的标记含义：`[已修]` 代码或文档已落地；`[已核实 · 未修]` 事实确认成立但没动代码；
`[部分已修]` 见备注；`[未核实…]` = 连事实都还没确认，比「未修」更早一步。
**没有 `[已修]` 前缀的项都还没做**——标题里出现任何标记都不代表完成。

---

## P0 — 已错 / 会误导，必须先修

### P0-1 服务端架构文档说「不要部署」，但缺口已修完 `[已修]`

服务端仓库 `docs/ARCHITECTURE.md:42-54` 写着：

> This is not complete lifecycle protection: a busy claim can cross Stop before its later
> queue commit, and the final inner prompt-turn worker does not yet carry the outer admission
> token through publication/start/entry. ... **Do not deploy this candidate** until both are
> repaired and reviewed.

**这两个缺口正是补丁 0002 修掉的**：
- busy claim 跨 Stop → `_commit_busy_queue` 在提交锁内复核取消代次（`session_auto_continue.py`）
- inner worker 不带 admission → admission 贯穿到 `prompt-turn-*` 入口（`prompt_turn.py`）

而且**已经部署**（2026-10-27 20:42 起）。文档停在 10-26，会让人误判当前状态。

**改**：把该节改为「已修复 + 修复点 + 证据位置」，保留历史缺口描述但标明已闭合。

### P0-2 客户端契约文档两处事实错误（我 10-28 引入）`[已修]`

`C:\hermes-console\docs\UPSTREAM_CONTRACT.md:57-77`：

| 写错的地方 | 事实 |
|---|---|
| 「`session.info` / `session.resume` 可能带 `last_sequence`」 | `last_sequence` / `replay_epoch` 只在 `LiveSessionSnapshot`（`sessions.py:104-105`）根上；canonical `session.info`（`canonical.py:176-205`）没有这两个字段 |
| 「`events.since` takes the process epoch back as `replay_epoch`」 | 服务端是 "Accepted and ignored"（`sessions.py:732-735`），且客户端 `_fetchReplay` 只发 `session_id`+`last_seen`（`tui_gateway_client.dart:2843-2846`） |

**改**：按事实改写，并写清客户端真实做法（从 `gateway.ready` 采纳 epoch，等值比较）。

---

## P1 — 契约缺口，影响功能

### P1-1 客户端没用 `user_row_id`，改用全文 REST 扫描 `[已修]`

- 服务端提供：`prompt_voice.py:81`（该次提交写入的 user row id）
- 客户端现状：`tui_gateway_client.dart:8536-8573` `resolveDurableUserRowId` 拉全量历史按**文本匹配**
- 后果：同文本多行时返回 null → `active_chat_service.dart:16397` 抛
  `The message can no longer be edited safely`

**改**：优先用 ack 的 `user_row_id`；拿不到再回退到现有扫描。

### P1-2 排队消息无法转向/改写 `[RPC 已修 · UI 未接线]`

- 服务端提供：`admission_id` + `status: queued/steered/redirected`（`prompt_voice.py:84-95`）；
  方法 `prompt.steer_queued` / `prompt.replace_queued`（`canonical_sessions.py:332,341`）
- 客户端现状：`admission_id` 在 `lib/` 零引用；两个方法零引用
- 后果：消息排队后只能等，不能改

**待核实**：这两个方法是否真的注册在 `/api/ws`（canonical 方法不在 `METHODS` 里，
`registry.py` 的 `assert_complete` 只覆盖 258 个非 canonical 方法）。若未注册，此条降级为
「服务端未暴露」，先补服务端注册再谈客户端。

### P1-3 `snapshot_required` / `session_authority` 未消费 `[部分已修]`

- `CanonicalEventsResult.snapshot_required`（`canonical_sessions.py:315`）：客户端只读
  `truncated`/`epoch`/`latest_seq`（`replay_batch_proof.dart:47-83`），靠推断代替显式信号
- `GatewayReadyPayload.session_authority`（`events.py:60`）：零引用，客户端只能靠 `-32601` 探测

**改**：接入 `snapshot_required`（服务端明确要求重取快照时立刻取）；`session_authority` 次优先。

---

## P2 — 健壮性与文档

### P2-1 `docs/_map/chat_core.md` 行号偏移 `[部分已修：表格入口已重核，正文未重算]`

报告称 `active_chat_service.dart` 的行号统一比实际**小 14 行**，且开头两句
「行号均已核对」「lib/ 多文件已改未提交」已失效（当前 `git status` 只有 docs 改动）。

**改**：重算行号，删掉两处失效声明。**这是机械工作，必须脚本核对，不能凭印象。**

### P2-2 隐式契约没写：进入 ack 的字段必填 `[已修（文档）]`

- 服务端 6 处填 `duplicate`，全是 bool（`methods_prompt.py:1021,1101,1334,1464`、`session_auto_continue.py:521,581`）→ 客户端强制 `duplicate is! bool` 抛错**是对的**
- `server_turn_id` 有两处防御性默认：`entry.get(...) or ""`（`methods_prompt.py:1019`）、
  `server_turn_id = None`（`:1434`）。**但两者都不可达**：`_lock_in_submit_turn` 在 `:1305`
  先 claim（`:1145`），claim 被拒则 `:1153` 返 5038 提前退出；两处 ack（`:1380`、`:1462`）
  都在其后。typed-stop 走自己的 claim（`:1218`），`:1221-1222` 有 absent-key 前置返回，
  其 ack 在 `:1230`（早于 `:1305`，所以「顺序」是按路径成立，不是一次全局 claim 挡住所有 ack）。
  `:1327` 那处也有 `entry is None` 前置返回。
  所以可达路径上 `server_turn_id` 必非空，客户端要求非空（`tui_gateway_client.dart:1283-1288`）**也是对的**

**改**：契约文档写明两者必填，并说明保证来自**顺序**（claim 先于 publish）而不是函数自身检查——
否则以后有人把 ack 挪到 claim 之前就会变成真的客户端崩溃。
**不改服务端**：`or ""` 与 `= None` 是防御默认，换成断言不会增加安全性，反而在不可达路径上引入崩溃风险。

**明确不做**：不把客户端的 `duplicate` 检查降级为可选。服务端保证总填，收紧是对的。

### P2-3 `_fetchReplay` 不回传 `replay_epoch` `[已修]`

客户端只发 `session_id`+`last_seen`（`2843-2846`）；换进程只能靠响应里的 `epoch` 事后发现。

**改**：请求带上已知 epoch，把「事后发现」变成「请求时判定」。次优先——当前靠响应 epoch
也能收敛，只是多一轮。

---

## P3 — 服务端内部债务

### P3-1 kanban 批次丢弃不回退游标 `[已修]`

连续 3 次拒绝后 `pop("_kanban_pending")`（`session_notifications.py:596-605`），但事件已被
`claim_unseen_events_for_sub` 原子推进（`kanban_db_notify.py:352-381`），这条 refusal 路径从不调用
`rewind_notify_cursor`（定义在 `kanban_db_notify.py:421-436`；另一路径 `gateway/kanban_watchers.py:150` 有调用，与本路径无关）
→ 该会话的 kanban 通知**永久丢失**。

**改**：让 `_kb_poll_board` 返回 `(text, (sub, old, new))`，与 pending 同构缓存；丢弃时逐条
`rewind_notify_cursor(conn, claimed_cursor=new, old_cursor=old)`（CAS 保证不覆盖更新的进度）。

### P3-2 无机器可读错误码表 `[已修：改为「码是粗分类」约定，不是建表]`

实际在用 12 种码（4001/4002/4004/4009/4015/4018/4030/4064/4090/4095/4124/4404/5011/5035…），
契约 docstring 只提 4000/4006/4015；客户端只对 4095 有文档。

**改**：`contracts/` 增 `WireError` 枚举，方法契约上标注可能的码。

---

## 明确不做

- **不降级** `DesktopTurnAck` 的 `duplicate`/`state` 严格检查（服务端保证填，收紧是对的）
- **不接 canonical-only 方法**（`session.info`、`kanban.run` 不在 `/api/ws` 的 258 个注册方法里，
  客户端调了只会收 `-32601`）
- 不动 UI、不动 voice、不重构

---

## 执行分批

| 批次 | 内容 | 档位 | 门 |
|---|---|---|---|
| **A** | P0-1、P0-2、P2-1 | 微档（文档） | 无独立票，留读回证据 |
| **B** | P1-1、P1-3、P2-2、P2-3 | 中档（客户端代码） | spec + 独立票；**但 `flutter test` 本机跑不了**，验收只能靠 analyze + 人工 |
| **C** | P3-1、P3-2 + P1-2 待核实 | 中档（服务端） | spec + 独立票；测试环境可用 |

**推荐顺序**：A（今天，纯文档纠错，风险为零）→ C（服务端，测试能跑，可验证）→ B（客户端，
受测试环境限制，最后做，且只做能人工验证的部分）。

## 已知阻塞

`flutter test` 在本机无法执行：`flutter.bat` 需要 `PowerShell.exe`（bash PATH 缺），
补进 PATH 后又被安全策略拦 `wsl.exe`（程序黑名单）。**客户端改动只能靠 `flutter analyze`
+ 人工验证**，没有测试证据。这条阻塞不解决，B 批次无法达到「过审才推」的标准。
