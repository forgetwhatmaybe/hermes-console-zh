# 发布与覆盖安装（UPDATE-APK）

> 一条命令：`C:\hermes-console\build-apk.cmd`
> 目标：手机端每次更新都能**直接覆盖安装**（不卸载、数据保留）。

## 1. 为什么能覆盖安装

Android 允许「覆盖安装」只有三个条件同时满足（缺一条系统就拒装）：

| # | 条件 | 本项目取值 | 校验方式 |
|---|------|-----------|---------|
| 1 | **applicationId 相同** | `dev.xpetalab.hermesconsole`（full 与 play 共用；qa 带 `.qa` 后缀，**不能**用于覆盖主线） | `aapt2 dump badging` 第一行 `package: name=...` |
| 2 | **签名证书相同** | `key.jks` / alias `hermes` / SHA-256 `1bb7c202211fe38559e6c8236dc4d1f1e051a7542cffa8bff18b2ac821d37321` | `apksigner verify --print-certs` vs `keytool -list -v` |
| 3 | **versionCode 不小于已安装的** | 已发布最高 **20000**（`hermes-console-1.3.2+20000.apk`，更早的 1.3.x 是 11630/11631），本仓库 `pubspec.yaml` 用 `1.3.2+20000` | `aapt2 dump badging` 的 `versionCode` |

签名是最容易踩的一条：**签名换了，手机一定拒装**，且必须先卸载才能装（数据全丢）。

## 2. 每次更新的标准动作

```bat
C:\hermes-console\build-apk.cmd
```

脚本可以从**任意目录**调用（内部会 `pushd` 到脚本所在仓库再构建），
依次做（任何一步失败就停下，不静默继续）：

1. 只在本窗口内设置 `JAVA_HOME`（JDK 17）、`ANDROID_HOME`、`PATH`（前置 flutter）：
   **优先用环境变量**，没设才去常见默认位置找并打印 `[INFO]` 提示（见 §6.1）；
2. 读 `pubspec.yaml` 的 `version: X.Y.Z+N`；
3. **版本守卫**（两条独立检查，缺一不可）：新 versionCode 不得低于 `C:\Hermes\downloads`
   里同包名 APK 的最大 versionCode（基线），也不得低于下限 `MIN_VERSION_CODE`（默认 20000，
   可覆盖），否则直接失败退出；
4. 把 `+N` 写回 `pubspec.yaml`（`+N` 只 +1，保留 diff 便于追溯）；
5. `flutter build apk --release --flavor full`（**必须带 `--flavor full`**）；
6. 读回产物：`versionCode` / `versionName` 必须等于期望值，证书 SHA-256 必须等于 `key.jks`；
7. 复制到 `C:\Hermes\downloads\hermes-console-<versionName>+<build>.apk`；
8. 打印 `versionCode` / `versionName` / 证书 SHA-256 / 体积 / 路径。

失败时脚本会把 `pubspec.yaml` 的 version 行还原，所以重复跑是安全的。

只要建包、不想要自增（例如刚手动设过版本号）：

```bat
set "NO_BUMP=1" && C:\hermes-console\build-apk.cmd
```

> 脚本会先清掉变量值的空格（`set "NO_BUMP=%NO_BUMP: =%"`），所以
> `set NO_BUMP=1 && ...` 与分两行写法现在等价，不会再因为尾空格被当成「没设」。
> 仍推荐带引号或分两行，避免空格被别的工具当成值的一部分：
> ```bat
> set "NO_BUMP=1"
> C:\hermes-console\build-apk.cmd
> ```

`NO_BUMP=1` 时版本号不动，两个守卫仍照常检查：当前值必须不低于已发布基线、
不低于下限 `MIN_VERSION_CODE`，否则一样失败退出。

用**同一个** versionCode 重打一次（例如改了代码但版本号不变，救急复现）：

```bat
set "NO_BUMP=1" && set "ALLOW_SAME_CODE=1" && C:\hermes-console\build-apk.cmd
```

`ALLOW_SAME_CODE` 只放开「等于已发布最大 versionCode」这一条，**低于基线永远被拒**——
因为这正是手机拒装的根因（见 §3.1）。

装到设备：

```bat
adb install -r "C:\Hermes\downloads\hermes-console-1.3.2+20000.apk"
```

## 3. 两条硬规则

### 3.1 版本号只许增不许减（本次真实踩坑）

`pubspec.yaml` 原来是 `version: 1.3.1+9631`，打出来的包 `versionCode=9631`；
而已发布、装在手机上的包是：

| 包 | versionName | versionCode |
|----|------------|------------|
| `hermes-console-zh-win-arm64.apk` | 1.3.0 | 11630 |
| `hermes-console-zh-win-arm64-final.apk` | 1.3.0 | 11630 |
| `hermes-console-zh-alias-arm64-v2.apk` | 1.3.0 | 11630 |
| `hermes-console-win-final-1.3.1.apk` | 1.3.1 | **11631**（基线） |

`9631 < 11631` → 手机报「应用未安装」，日志里是 `INSTALL_FAILED_VERSION_DOWNGRADE`。
**签名、包名都没问题，就是版本号倒退了。** 修法：把 `+N` 抬到基线之上（本次 1.3.2+20000），
之后每次 +1，由脚本守卫兜底。

> 为什么是 20000 而不是 11632？留出空间：任何历史包里最大的 versionCode 都可能再变大
> （例如另一个分支出过 11xxx），一次抬到 20000 可以避免反复追基线。

### 3.2 签名必须与 key.jks 一致

`android/key.properties` → `storeFile=C:\hermes-console\key.jks`、`keyAlias=hermes`。
release 构建会校验签名，**不会**降级成 debug 签名。校验命令：

```bat
:: 新包（ANDROID_HOME / JAVA_HOME 见 §6.1；<版本> 用脚本打印的 build-tools 实际值）
"%ANDROID_HOME%\build-tools\<版本>\apksigner.bat" verify --print-certs "C:\Hermes\downloads\hermes-console-1.3.2+20000.apk"
:: 密钥库
"%JAVA_HOME%\bin\keytool.exe" -list -v -keystore C:\hermes-console\key.jks -alias hermes
:: 旧包（对照）
"%ANDROID_HOME%\build-tools\<版本>\apksigner.bat" verify --print-certs "C:\Hermes\downloads\hermes-console-win-final-1.3.1.apk"
```

`<版本>` 就是脚本开头 `[INFO] build-tools <路径>` 打印的那个目录名（36.0.0 / 35.0.0 / 更早），
不要照抄旧文档写死的 36.0.0。路径一律带引号，SDK 装在含空格的目录（如 `C:\Android Sdk`）时也能跑。

三者 `SHA-256 digest` 必须完全一致（当前均为 `1bb7c202…7321`）。
`build-apk.cmd` 已把这条做成硬校验：证书不匹配 → 直接失败，不发布。

## 4. 报错对照表

| 手机上看到 | adb 里的错误 | 原因 | 处理 |
|-----------|-------------|------|------|
| 「应用未安装」 | `INSTALL_FAILED_VERSION_DOWNGRADE` | 新包 versionCode ≤ 已装 | 抬 `+N`，重跑脚本（守卫会先拦住） |
| 「应用未安装」 | `INSTALL_FAILED_UPDATE_INCOMPATIBLE` / `signatures do not match` | 签名与已装包不同 | 见 §5 补救 |
| 「应用未安装」 | `INSTALL_FAILED_APP_NOT_INSTALLED`…（伴随 `OLD` 包残留） | 多用户/残留 | `adb uninstall` 后重装 |
| 「解析包错误」 | — | 传输截断 / APK 损坏 | 重新复制或用脚本重新出包，比对文件大小 |
| 覆盖成功但数据没了 | — | 你卸载过 | 覆盖安装才会保留数据；卸载即清数据 |

## 5. 签名变了怎么补救（会丢数据）

签名不同无法覆盖，只能：

1. **先备份数据**（应用内导出 / `adb backup` / 或至少导出关键会话）；
2. 卸载旧包：`adb uninstall dev.xpetalab.hermesconsole`（或手机设置里卸载）；
3. 装新包：`adb install "C:\Hermes\downloads\hermes-console-<ver>.apk"`；
4. 恢复数据。

**不要**为了让包「能装」去换签名或改包名——那等于换了个 App，用户数据直接断掉。

## 6. 构建环境

脚本本身不写死任何人的绝对路径。它按下面的顺序解析工具链，**环境变量优先**，
没设时才回退到通用默认位置并打印 `[INFO]` 提示；都找不到就在构建前直接失败。

| 变量 | 用途 | 回退顺序（变量缺失时） |
|------|------|----------------------|
| `JAVA_HOME` | JDK **17**（Gradle 要求） | `%USERPROFILE%\.jdks\*17*` → `%ProgramFiles%\Android\Android Studio\jbr` → `%ProgramFiles%\Java\jdk-17` |
| `ANDROID_HOME` | Android SDK（同时写 `ANDROID_SDK_ROOT`） | `%LOCALAPPDATA%\Android\Sdk` → `C:\Android\sdk` |
| `FLUTTER_HOME` | Flutter SDK 根目录 | `C:\flutter` → PATH 里的 `flutter` |
| `DIST` | 发布目录 | `C:\Hermes\downloads` |
| `MIN_VERSION_CODE` | versionCode 下限 | `20000` |

| 项 | 说明 |
|----|------|
| build-tools | 按 **36.0.0 → 35.0.0 → 其它已装版本** 倒序探测，取第一个同时含 `apksigner.bat` 与 `aapt2.exe` 的目录，并打印 `[INFO] build-tools <路径>`；只装了 35.0.0 也能出包 |
| flavor | `full` / `play` / `qa`；**发布必须 `--flavor full`** |

### 6.1 如何设置（一次性，永久生效）

```bat
:: 当前用户永久生效；改完重开一个 cmd 窗口
setx JAVA_HOME "<JDK17_HOME>"
setx ANDROID_HOME "<ANDROID_SDK>"
setx FLUTTER_HOME "<FLUTTER_SDK>"
:: 只对当前窗口生效（临时验证用）
set "JAVA_HOME=<JDK17_HOME>"
set "ANDROID_HOME=<ANDROID_SDK>"
```

占位符对应关系：

- `<JDK17_HOME>`：JDK 17 根目录，目录下应有 `bin\java.exe`、`bin\keytool.exe`。
  IntelliJ 下载的 JDK 通常在 `%USERPROFILE%\.jdks\<版本目录>`，Android Studio 自带的是
  `<Android Studio 安装目录>\jbr`。
- `<ANDROID_SDK>`：Android SDK 根目录，目录下应有 `platform-tools\adb.exe`、
  `build-tools\<版本>\apksigner.bat`。
- `<FLUTTER_SDK>`：Flutter SDK 根目录，目录下应有 `bin\flutter.bat`。

验证：

```bat
echo %JAVA_HOME%
"%JAVA_HOME%\bin\java.exe" -version
echo %ANDROID_HOME%
"%FLUTTER_HOME%\bin\flutter.bat" --version
```

> 系统默认 `JAVA_HOME` 指向 JDK 8 时，不覆盖会报
> `Gradle requires JVM 17 or later to run. Your build is currently configured to use JVM 8`；
> 不设 `ANDROID_HOME` 会报 `[!] No Android SDK found`。脚本里的 `set` 只影响本窗口，
> 不会污染系统环境。

### 常见构建噪声（不是错误）

- `flutter build apk --release`（不带 flavor）会打印
  `Gradle build failed to produce an .apk file`——因为产物叫 `app-full-release.apk` / `app-play-release.apk` /
  `app-qa-release.apk`，flutter 找的是 `app-release.apk`。 **加 `--flavor full` 即可**。
- 多个 `flutter test` 并发时偶发 `loading ... test.dart` 失败或
  `Flutter failed to delete file ... build/native_assets/windows/sqlite3.dll`（文件被另一个 flutter_tester 锁住）。
  串行跑、等 45 秒重试。
- `test/chat_screen_test.dart` 有 9 个用例在 Windows 上失败（图片缓存路径比较 `/` vs `\\`），
  在改动前的 baseline 上同样失败，属既有问题，与本功能无关。

## 7. 历史版本对照

| versionName | versionCode | 文件 |
|------------|-------------|------|
| 1.3.0 | 11630 | `hermes-console-zh-win-arm64.apk`、`-final`、`zh-alias-arm64-v2` |
| 1.3.1 | 11631 | `hermes-console-win-final-1.3.1.apk` |
| 1.3.2 | 20000 | `hermes-console-1.3.2+20000.apk`（本次） |

## 8. 已知行为变化（1.3.2+20000 起：每轮 token 页脚）

这一版在每轮回答下面加了 `1,234 tokens · 56 tok/s` 页脚，有两条**预期内**的表现，
遇到不要当 bug 报：

1. **没有 usage 的回合不显示 token 数字。**
   页脚只在拿到本轮用量时渲染（`tokens <= 0` 直接不画）。服务端没回 usage
   （或本轮没有输出）时，那一行就只有时间，不会出现 `0 tokens` 之类的假数字。
2. **REST 刷新后该轮指标消失（无回填机制）。**
   `_turn_output_tokens` / `_turn_total_tokens` / `_turn_avg_tps` / `_turn_usage_source`
   是 `active_chat_service` 在回合结算时写进内存消息 `metadata` 的**运行时键**，
   既不落库、也不出现在 REST / 导出的消息里。所以下拉刷新、切走再回来、重启 App 之后，
   历史回合的 tokens / tok/s 不再显示；只有本次会话里跑过的回合才有。
   需要历史数字得另做持久化与回填，目前没有。

流式期间显示的数字来自服务端 tick（实时值），回合结束切到结算值，两者不会混用。
