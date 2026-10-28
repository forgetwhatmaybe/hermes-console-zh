# 跨仓修改计划（2026-10-28）

审计两侧源码后得出的待修项。**本文件是计划，不是执行记录**；每条都带 `file:line` 证据。

审计方式：两个只读子 agent 分别扫服务端契约面与客户端消费面，主 agent 逐条核实关键结论
（核实过的标 ✅，未核实的标 ⚠️）。

## 进度（2026-10-28 11:05）

| 项 | 状态 |
|---|---|
| P0-1 服务端 `ARCHITECTURE.md` 的 Do-not-deploy | ✅ 已改写为 closed，附证据与部署 PID |
| P0-2 客户端契约文档两处事实错 | ✅ 已改（`session.info` 字段位置、`events.since` 的 epoch 语义） |
| P2-1 `chat_core.md` 行号 | ⚠️ 部分：表格入口行号已 +14 核对；正文标注「+14 换算」规则，未逐条重算 |
| AGENTS.md 两条规则（文档同步 / 改前审核） | ✅ 两侧已写入 |
| P1-1 / P1-2 / P1-3 / P2-2 / P2-3 / P3-1 / P3-2 | 未开始 |

---

## P0 — 已错 / 会误导，必须先修

### P0-1 服务端架构文档说「不要部署」，但缺口已修完 ✅

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

### P0-2 客户端契约文档两处事实错误（我 10-28 引入）✅

`C:\hermes-console\docs\UPSTREAM_CONTRACT.md:57-77`：

| 写错的地方 | 事实 |
|---|---|
| 「`session.info` / `session.resume` 可能带 `last_sequence`」 | `last_sequence` / `replay_epoch` 只在 `LiveSessionSnapshot`（`sessions.py:104-105`）根上；canonical `session.info`（`canonical.py:176-205`）没有这两个字段 |
| 「`events.since` takes the process epoch back as `replay_epoch`」 | 服务端是 "Accepted and ignored"（`sessions.py:732-735`），且客户端 `_fetchReplay` 只发 `session_id`+`last_seen`（`tui_gateway_client.dart:2843-2846`） |

**改**：按事实改写，并写清客户端真实做法（从 `gateway.ready` 采纳 epoch，等值比较）。

---

## P1 — 契约缺口，影响功能

### P1-1 客户端没用 `user_row_id`，改用全文 REST 扫描 ✅

- 服务端提供：`prompt_voice.py:81`（该次提交写入的 user row id）
- 客户端现状：`tui_gateway_client.dart:8536-8573` `resolveDurableUserRowId` 拉全量历史按**文本匹配**
- 后果：同文本多行时返回 null → `active_chat_service.dart:16397` 抛
  `The message can no longer be edited safely`

**改**：优先用 ack 的 `user_row_id`；拿不到再回退到现有扫描。

### P1-2 排队消息无法转向/改写 ⚠️

- 服务端提供：`admission_id` + `status: queued/steered/redirected`（`prompt_voice.py:84-95`）；
  方法 `prompt.steer_queued` / `prompt.replace_queued`（`canonical_sessions.py:332,341`）
- 客户端现状：`admission_id` 在 `lib/` 零引用；两个方法零引用
- 后果：消息排队后只能等，不能改

**待核实**：这两个方法是否真的注册在 `/api/ws`（canonical 方法不在 `METHODS` 里，
`registry.py` 的 `assert_complete` 只覆盖 258 个非 canonical 方法）。若未注册，此条降级为
「服务端未暴露」，先补服务端注册再谈客户端。

### P1-3 `snapshot_required` / `session_authority` 未消费 ⚠️

- `CanonicalEventsResult.snapshot_required`（`canonical_sessions.py:315`）：客户端只读
  `truncated`/`epoch`/`latest_seq`（`replay_batch_proof.dart:47-83`），靠推断代替显式信号
- `GatewayReadyPayload.session_authority`（`events.py:60`）：零引用，客户端只能靠 `-32601` 探测

**改**：接入 `snapshot_required`（服务端明确要求重取快照时立刻取）；`session_authority` 次优先。

---

## P2 — 健壮性与文档

### P2-1 `docs/_map/chat_core.md` 行号整体偏移 ✅（子 agent 报的偏移量未逐条复核）

报告称 `active_chat_service.dart` 的行号统一比实际**小 14 行**，且开头两句
「行号均已核对」「lib/ 多文件已改未提交」已失效（当前 `git status` 只有 docs 改动）。

**改**：重算行号，删掉两处失效声明。**这是机械工作，必须脚本核对，不能凭印象。**

### P2-2 隐式契约没写：进入 ack 的字段必填 ✅

- 服务端 6 处填 `duplicate`，全是 bool（`methods_prompt.py:1021,1101,1334,1464`、`session_auto_continue.py:521,581`）→ 客户端强制 `duplicate is! bool` 抛错**是对的**
- `server_turn_id` 用 `entry.get(...) or ""`（`methods_prompt.py:1019,1496`），理论上可能为空串，
  而客户端要求非空（`tui_gateway_client.dart:1283-1288`）

**改**：契约文档写明「带 `client_turn_id` 的 ack 中 `duplicate` 必为 bool、`server_turn_id` 必非空」，
服务端把 `or ""` 改成断言/降级，二选一但两边对齐。

**明确不做**：不把客户端的 `duplicate` 检查降级为可选。服务端保证总填，收紧是对的。

### P2-3 `_fetchReplay` 不回传 `replay_epoch` ✅

客户端只发 `session_id`+`last_seen`（`2843-2846`）；换进程只能靠响应里的 `epoch` 事后发现。

**改**：请求带上已知 epoch，把「事后发现」变成「请求时判定」。次优先——当前靠响应 epoch
也能收敛，只是多一轮。

---

## P3 — 服务端内部债务

### P3-1 kanban 批次丢弃不回退游标 ✅

连续 3 次拒绝后 `pop("_kanban_pending")`（`session_notifications.py:596-605`），但事件已被
`claim_unseen_events_for_sub` 原子推进（`kanban_db_notify.py:352-381`），这条 refusal 路径从不调用
`rewind_notify_cursor`（定义在 `kanban_db_notify.py:421-436`；另一路径 `gateway/kanban_watchers.py:150` 有调用，与本路径无关）
→ 该会话的 kanban 通知**永久丢失**。

**改**：让 `_kb_poll_board` 返回 `(text, (sub, old, new))`，与 pending 同构缓存；丢弃时逐条
`rewind_notify_cursor(conn, claimed_cursor=new, old_cursor=old)`（CAS 保证不覆盖更新的进度）。

### P3-2 无机器可读错误码表 ⚠️

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
