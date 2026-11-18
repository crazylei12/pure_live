# Kick 恢复（Windows + Android）AI 技术交接

2026-11-18 · 源码基线 `d7d9c3e8d` · 分支 `master`

## 1. 最新有效需求与边界

用户当前要求：

1. 停止继续做 UI/设备验证，验证由用户自己完成。
2. 提交并推送当前源码。
3. 生成 Windows 安装包和 Android 安装包（APK）并交付路径。

本批有效范围：

- 在 Android 恢复 Kick 支持：`kick.com` 的 JSON 请求走 Android 原生 `HttpURLConnection`，媒体仍走 dart:io/dio。
- 保留此前 Windows WinHTTP/Schannel 恢复，不改变其行为。
- 不新增 iOS/Linux/macOS Kick 通道；这些平台继续按退役平台处理。
- 用户没有要求版本递增、GitHub Release 或附件上传，本批没有做。
- 旧的“Kick 仅 Windows”要求已被本批 Android 恢复覆盖；“不要顺带新增 Android 通道”的旧边界不再有效。

## 2. 工作区、Git 与发布状态

- 工作区：`D:\purelive`；分支 `master`。
- 本批源码提交：`d7d9c3e8d490130600effdd6cf2412499926e8f8` `feat(kick): 支持 Android 原生 TLS 通道恢复 Kick`，7 个文件，+77/−38。
- 上一源码基线：`f366da1f6`（`docs: 补充 fork 远端 head 查询说明`）。
- 远端：
  - `origin` = `https://github.com/liuchuancong/pure_live.git`，仍无写权限（403）。
  - `upstream` = `https://github.com/Jackiu1997/pure_live.git`，只读。
  - `fork` = `https://github.com/crazylei12/pure_live.git`，本批推送目标。
- **推送状态：源码提交已推送到 `fork/master`。** 远端 head 已核对为 `d7d9c3e8d490130600effdd6cf2412499926e8f8`。
- 本文档和 `docs/PLATFORM_COMPATIBILITY.md` 的更新作为后续 `docs:` 提交推送；文档自身哈希以 `git log` 为准。文档提交不改变应用源码基线。
- 没有版本 tag、GitHub Release、附件上传或 `assets/releases.json` 更新。
- 工作区只剩未跟踪的 `.lcode/` 草稿目录；不要提交。

## 3. 本批源码改动

### 3.1 Android 原生通道

文件：`android/app/src/main/kotlin/com/mystyle/pure_live/NativeHttpChannel.kt`

- `onMethodCall` 新增 `"getKickJson" -> ::executeKickGet`。
- 新增 `executeKickGet(call)`：
  - 只接受 `https` 且 host 为 `kick.com` 的 URL。
  - `requestMethod = "GET"`，`doOutput = false`。
  - 调用 `openConnection(call, url)` 复用超时、代理、重定向、缓存配置。
  - 调用 `applyHeaders` 注入请求头。
  - 返回 `mapOf("statusCode" to statusCode, "body" to responseBody)`。
  - 2xx 读 `inputStream`，非 2xx 读 `errorStream`；沿用 `readBoundedUtf8` 的 8 MB 上限。
- 抽出 `openConnection(call, url)`：超时 1–60 秒（默认 20 秒），支持应用代理，`instanceFollowRedirects=false`、`useCaches=false`、`doInput=true`。
- 抽出 `applyHeaders(connection, headers)`：过滤空名、`DISALLOWED_HEADERS`、含 CR/LF 的值。
- `executeTwitchPost` 改为复用 `openConnection` 和 `applyHeaders`；仍然只允许 `https://gql.twitch.tv`，仍然默认 `Content-Type: application/json`，行为未改变。
- 原生层仍然只放行两个固定主机：`kick.com` 和 `gql.twitch.tv`。不要放宽为任意主机。

### 3.2 Dart 平台门控

文件：`lib/core/platform/native_http.dart`

- 文档注释改为 Windows/Android 双平台。
- `NativeHttp.supportsKick => Platform.isWindows || Platform.isAndroid`。
- `getKickJson` 参数和 MethodChannel 名称不变：`pure_live/native_http`、`getKickJson`、`{url, headers, proxyHost?, proxyPort?, timeoutMillis?}`。

文件：`lib/domains/live/data/platforms/sites.dart`

- `supportedSiteIds`：Windows 或 Android 时加入 `kickSite`。
- `availableSites` 列表：同样按 Windows 或 Android 加入 Kick。
- 退役注释更新为“Windows/Android 原生 TLS 通道通过 Cloudflare 检查；其他平台继续退役”。
- `retiredSiteIds` 仍保留 `'kick'`，用于非 Windows/Android 的退役提示。

文件：`lib/domains/live/data/favorite_room_controller.dart`

- 仅注释更新：v17 为 Windows/Android 恢复；v39 为 Kick 在 Windows/Android 返回。
- `currentSiteCatalogMigration = 39` 未改变，已有用户不需要新迁移。

文件：`lib/shared/platforms/kick/kick_api.dart`

- 仅注释更新：Windows WinHTTP 和 Android HttpURLConnection 均被接受，两者都拒绝其他主机。
- `usesPlatformTls(uri, {native})` 逻辑未改变：只有 `native == true` 且 `https://kick.com` 才走原生通道。
- `_nativeRequest` 仍复用超时、代理、8 MB 上限和取消语义。
- IVS 媒体 `*.live-video.net` 继续走 dio，不要接入只放行 `kick.com` 的原生通道。

### 3.3 测试

文件：`test/shared/platforms/kick_transport_routing_test.dart`

- 移除 `dart:io` 导入，改用 `NativeHttp.supportsKick`。
- 测试名改为 “Kick is registered only where a native TLS channel exists”。
- 断言 `Sites.isSupported/isRetired/isRetiredLink` 与 `NativeHttp.supportsKick` 一致；支持时检查 Kick logo。

文件：`integration_test/native_http_kick_test.dart`

- 头部注释补充 Android 设备运行方式：
  `flutter test integration_test/native_http_kick_test.dart --device-id=emulator-5554`
- 测试体未改变；本批没有在 Android 设备上运行它。

### 3.4 文档

- `docs/PLATFORM_COMPATIBILITY.md`：Kick 从“仅 Windows”改为“Windows/Android”；平台数量改为 Windows 与 Android 各 34 直播站 + IPTV；表格标签改为 `Kick（Windows/Android）`。
- `docs/KICK_WINDOWS_RESTORE_2026_11_18.md`：用户结果说明，已更新为本批交付。
- 本文件：AI 技术交接，已更新为本批交付。
- 历史证据仍在 `docs/PLATFORM_PROBE_2026_09_25.md`：Android `HttpURLConnection` 旧实现（`f1511974`、`76a59f31`、`8435e9e2`）曾在真机通过 1080p60 播放与聊天；这是历史记录，不是本批验收。

## 4. 构建与安装包事实

### 4.1 Windows

- 命令：`tool/build_local_release.ps1 -Target WindowsX64 -Configuration Release -SkipQuality`
- 构建记录：`D:\purelive\local-artifacts\build-records\20261118T010059642Z-build-windowsx64-release.json`
- 安装程序：`D:\purelive\local-artifacts\3.1.19-4108\PureLive-3.1.19-4108-windows-x64-setup.exe`
  - 63,019,623 字节
  - SHA-256 `dfac41982cf3045d7f720df744b60ee4ef472fecff174a9e1ff0fcbbcb7bafba`
  - Authenticode `NotSigned`
  - ProductVersion `3.1.19`
- 便携包：`D:\purelive\local-artifacts\3.1.19-4108\PureLive-3.1.19-4108-windows-x64-portable.zip`
  - 80,987,877 字节
  - SHA-256 `c60a666606d1b5c624fb63207b640b58e1fffff50ef3b5f3e647a4783698c4bc`
- 构建脚本已完成：锁文件依赖解析、FFmpeg 9.0.2 Windows ZIP 哈希核验、install manifest 过滤、便携 ZIP、Inno Setup 安装程序。
- 构建元数据：`WINDOWS_BUILD_METADATA.json` 和 `WINDOWS_SHA256SUMS.txt` 在同目录。
- `source_commit` 为 `d7d9c3e8d`；`tracked_files_dirty=true` 仅因构建期间存在 `docs/PLATFORM_COMPATIBILITY.md` 文档修改，`docs/` 不参与应用打包。

### 4.2 Android

- 命令：`tool/build_local_release.ps1 -Target AndroidArm64 -Configuration Release -SkipQuality`
- 构建记录：`D:\purelive\local-artifacts\build-records\20261118T011120975Z-build-androidarm64-release.json`
- APK：`D:\purelive\local-artifacts\3.1.19-4108\PureLive-3.1.19-4108-debug-signed-android-arm64-v8a-release.apk`
  - 139,036,861 字节
  - SHA-256 `0e207bb2eb15f4845fe084d196909a947933d666dd21a169849a1fe492ba25a9`
  - 包名 `com.mystyle.purelive`
  - versionName `3.1.19`；pubspec 基础 build `4108`；Manifest versionCode `6108`（`--split-per-abi` 的 arm64 偏移 +2000）
  - minSdk 26，targetSdk 37，ABI `arm64-v8a`
  - 18 个原生库，ELF LOAD 对齐 ≥ `0x4000`
  - 关键库：`libmpv.so`、`libffmpegkit.so`、`libflutter.so`、`libapp.so`
  - 签名：V2，证书 `CN=Android Debug`，证书 SHA-256 `4c1b62ecc97b05f78f513889995348c5e35e7bbff78a76727c33caa584208a93`
- 构建脚本已完成：FFmpeg 9.0.2 AAR 哈希核验、APK 包名/版本/ABI/原生库/ELF 对齐/大小/SHA-256 核验。
- `BUILD_METADATA.json` 和 `SHA256SUMS.txt` 在同目录。
- 这是 Release 模式但使用 Debug 证书的测试包，不是正式签名发布包。覆盖正式签名安装前必须先卸载。

## 5. 实际验证记录

环境：Windows 10.0.26200，Flutter 3.47.5（`.fvmrc`），`tool/flutterw.ps1`。

1. **定向测试 + Analyze**
   - 测试命令：`tool/local_ci.ps1 -Scope Focused -SkipPubGet -TestPath <10 个文件>`；测试文件：`kick_transport_routing_test.dart`、`kick_danmaku_test.dart`、`playback_header_resolver_test.dart`、全部 `mirror_danmaku_*`（7 个测试文件）。
   - 结果：62/62 通过；测试阶段 54.8 秒；记录 `local-artifacts/build-records/20261118T011408781Z-quality-focused.json`（`source_commit` 为 `d7d9c3e8d`）。
   - Analyze 命令：`tool/local_ci.ps1 -Scope Focused -Analyze -SkipPubGet`；结果 `No issues found!`（151.2 秒）；记录 `local-artifacts/build-records/20261118T011650353Z-quality-focused.json`。
   - 两轮运行的 `source_worktree_dirty` 均为 `true`，原因是文档修改；业务源码为 `d7d9c3e8d`。
2. **Android 原生 TLS 接口探针（本机运行）**
   - 独立 `HttpURLConnection` 探针，用 javac 21 + d8 编译，通过 `app_process` 在 MuMu Android 15/API 35 x86_64 上运行。
   - 请求 `https://kick.com/stream/livestreams/en?page=1&limit=5`，HTTP 200，13,326 字节。
   - 这是接口级证据，不覆盖应用内页面、播放器或弹幕。
3. **Android x86_64 Debug 构建与启动**
   - `build/app/outputs/flutter-apk/app-debug.apk` 曾安装到 MuMu 模拟器并启动，logcat 出现 Flutter “Fully drawn”。
   - 未进入 Kick 页面做 UI 验收；MuMu 多虚拟显示导致 `adb screencap` 不可用。
4. **Android arm64 Release 构建（第一次失败）**
   - 失败在 `:app:compileReleaseJavaWithJavac`：`GeneratedPluginRegistrant.java` 引用 `dev.flutter.plugins.integration_test.IntegrationTestPlugin`，release classpath 中不存在。
   - 根因：该文件是 gitignored 生成文件，时间戳来自之前的 Debug/集成测试构建；构建脚本使用 `--no-pub`，Flutter 不会重新生成平台插件文件，于是沿用了含 dev 依赖的旧注册表。
   - 修复：运行一次不带 `--no-pub` 的 release config-only，重新生成插件注册表；确认文件时间戳更新且不再引用 `integration_test`，再重跑构建脚本。
   - 临时脚本：`.lcode/android_release_config_only.ps1`（未提交）。
5. **Android arm64 Release 构建（第二次成功）**
   - Gradle `assembleRelease` 141.1 秒；APK 132.6 MB（十进制显示），最终文件 139,036,861 字节。
   - 脚本输出：`Android ELF alignment passed: ABI=arm64-v8a, libraries=18, minimum LOAD alignment >= 0x4000`；`Android APK integrity passed: ... version=3.1.19, manifestVersionCode=6108, minSdk=26, Flutter assets=1306, asset bytes=24669364`。
   - `apksigner verify --verbose --print-certs`：`Verifies`，V2 true，V1/V3/V4 false，签名者 `CN=Android Debug`。
   - `unzip -l` 确认关键库存在；`classes.dex` 含 `getKickJson`、`postTwitchJson`、`pure_live/native_http`、`kick.com`；`libapp.so` 含 `getKickJson`、`kick.com`。
6. **Windows Release 构建**
   - 成功；构建记录和产物见 §4.1。
   - 安装程序未安装运行；只核验了产物元数据和签名状态。
7. **未执行**
   - Android 真机/模拟器应用内 Kick 目录、搜索、房间、播放、清晰度、弹幕、同步弹幕。
   - Pusher 真实连接。
   - Windows 安装程序安装启动。
   - 完整回归门禁（本批使用 `-SkipQuality`，引用此前定向测试与 Analyze 证据）。
   - 架构严格校验（历史基线有一条既有违规，本批未改该文件）。

## 6. 已知缺陷 / 风险

- **构建脚本的插件注册表陷阱**：在 Debug/`integration_test` 构建之后直接跑 `-Target AndroidArm64 -Configuration Release -SkipQuality`，可能因旧 `GeneratedPluginRegistrant.java` 含 `integration_test` 而失败。处理方式见 §5.4；不要手工编辑该生成文件。
- **Kotlin 增量缓存跨盘警告**：首次失败构建出现 `this and base files have different roots`（Pub 缓存在 `C:`，仓库在 `D:`）的 Kotlin 增量缓存错误；第二次构建未再导致失败。若后续干净构建复现，可考虑禁用 Kotlin 增量编译或统一盘符，但不要未经授权修改构建配置。
- **Android 签名**：本机没有 `android/key.properties`，Release 包使用 Debug 证书；不能作为正式发布包。
- **Windows 签名**：安装程序未签名，SmartScreen 可能拦截。
- **Cloudflare 依赖**：Android `HttpURLConnection` 和 Windows Schannel 目前被接受，未来可能再次被拦截。
- **真实行为未验收**：目录、搜索、播放、清晰度、弹幕、聊天、收藏迁移、长时间稳定性均未在本批真实设备 UI 中验证。
- **版本/发布未推进**：仍是 `3.1.19+4108`；没有 tag、Release、正式签名、上传或发布索引。
- **文档构建标记**：两套构建的 `tracked_files_dirty=true` 由仅文档修改导致；应用源码基线是 `d7d9c3e8d`。

## 7. 剩余任务与建议顺序

1. **用户自行安装验证 Android**：先卸载正式签名旧版（如存在），安装 arm64 APK；验证启动、Kick 目录、搜索、房间详情、播放、清晰度、弹幕、同步弹幕、收藏迁移和退出重进。
2. **用户自行安装验证 Windows**：运行 setup.exe，验证 Kick 目录、搜索、播放、清晰度、弹幕、外部打开和收藏；注意 SmartScreen。
3. 如果两平台验收通过，再按 `BUILD_POLICY.md` 的正式交付闭环处理：版本递增、完整回归、正式签名、tag/草稿 Release、上传、签名校验、`assets/releases.json` 刷新。
4. 正式交付前重新确认 `assets/version.json`、`pubspec.yaml`、MSIX 版本、README/Release Notes 和阶段文档的版本同步。
5. 如果后续还要构建 Android Release，先检查 `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` 是否引用 `integration_test`；若是，先重新生成 release 插件注册表。
6. 评估 Android 集成测试在真实设备上的运行；本批没有运行。
7. 不要删除 `.lcode/` 前先确认其中的历史草稿是否还需要对照；不要提交该目录。

## 8. 操作权限与禁止事项

- 当前授权范围：提交/推送本批源码，构建 Windows 与 Android 本机安装包，更新交付文档。
- 设备/ADB/真机验证由用户自行执行；不要主动继续设备操作。
- 不要创建 GitHub Release、上传附件、更新 `assets/releases.json` 或递增版本，除非用户明确要求。
- 不要强推、改写远端历史、删除无关分支或覆盖用户数据。
- 不要提交 `.lcode/`、`android/key.properties`、签名文件、密钥或未脱敏日志。
- 不要把 Debug 证书签名的 APK 描述为正式发布包。
- 不要在没有新证据时声称 Android UI、播放、弹幕、Pusher 或 Windows 安装运行已验收。
- 不要用“重试/刷新/延迟”替代对失败原因的诊断。

## 9. 关键命令

```powershell
# 定向测试 + Analyze（按实际需要替换 TestPath 数组）
powershell -NoProfile -ExecutionPolicy Bypass -File tool/local_ci.ps1 `
  -Scope Focused -SkipPubGet `
  -TestPath test/shared/platforms/kick_transport_routing_test.dart,test/shared/platforms/kick_danmaku_test.dart,test/domains/live/playback_header_resolver_test.dart -Analyze

# 重新生成 Android Release 插件注册表（在 Debug/集成测试构建之后）
powershell -NoProfile -ExecutionPolicy Bypass -File tool/flutterw.ps1 build apk `
  --release --config-only --split-per-abi --target-platform android-arm64 `
  --build-name=3.1.19 --build-number=4108

# Android arm64 Release（本机测试签名）
powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_local_release.ps1 `
  -Target AndroidArm64 -Configuration Release -SkipQuality

# Windows x64 Release
powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_local_release.ps1 `
  -Target WindowsX64 -Configuration Release -SkipQuality
```

> `flutterw.ps1` 的 `--device-id` 必须用长参数；PowerShell 会把 `-d` 绑定到自己的 `-Debug` 开关。

## 10. 关联文档

- 用户结果说明：[KICK_WINDOWS_RESTORE_2026_11_18.md](KICK_WINDOWS_RESTORE_2026_11_18.md)
- 平台兼容性：[PLATFORM_COMPATIBILITY.md](PLATFORM_COMPATIBILITY.md)
- 历史平台探针（Android Kick 旧实现与真机证据）：[PLATFORM_PROBE_2026_09_25.md](PLATFORM_PROBE_2026_09_25.md)
- 历史聊天审计：[KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md](KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md)
