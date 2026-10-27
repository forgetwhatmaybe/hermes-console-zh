# 手机中文语音无反应 — 根因与修复记录（2026-10-24）

## 现象

手机 Hermes Console（hermes-console，Flutter/Dart）按麦克风说中文，说完后输入框空白，
无任何提示。纯文字消息正常。切换「Hermes 服务器」听写引擎后依旧。

## 排查过程（按证据链）

| # | 假设 | 结论 | 证据 |
|---|---|---|---|
| 1 | 服务器未收到请求 | 否 | `C:\Hermes\data\logs\gui.log` 18:10:04 / 18:10:16 两条 `[diag] transcribe arrival`，即用户手机的真实语音 |
| 2 | 服务器转写失败/不支持中文 | 否 | 同日志 2-3 秒后 `[diag] transcribe done ... success=True provider='local' transcript='什麼情況?'` / `'啥情況 你聽得到嗎'`；另本机直调 `transcribe_recording()` 返回正确中文 |
| 3 | App 未收到响应 | 否 | HTTP 200 响应正常（本机等价请求实测 `{"ok":true,"transcript":"你好,这是手机语音链录测试。","provider":"local"}`） |
| 4 | **App 收到后把中文当"幻觉"丢弃** | **是（根因）** | `lib/core/services/voice/voice_response_policy.dart` 旧代码见下 |

## 根因

`VoiceResponsePolicy.isLikelySttHallucination()`（防 Whisper 静音幻觉「thanks for watching」
等的过滤器）的「空文本」判定：

```dart
t = t.replaceAll(RegExp(r'[^a-z0-9. ]'), ' ');   // 只保留 ASCII
if (!RegExp(r'[a-z0-9]').hasMatch(t)) return true; // 剩不下 ASCII 字母 → 判为幻觉
```

纯中文转写经过第一行后全部字符被替换为空格 → 第二行判「无内容」→ **整句被静默丢弃**，
输入框保持空白，无提示。该过滤器设计时只考虑西语/英语场景，CJK 为盲区。

服务器端一切正常（转写 2-3 秒返回正确中文），问题只在 App 端这一行。

## 修复

`lib/core/services/voice/voice_response_policy.dart`：

- 新增 `_cjkOrOtherLetters` 正则（CJK 表意文字、假名、谚文、扩展区等真实字母区段，
  **不含** U+FF01..U+FF5E 全角标点——那是标点不是字母）。
- 空文本判定改为：ASCII 清理后无 `a-z0-9` **且** 原文不含任何非 ASCII 字母 → 才判幻觉。
  纯中文/日文/韩文/西里尔等转写因此不再被丢弃；纯标点（`。。。`、`，！？`）仍判为噪声。

测试（TDD，先 RED 后 GREEN）：`test/voice_pro_rc_test.dart`
新增组「transcripciones chinas NO se descartan」，覆盖你好 / 什麼情況 / 混合中英 /
纯 CJK 标点仍丢弃等 9 断言；本文件 18/18 绿。

## 关联修复（同日早前，服务器侧）

`C:\Hermes\app\hermes_cli\dashboard_auth\middleware.py`：basic 模式网关原先忽略手机 App
官方使用的 `X-Hermes-Session-Token` 头（探测 401 → App 不发转写）。已用同一套 HMAC
验签校验该头（+19 行，无新增免鉴权面）。重启后 /api/audio/transcribe 全链路 200。

## 诊断残留（待清理）

`C:\Hermes\app\hermes_cli\web_routers\audio.py` 内两行 `TEMP-DIAG` 日志（arrival/done），
定位完 App 端问题、用户确认手机语音正常后移除。

## 验收标准

手机安装含本修复的 APK（versionCode ≥ 22009）后：
1. 语音设置 → 听写引擎 = Hermes 服务器（已选）。
2. 按麦克风说中文 → 松开 → 中文文字出现在输入框。
3. 服务器 gui.log 出现 arrival + done 且 transcript 非空。
