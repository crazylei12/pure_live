# Kick 恢复（Windows + Android）工作结果说明

2026-11-18 · 源码基线 `d7d9c3e8d`

## 结论

Kick 已在 Windows 和 Android 两个平台恢复到源码，并生成了两套本机安装包：Windows x64 安装程序和 Android arm64 Release APK。Android 端新增了只允许 `https://kick.com` 的原生 `HttpURLConnection` GET 通道，Kick 站点注册、收藏目录迁移和路由测试同步改为 Windows/Android 双平台；媒体仍由普通 dart:io/dio 拉取 `*.live-video.net`。

两套安装包都已通过本机构建、版本、关键文件/原生库和 SHA-256 核验。Android APK 是 Release 构建但使用本机 Debug 证书签名，Windows 安装程序未做 Authenticode 签名；两套包都没有发布 GitHub Release，也没有递增版本号。真实设备上的目录、搜索、播放、清晰度和弹幕验收尚未执行，按你的要求由你自行安装验证。

## 本次提交与变更

- 源码提交：`d7d9c3e8d` `feat(kick): 支持 Android 原生 TLS 通道恢复 Kick`，7 个文件，+77/−38。
- 已推送到 `fork`（`https://github.com/crazylei12/pure_live.git`）的 `master`，远端 head 已核对为 `d7d9c3e8d490130600effdd6cf2412499926e8f8`。
- 本文档及平台兼容性文档的更新作为后续 `docs:` 提交推送；其哈希以 `git log` 为准。原 `origin`（`liuchuancong/pure_live`）仍返回 403，未推送、未强推。
- 没有版本递增：仍是 `3.1.19+4108`。没有创建 tag、GitHub Release 或 `assets/releases.json` 更新。

## 已经具备 / 本次完成

- **Android 原生通道**：`android/app/src/main/kotlin/com/mystyle/pure_live/NativeHttpChannel.kt` 新增 `getKickJson`，只接受 HTTPS 且主机为 `kick.com` 的 GET 请求；复用既有超时（1–60 秒）、应用代理、8 MB 响应上限和请求头注入校验。Twitch 的 `postTwitchJson` 行为保持不变。
- **平台注册**：`NativeHttp.supportsKick` 改为 `Platform.isWindows || Platform.isAndroid`；`Sites.supportedSiteIds` 和平台选择列表在 Android 也加入 Kick。其他平台继续按退役平台处理。
- **收藏目录迁移**：v17/v39 的 Kick 注释更新为 Windows/Android；迁移编号未改变，已有用户不需要新的迁移步骤。
- **数据层复用**：Kick 目录、搜索、房间详情、HLS 质量解析、媒体请求头和 Pusher 聊天沿用现有实现；只有 `https://kick.com` 的 JSON 走原生通道，IVS 媒体主机不经过原生层。
- **测试**：`test/shared/platforms/kick_transport_routing_test.dart` 改为按 `NativeHttp.supportsKick` 断言注册/退役状态，不再硬编码 `Platform.isWindows`。
- **Windows 构建**：Kick 的 Windows WinHTTP/Schannel 通道没有改动；本次 Windows 安装包由同一源码提交重新构建。

## 安装包

### Windows

| 项目 | 值 |
|---|---|
| 安装程序 | [PureLive-3.1.19-4108-windows-x64-setup.exe](../local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-windows-x64-setup.exe) |
| 便携包 | [PureLive-3.1.19-4108-windows-x64-portable.zip](../local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-windows-x64-portable.zip) |
| 版本 | 3.1.19（构建号 4108） |
| 大小 | 63,019,623 字节（安装程序） |
| SHA-256 | `dfac41982cf3045d7f720df744b60ee4ef472fecff174a9e1ff0fcbbcb7bafba` |
| 签名 | 未签名（Authenticode `NotSigned`） |
| 构建记录 | `local-artifacts/build-records/20261118T010059642Z-build-windowsx64-release.json` |

### Android

| 项目 | 值 |
|---|---|
| APK | [PureLive-3.1.19-4108-debug-signed-android-arm64-v8a-release.apk](../local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-debug-signed-android-arm64-v8a-release.apk) |
| 包名 | `com.mystyle.purelive` |
| 版本 | versionName `3.1.19`；pubspec 基础 build `4108`；Manifest versionCode `6108`（arm64 ABI 偏移 +2000） |
| 大小 | 139,036,861 字节 |
| SHA-256 | `0e207bb2eb15f4845fe084d196909a947933d666dd21a169849a1fe492ba25a9` |
| ABI / SDK | `arm64-v8a`；minSdk 26，targetSdk 37 |
| 原生库 | 18 个，含 `libmpv.so`、`libffmpegkit.so`、`libflutter.so`、`libapp.so`；ELF LOAD 对齐 ≥ `0x4000` |
| 签名 | Release 构建，但使用本机 Debug 证书（`CN=Android Debug`，SHA-256 `4c1b62ecc97b05f78f513889995348c5e35e7bbff78a76727c33caa584208a93`） |
| 构建记录 | `local-artifacts/build-records/20261118T011120975Z-build-androidarm64-release.json` |

> **安装提示**：Android APK 与正式发布包的签名不同。如果手机上已安装正式签名版本，直接覆盖会报签名冲突；需要先卸载旧版再安装。Windows 安装程序未签名，SmartScreen 可能提示“未知发布者”。

## 验证结果

| 验证项 | 结果 | 证据 |
|---|---|---|
| Kick 定向测试 | 通过，62 个测试 | `kick_transport_routing_test.dart`、`kick_danmaku_test.dart`、`playback_header_resolver_test.dart` 及全部 `mirror_danmaku_*`；质量记录 `local-artifacts/build-records/20261118T011408781Z-quality-focused.json`（测试阶段 54.8 秒） |
| 全仓 Analyze | 通过 | 质量记录 `local-artifacts/build-records/20261118T011650353Z-quality-focused.json`，`No issues found!`（151.2 秒） |
| Android 原生 TLS 接口探针 | 通过 | 独立 `HttpURLConnection` 探针在 MuMu Android 15/API 35（x86_64）上请求 `https://kick.com/stream/livestreams/en?page=1&limit=5`，HTTP 200，13,326 字节；这是原生接口级证据，不是应用内验收 |
| Android x86_64 Debug 构建 | 通过并启动 | `build/app/outputs/flutter-apk/app-debug.apk` 曾安装到模拟器，logcat 出现 Flutter “Fully drawn”；未进入 Kick 页面做 UI 验收 |
| Android arm64 Release 构建 | 通过 | 脚本核验包名、versionName、基础 build、Manifest versionCode、ABI、18 个原生库、ELF 对齐、文件大小和 SHA-256；见上表 |
| APK 签名 | 通过（V2，Debug 证书） | `apksigner verify --print-certs`：`Verifies`，仅 V2 scheme，证书 `CN=Android Debug` |
| APK 内容抽查 | 通过 | `classes.dex` 含 `getKickJson`、`postTwitchJson`、`pure_live/native_http`、`kick.com`；`libapp.so` 含 `getKickJson`、`kick.com` |
| Windows Release 构建 | 通过 | 打包脚本完成 Flutter 构建、FFmpeg 9.0.2 DLL 哈希核验、Inno Setup 编译；安装程序 ProductVersion `3.1.19` |
| 真实 Android 设备安装/播放 | 未执行 | 按你的要求留给你自行安装验证 |
| Windows 安装/运行 | 未执行 | 安装程序未在本机安装启动；只核验了产物元数据和签名状态 |

补充说明：Windows 构建元数据中的 `tracked_files_dirty` 为 `true`，原因是构建期间工作区有一处仅文档的 `docs/PLATFORM_COMPATIBILITY.md` 修改；应用源码仍是 `d7d9c3e8d`，`docs/` 不参与应用打包。Android 构建同样记录了该文档差异。两套产物的 `source_commit` 均为 `d7d9c3e8d`。

## 已确认未解决的问题

- **应用内 Kick 行为未验收**：没有在 Android 真机或模拟器里实际打开 Kick 目录、搜索、房间、播放、清晰度切换和弹幕；只验证了原生接口、编译产物和既有单元测试。
- **Pusher 未实连**：聊天订阅、`pusher:ping/pong`、断线重连只有单元测试和历史证据，本批没有真实连接 `wss://ws-us2.pusher.com`。
- **Android APK 不是正式签名**：本机没有 `android/key.properties`，Release 构建按脚本回退到 Debug 证书；不能作为正式发布包，也不能覆盖正式签名安装。
- **Windows 安装包未签名**：没有 Authenticode 证书；SmartScreen 可能拦截。
- **版本与发布未推进**：没有版本递增、tag、GitHub Release 或发布索引更新；当前两套包只是本机验证产物。
- **构建环境噪声**：首次 Android Release 构建因旧的 Debug 插件注册表包含 `integration_test` 而失败；重新生成 Release 插件注册表后成功。Kotlin 增量缓存还出现过跨盘根路径警告（Pub 缓存在 C:，仓库在 D:），第二次构建未再导致失败，但后续干净构建仍可能遇到。
- **架构严格校验未在本轮重跑**：历史基线存在一条未批准违规（`lib/domains/recorder/presentation/pages/local_player/local_video_player_controller.dart:15` 导入 `domains/live/domain/global_player_service.dart`），本批未修改该文件。

## 尚未实现 / 仅部分实现

- **Windows/Android 之外的平台**：iOS、Linux、macOS 仍不注册 Kick；继续按退役平台处理。
- **正式发布流程**：版本递增、完整回归门禁、正式签名、草稿 Release、上传附件、`assets/releases.json` 刷新均未执行。
- **完整设备验收**：Android 真机上的目录/搜索/播放/弹幕/同步弹幕，以及 Windows 安装后的实际播放，均待执行。
- **集成测试**：`integration_test/native_http_kick_test.dart` 本批没有在 Android 设备上运行；历史 Windows 运行受 Flutter 3.47 工具链问题阻塞，见交接文档。

## 当前状态与操作边界

- 源码：`master` 包含 `d7d9c3e8d`，已推送到 fork；文档更新随后单独提交推送。工作区只剩未跟踪的 `.lcode/` 草稿目录。
- 安装包：只存在于本机 `D:\purelive\local-artifacts\3.1.19-4108\`，没有上传到任何 Release 或外部服务。
- 版本：仍是 `3.1.19+4108`。两套包是同版本的本地重建，不是新版本发布。
- Android 生效条件：仅在 `Platform.isAndroid` 且请求主机为 `kick.com` 时走原生通道；其他主机和其他平台保持原有行为。
- 风险边界：该通道依赖 Cloudflare 当前接受 Android `HttpURLConnection` 的 TLS 指纹；未来可能再次失效。不要把它当成永久绕过方案。
- 验证边界：本说明只证明源码、定向测试、静态分析、构建产物和签名/哈希事实；不证明真实设备上的播放、清晰度、弹幕或长时间稳定性。

## 相关文档

- AI 技术交接：[KICK_WINDOWS_RESTORE_HANDOFF_2026_11_18.md](KICK_WINDOWS_RESTORE_HANDOFF_2026_11_18.md)
- 平台兼容性：[PLATFORM_COMPATIBILITY.md](PLATFORM_COMPATIBILITY.md)
- 历史平台探针（含 Android Kick 旧实现与真机 1080p60 证据）：[PLATFORM_PROBE_2026_09_25.md](PLATFORM_PROBE_2026_09_25.md)
