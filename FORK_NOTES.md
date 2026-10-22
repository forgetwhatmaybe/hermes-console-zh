# Fork 说明 / Modifications notice

本仓库是 [xP3ta/hermes-console](https://github.com/xP3ta/hermes-console) 的个人修改版（GPL-3.0）。
上游 Console 是 [Nous Research Hermes Agent](https://github.com/NousResearch/hermes-agent) 的 Android 客户端。

- 基线版本：Console **1.3.0 (versionCode 9630)**
- 基线 commit：`7c51c99`（upstream `main`，2026-10-21 release #209）
- 许可证：**GPL-3.0**，见 `LICENSE`；原版权归 XPeta Lab / 各贡献者
- 本仓库修改部分同样以 GPL-3.0 发布，并保留上游全部版权与许可声明

> GPL-3.0 §5(a) 修改声明：本仓库包含对上述上游源码的修改，修改内容见下节，日期 2026-10-22。

## 本 fork 改了什么

### 1. 简体中文本地化

| 文件 | 改动 |
|---|---|
| `lib/l10n/app_zh.arb` | 新增，4425 条 UI 文案的中文翻译（含 ICU 占位符/复数结构） |
| `lib/main.dart` | `AppLocales.all` 增加 `zh / 中文`；`localeResolutionCallback` 支持 `zh` |
| `lib/core/services/startup_guard.dart` | 启动失败页也识别 `zh`，不再只认 es/en |
| `l10n.yaml` | 无需改，`flutter gen-l10n` 自动把 `app_zh.arb` 生成为 `StringsZh` |

语言入口：**Settings → Appearance → Language → 中文**；系统语言为中文时默认中文。
翻译由本 fork 生成，10 条含复杂占位符的条目回退英文（见 `lib/l10n/app_zh.arb`）。

### 2. Switch instance 支持别名（只改显示名）

| 文件 | 改动 |
|---|---|
| `lib/core/widgets/hermes_drawer.dart` | 实例列表：大字显示 `label`（别名），小字显示 `host:port`；**长按**条目弹出重命名对话框 |
| `lib/core/models/connection.dart` | 复用已有 `label` 字段，**未改**连接参数（host/port/useHttps/kind/apiKey 均不动） |
| `lib/l10n/app_en.arb` / `app_es.arb` | 新增 3 个键：`drawerRenameHint` / `drawerRenameTitle` / `drawerRenameField` |

重命名走 `ConnectionManager.updateConnection`，只持久化 label，并保留原有 key 与 endpoint。

### 3. 构建相关（不改业务逻辑）

| 文件 | 改动 | 原因 |
|---|---|---|
| `android/app/build.gradle.kts` | release 关闭 R8：`isMinifyEnabled=false`、`isShrinkResources=false` | 开启 R8 时 `flutter_secure_storage` 启动读 Keystore 失败，App 显示 “Console could not start” |
| `android/settings.gradle.kts`、`android/build.gradle.kts` | 增加阿里云 Maven 镜像（google/public/gradle-plugin） | 国内网络访问 `dl.google.com` 不稳定；官方仓库仍保留在后备 |
| `.gitignore` | 忽略 `*.jks`、`*.p12`、`.zh/` | 防止签名文件和本地翻译脚本入库 |

## 构建

环境（本机验证）：

- Flutter **3.47.7**（Dart 3.13）
- JDK **17**（Temurin 17.0.18）
- Android SDK **36**，build-tools **36.0.0**
- 先 `flutter pub get`，然后 `flutter gen-l10n`

打包（full = GitHub/直接安装渠道）：

```bash
flutter build apk --release --flavor full --split-per-abi
# 产物：build/app/outputs/flutter-apk/app-arm64-v8a-full-release.apk
```

通用包去掉 `--split-per-abi`。

签名：
- 本仓库**不包含** keystore。`android/app/build.gradle.kts` 从仓库根的 `key.properties` 读取签名配置。
- 需要自签时生成 `key.jks` 并写 `key.properties`（字段：storePassword / keyPassword / keyAlias / storeFile）。
- 自签 APK 与官方 GitHub/Play 版**签名不同**：安装前必须卸载官方版，或使用不同 `applicationId`（`qa` flavor）。

## 以后跟进上游 / 看 diff

```bash
git remote add upstream https://github.com/xP3ta/hermes-console.git   # 只需一次
git fetch upstream
git log --oneline HEAD..upstream/main          # 上游新增了什么
git diff upstream/main...HEAD --stat           # 本 fork 相对上游的全部改动
git diff upstream/main...HEAD -- lib/          # 只看源码差异
```

同步上游（推荐 rebase，保持提交线性）：

```bash
git fetch upstream
git rebase upstream/main
# 冲突集中在 lib/l10n/app_en.arb / app_es.arb / hermes_drawer.dart
flutter pub get && flutter gen-l10n && flutter analyze
flutter build apk --release --flavor full --split-per-abi
```

中文 ARB 的维护：上游新增英文键后，`app_zh.arb` 会缺键，`flutter gen-l10n` 会提示。补齐对应中文即可；缺键时运行时会回退到模板语言，建议每次 rebase 后检查 `untranslated-messages-file`。
（本机翻译脚本在 `.zh/`，含本地 API key，已 gitignore，不入库。）

## 第三方组件 / 引用

- 上游项目：**xP3ta/hermes-console**（GPL-3.0）— 本仓库全部基础代码
- Hermes Agent：**NousResearch/hermes-agent**（MIT）— Console 连接的服务端/Dashboard 契约
- Flutter / Dart（BSD-3-Clause）、Material Icons（Apache-2.0）
- Dart 包（均为各自许可证，完整清单见 `pubspec.yaml`、`THIRD_PARTY_NOTICES.md`、`LICENSES/`）：
  `intl`, `http`, `web_socket_channel`, `shared_preferences`, `flutter_secure_storage`,
  `go_router`, `flutter_markdown`, `markdown`, `flutter_animate`, `flutter_staggered_animations`,
  `home_widget`, `path_provider`, `json_annotation`, `uuid`, `url_launcher`, `package_info_plus`,
  `app_links`, `share_plus`, `gal`, `highlight`, `image_picker`, `cupertino_icons`
- 本 fork 未新增第三方依赖；中文翻译为本仓库原创内容，随 GPL-3.0 发布

## 免责声明

本仓库为个人自用修改，非 XPeta Lab 官方发布。上游作者不对本 fork 的问题负责；签名、构建产物与官方版本不兼容。
