# Kick 弹幕修复（Windows + Android）工作结果说明

2026-11-18 · Kick 源码基线 `302e44c92` · Android 版本提交 `224f937d9` · 分支 `master`

## 结论

Windows 端接收不到 Kick 弹幕的问题已修复，Android 也已用同一套 Centrifugo 共享实现重新构建。根因是 Kick 停用了旧 Pusher 应用 key，原客户端连接任何 Pusher 集群都返回 `4001 App key ... not in this cluster`，订阅从未成功。

本轮已产出两个本机包：

- **Windows x64**：`3.1.19+4108` 安装程序和便携包，构建于 `302e44c92`。
- **Android arm64-v8a**：`3.1.20+4109` Release APK，构建于 `224f937d9`，使用本机新生成的**独立 Release 签名密钥**，不再是 Debug 证书。

**两个平台都还没有做真实界面验收**：Windows 没有安装启动，Android 没有设备安装和播放页弹幕观察。构建、签名、版本和包内代码已核验，但最终使用效果需要你安装确认。

## 本次提交与变更

- `302e44c92` `fix(kick): 迁移公开弹幕到 Centrifugo 实时网关`，4 个文件，+514/−77。
- `224f937d9` `chore(release): 递增 Android 版本到 3.1.20+4109`，只更新 `pubspec.yaml` 和 `assets/version.json` 的顶层与 Android 条目；Windows 条目与 MSIX 仍是 `3.1.19+4108`。
- 交付文档提交在其后，哈希以 `git log` 为准。
- 已推送到 `fork`（`https://github.com/crazylei12/pure_live.git`）的 `master`；远端 head 以 `git log` 和 `git ls-remote fork refs/heads/master` 为准。
- 没有版本 tag、GitHub Release、附件上传、`assets/releases.json` 更新或正式签名发布流程。

## 已经具备 / 本次完成

- **旧链路诊断**：`ws-us2`、`us3`、`eu`、`ap1`、`ap2`、`mt1` 六个 Pusher 集群全部返回 `4001`。
- **新实时链路**：频道接口解析独立 `chatroom.id` → `web.kick.com` 申请区域 WebSocket 和游客 JWT → Centrifugo `connect`/`subscribe` 订阅 `chatrooms.<id>.v2`。
- **消息与连接维护**：支持当前和旧版消息形状、空 JSON `{}` keepalive、消息房间校验、断线重连换发 token、订阅超时和旧会话隔离；emote 代码显示为名称。
- **共享实现**：修复位于共享 `KickDanmaku`，Windows 和 Android 都使用新协议。
- **Android 版本递增**：`3.1.20+4109`，Manifest `versionCode=6109`（arm64 ABI 偏移 +2000），`versionName=3.1.20`，`minSdk=26`，`targetSdk=37`，只包含 `arm64-v8a`。
- **Android 正式签名**：使用本机专用 Release 密钥，不再回退 Debug 证书；证书主体 `CN=Pure Live Release, OU=Android, O=Pure Live, C=CN`，证书 SHA-256 为 `35:BC:29:C1:64:A8:EB:97:B7:75:B1:C7:7D:9E:E4:85:A3:58:A3:44:6C:CC:4D:5B:25:E8:D0:41:D0:80`。
- **Release 插件注册表**：构建前重新生成，确认 `GeneratedPluginRegistrant.java` 不含 `integration_test`；APK 的 `classes.dex` 也没有 `IntegrationTestPlugin`。

## 安装包

### Windows x64

| 项目 | 值 |
|---|---|
| 安装程序 | [PureLive-3.1.19-4108-windows-x64-setup.exe](../local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-windows-x64-setup.exe) |
| 便携包 | [PureLive-3.1.19-4108-windows-x64-portable.zip](../local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-windows-x64-portable.zip) |
| 版本 | 3.1.19（构建号 4108），源码 `302e44c92` |
| 大小 | 63,026,122 字节（安装程序）；80,992,861 字节（便携包） |
| SHA-256 | `1c3396d09d650a1e35cb2aaa53de315394a82786d5771d56476733b8d516f962`（安装程序）<br>`078cd3d2a22d8d51f506a0b0607ced96aff85599faedc7b3eba252d26f493ca8`（便携包） |
| 签名 | 安装程序未签名（Authenticode `NotSigned`） |
| 构建记录 | `local-artifacts/build-records/20261118T113703179Z-build-windowsx64-release.json` |

### Android arm64-v8a

| 项目 | 值 |
|---|---|
| APK | [PureLive-3.1.20-4109-android-arm64-v8a-release.apk](../local-artifacts/3.1.20-4109/PureLive-3.1.20-4109-android-arm64-v8a-release.apk) |
| 版本 | 3.1.20（构建号 4109），Manifest versionCode 6109 |
| 包名 / ABI | `com.mystyle.purelive` / 仅 `arm64-v8a` |
| 大小 | 139,036,981 字节 |
| SHA-256 | `e908c978a87e93734aa758f641dc787c6634ccda67cebbbbb2dee352be20fdb3` |
| 签名 | Release 密钥，APK Signature Scheme v2，证书 SHA-256 `35bc29c164a8eb97b775b1c77d9ee485a358a3446ccc4d5b25e8d041d0803280` |
| 其他 | `minSdk=26`，`targetSdk=37`，18 个原生库，最小 ELF LOAD 对齐 `0x4000`，zipalign 通过 |
| 构建记录 | `local-artifacts/build-records/20261118T115523193Z-build-androidarm64-release.json` |
| 构建元数据 | `local-artifacts/3.1.20-4109/BUILD_METADATA.json`、`SHA256SUMS.txt` |

Android 构建记录显示 `source_commit=224f937d9`、`tracked_files_dirty=false`、`android_signing=release`；APK 内 `lib/arm64-v8a/libapp.so` 包含 `web.kick.com`、`chatrooms.`、`App\Events\ChatMessageEvent`，确认是新代码。

## Android 签名材料

- Release keystore：`D:\purelive-signing\purelive-release.p12`（RSA 4096，PKCS12，100 年有效期，别名 `purelive`）。
- 本机备份：`D:\purelive-signing\backup\`（含 keystore 和 `key.properties` 副本）。
- Gradle 配置：`D:\purelive\android\key.properties`，已被 `.gitignore` 忽略。
- 说明文件：`D:\purelive-signing\SIGNING_README.txt`。
- **密钥和密码没有提交到 Git，也没有写进本文档。** 后续独立维护必须保留这套 keystore 和密码；丢失后将无法覆盖安装后续版本。
- APK 使用 v2 签名方案（Android 7.0+ 可验证）；没有启用 v3 密钥轮换方案。

> **重要**：以后构建 Android Release 时必须显式加 `-RequireReleaseSigning`，否则构建脚本仍允许在缺少 `key.properties` 时回退 Debug 证书。签名材料丢失前建议再做一次离线备份。

## 验证结果

| 验证项 | 结果 | 证据 |
|---|---|---|
| 旧 Pusher 链路 | 全部集群失败，`4001` | 本机对六个 Pusher 集群的短连接探测 |
| 真实生产链路探针 | 通过，收到真实 Kick 聊天消息 | `tool/probes/kick_chat_probe_test.dart`，本轮输出 `00:08 +1: All tests passed!` |
| 全仓 Analyze（`224f937d9`） | 通过，`No issues found!` | `local-artifacts/build-records/20261118T115740778Z-quality-focused.json`，13.9 秒 |
| 完整 Flutter 测试（`224f937d9`） | 通过，298/298 | 日志 `local-artifacts/build-records/20261118T115740778Z-android-full-tests.log`，约 45 秒 |
| Android Release 构建 | 通过 | `20261118T115523193Z-build-androidarm64-release.json`，`status=succeeded`，`android_signing=release`，374 秒 |
| APK 版本/ABI | 通过 | `versionName=3.1.20`、`versionCode=6109`、`minSdk=26`、`native-code=arm64-v8a` |
| APK 签名 | 通过 | `apksigner verify` 显示 v2 签名，证书 SHA-256 与 Release keystore 一致 |
| APK 完整性 | 通过 | 18 个原生库，最小 ELF LOAD 对齐 `0x4000`，zipalign 通过，SHA-256 与 `SHA256SUMS.txt` 一致 |
| 包内新代码 | 通过 | `libapp.so` 含 `web.kick.com`、`chatrooms.`、`App\Events\ChatMessageEvent` |
| Release 注册表 | 通过 | 构建前 `GeneratedPluginRegistrant.java` 无 `integration_test`；APK `classes.dex` 无 `IntegrationTestPlugin` |
| Windows 包 | 通过构建/哈希核验 | 安装程序与便携包哈希、运行库、包内 `app.so` 新代码标记已核验 |
| Android 真机安装/播放/弹幕 | **未执行** | 没有设备请求，未做 ADB 安装或界面验收 |
| Windows 安装/运行/弹幕 | **未执行** | 没有安装 setup.exe 或启动应用 |

补充：`local_ci.ps1 -Scope Full` 的包装器仍在仓库预检阶段被缺失的 `.github/workflows/audit-upstream.yml` 阻断（该文件在历史提交 `4a0cf09fe` 中被删除，但校验脚本仍要求它）。因此没有“Full 包装器整体通过”的记录；上面的 Analyze 和 298 个测试是直接运行的真实结果。该阻断是既有仓库策略漂移，不是本次修改引入的。

## 已确认未解决的问题

- **Android 真机未验收**：没有安装 APK，也没有在真实 Kick 房间观察弹幕、播放、清晰度和长时间稳定性。
- **Windows 界面未验收**：没有安装 setup.exe 或启动应用。
- **Full 质量包装器未通过**：被缺失的 `.github/workflows/audit-upstream.yml` 阻断，详见上文。
- **Windows 安装包未签名**：Android APK 已使用 Release 密钥，但 Windows setup.exe 仍是 `NotSigned`。
- **Android 只启用 v2 签名**：没有 v3/v3.1 密钥轮换签名；当前 Android 7.0+ 可正常验证。
- **签名密钥只有本机副本**：keystore 在 `D:\purelive-signing`，备份也在同一磁盘；如果磁盘损坏且没有离线备份，将无法发布覆盖更新。
- **发布链路未推进**：没有 tag、GitHub Release、附件上传、`assets/releases.json` 更新或 Release Notes 更新；当前 APK 只在 `local-artifacts`。
- **版本线不一致**：Android 是 `3.1.20+4109`，Windows 仍是 `3.1.19+4108`；这是本轮只重建 Android 的直接结果，不是 Windows 包被替换。
- **长时间网络行为未验收**：token 过期、网络切换、后台恢复只有单元测试分支覆盖，没有真实长跑。

## 尚未实现 / 仅部分实现

- **发布到 GitHub**：源码已推送，APK/安装包没有上传；没有创建 Release。
- **Android 其他 ABI**：只构建了 `arm64-v8a`，没有构建 `armeabi-v7a` 或 `x86_64`。
- **正式签名 CI**：当前签名材料只在本机，CI 还没有可用的签名密钥配置。
- **Kick 播放卡顿**：按你的要求暂缓，本轮没有修改播放器或媒体链路。

## 当前状态与操作边界

- 源码：`master` 包含 `302e44c92`（Kick 修复）和 `224f937d9`（Android 版本递增），已推送 `fork/master`；文档提交随后推送。
- Android APK：`D:\purelive\local-artifacts\3.1.20-4109\`，Release 签名，未发布。
- Windows 包：`D:\purelive\local-artifacts\3.1.19-4108\`，未签名，未发布。
- 签名材料：`D:\purelive-signing\` + 本机 `android/key.properties`，均不在 Git；务必保留离线备份。
- 工作区：跟踪文件干净；只剩未跟踪的 `.lcode/` 草稿目录。
- 生效范围：Kick 公开弹幕使用新协议；播放媒体链路和卡顿不在本轮范围。
- 验证边界：本说明证明源码修复、真实协议探针、静态分析、完整测试、Android Release 构建/签名/完整性以及 Windows 构建产物事实；不证明真实设备/界面验收，也不证明已发布。

## 相关文档

- AI 技术交接：[KICK_WINDOWS_RESTORE_HANDOFF_2026_11_18.md](KICK_WINDOWS_RESTORE_HANDOFF_2026_11_18.md)
- 平台兼容性：[PLATFORM_COMPATIBILITY.md](PLATFORM_COMPATIBILITY.md)
- 旧 Pusher 审计（已被本次 Centrifugo 迁移取代）：[KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md](KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md)
