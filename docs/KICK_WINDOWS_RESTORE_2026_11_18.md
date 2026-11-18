# Kick 弹幕修复（Windows）工作结果说明

2026-11-18 · 源码基线 `302e44c92` · 分支 `master`

## 结论

Windows 端接收不到 Kick 弹幕的问题已定位并修复到源码。直接原因是 Kick 已停用旧 Pusher 应用 key，客户端连接任何 Pusher 集群都会收到 `4001 App key ... not in this cluster`，订阅从未成功；现在已改为 Kick 官网当前使用的 Centrifugo 实时网关，并通过真实网络探针收到了真实聊天消息。

Windows x64 安装程序和便携包已从干净提交 `302e44c92` 构建成功，产物哈希、版本、签名状态、运行库和包内 `app.so` 的 Kick 新代码标记均已核验。**还没有在本机安装并打开 Windows 程序做界面验收**，弹幕在真实播放页中的呈现需要你安装后确认。

## 本次提交与变更

- 源码提交：`302e44c92` `fix(kick): 迁移公开弹幕到 Centrifugo 实时网关`，4 个文件，+514/−77。
- 已推送到 `fork`（`https://github.com/crazylei12/pure_live.git`）的 `master`，远端 head 已核对为 `302e44c92ad7c7bf6a98d8374ce28f3d3e935d48`。
- 本文档的更新作为后续 `docs:` 提交推送；应用源码基线仍是 `302e44c92`。
- 没有版本递增：仍是 `3.1.19+4108`。没有创建 tag、GitHub Release、上传附件或更新 `assets/releases.json`。

## 已经具备 / 本次完成

- **旧链路诊断**：实测 `ws-us2`、`us3`、`eu`、`ap1`、`ap2`、`mt1` 等 Pusher 集群全部返回 `4001`，确认不是房间号、网络或界面问题，而是旧 Pusher key 已失效。
- **新实时链路**：先通过频道接口解析独立的 `chatroom.id`，再向 `web.kick.com` 申请区域 WebSocket 地址和游客 JWT；WebSocket 按 Centrifugo 协议发送 `connect`、订阅 `chatrooms.<id>.v2`，服务端返回订阅确认后才标记连接成功。
- **消息解析**：支持当前 `push.pub.data` 消息形状和旧版消息形状；只接受目标聊天室的消息，保留消息 ID、发送时间、用户名、颜色；`[emote:<id>:<name>]` 会显示为表情名称，不再显示原始代码。
- **连接维护**：处理 Centrifugo 的空 JSON `{}` keepalive 心跳；断线重连时重新获取游客 JWT；订阅超时、有限重连、停止时释放 socket 和计时器，旧会话不会回写新会话。
- **安全边界**：只接受 `wss://realtime.<region>.platform.kick.com/connection/websocket`、443 端口、无 query/fragment/userInfo 的地址；游客客户端 ID 和 JWT 做格式与长度校验；实时接口响应限制 256 KiB。
- **共享实现**：修复位于共享的 `KickDanmaku`，Windows 和 Android 源码都会使用新协议；本轮只构建了 Windows 包。目录里原有的 Android APK 是修复前构建的，不包含本次 Centrifugo 改动。

## 安装包（Windows x64）

| 项目 | 值 |
|---|---|
| 安装程序 | [PureLive-3.1.19-4108-windows-x64-setup.exe](../local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-windows-x64-setup.exe) |
| 便携包 | [PureLive-3.1.19-4108-windows-x64-portable.zip](../local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-windows-x64-portable.zip) |
| 版本 | 3.1.19（构建号 4108），源码提交 `302e44c92` |
| 大小 | 63,026,122 字节（安装程序）；80,992,861 字节（便携包） |
| SHA-256 | `1c3396d09d650a1e35cb2aaa53de315394a82786d5771d56476733b8d516f962`（安装程序）<br>`078cd3d2a22d8d51f506a0b0607ced96aff85599faedc7b3eba252d26f493ca8`（便携包） |
| 签名 | 安装程序未签名（Authenticode `NotSigned`） |
| 构建记录 | `local-artifacts/build-records/20261118T113703179Z-build-windowsx64-release.json` |
| 构建元数据 | `local-artifacts/3.1.19-4108/WINDOWS_BUILD_METADATA.json`、`WINDOWS_SHA256SUMS.txt` |

构建元数据记录 `source_commit=302e44c92...`、`tracked_files_dirty=false`；便携包内含 `msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`。包内 `data/app.so` 与构建目录中的同名文件 SHA-256 一致（`069681ad...`），并包含 `web.kick.com`、`chatrooms.`、`App\Events\ChatMessageEvent` 标记，确认不是旧包复用。

> **安装提示**：安装程序未签名，SmartScreen 可能提示“未知发布者”。该包没有上传到任何 Release 或外部服务，只存在于本机 `D:\purelive\local-artifacts\3.1.19-4108\`。

## 验证结果

| 验证项 | 结果 | 证据 |
|---|---|---|
| 旧 Pusher 链路 | 全部集群失败，`4001` | 本机对六个 Pusher 集群的短连接探测 |
| 真实生产链路探针 | 通过，收到真实 Kick 聊天消息 | `tool/probes/kick_chat_probe_test.dart`，本轮输出 `00:08 +1: All tests passed!`；探针使用生产 `KickApi` + `KickDanmaku`，只替换了测试网络适配器 |
| 全仓 Analyze（干净提交） | 通过，`No issues found!` | `local-artifacts/build-records/20261118T113834952Z-quality-focused.json`，源码 `302e44c92`，Analyze 14.6 秒 |
| 完整 Flutter 测试 | 通过，298/298 | `flutter test --no-pub --concurrency=12`；日志 `local-artifacts/build-records/20261118T113834952Z-kick-full-tests.log`，用时约 31 秒 |
| Windows Release 构建 | 通过 | 构建记录 `20261118T113703179Z-build-windowsx64-release.json`，`status=succeeded`，`duration_seconds=308.703` |
| 安装包/便携包哈希 | 通过 | 与 `WINDOWS_SHA256SUMS.txt` 一致；签名状态 `NotSigned`；ProductVersion `3.1.19` |
| 包内新代码 | 通过 | 从便携包解出的 `data/app.so` 含 `web.kick.com`、`chatrooms.`、`App\Events\ChatMessageEvent`，且与构建目录 `app.so` 哈希一致 |
| Windows 安装/运行/弹幕呈现 | **未执行** | 没有安装 setup.exe，也没有启动应用做界面验收 |

补充：`local_ci.ps1 -Scope Full` 的包装器在仓库预检阶段被阻断，原因是 `.github/workflows/audit-upstream.yml` 缺失（该文件已在历史提交 `4a0cf09fe` 中被删除，但校验脚本仍要求它）。因此本轮没有“Full 包装器整体通过”的记录；上面的 Analyze 和 298 个测试是直接运行的真实结果，不是包装器结论。该阻断是既有仓库策略漂移，不是本次 Kick 修改引入的。Analyze 质量记录里的 `source_worktree_dirty=true` 仅因未跟踪的 `.lcode/` 草稿目录；跟踪源码是 `302e44c92`，Windows 构建元数据也记录 `tracked_files_dirty=false`。

## 已确认未解决的问题

- **Windows 界面未验收**：没有在本机安装安装程序、启动应用、进入 Kick 房间观察弹幕；无法仅凭构建成功证明真实播放页的弹幕显示、滚动、颜色和长时间稳定性。
- **Full 质量包装器未通过**：被缺失的 `.github/workflows/audit-upstream.yml` 阻断，详见上文；没有把直接运行的 Analyze/测试冒充为 `local_ci -Scope Full` 的通过记录。
- **安装包未签名**：没有 Authenticode 证书，SmartScreen 可能拦截。
- **版本与发布未推进**：没有版本递增、tag、GitHub Release、附件上传或发布索引更新；当前包是本机验证产物。
- **Android 包未重建**：同目录下的 Android APK 是修复前构建的，不包含 Centrifugo 修复；本轮没有重新构建 Android。
- **长时间网络行为未验收**：没有做长时间后台运行、网络切换、服务端 token 过期后的连续重连测试；这些由单元测试覆盖了协议分支，但不等于真实环境验收。

## 尚未实现 / 仅部分实现

- **Kick 播放卡顿**：按你的明确要求暂停调查，本轮没有修改播放器、清晰度或媒体链路。
- **Android 交付**：共享实现已经改好，但没有重新构建 Android APK，也没有做 Android 真机验收。
- **正式发布流程**：版本递增、正式签名、完整 `Full` 包装器、草稿 Release、上传和 `assets/releases.json` 刷新均未执行。
- **Windows 之外的实际运行验收**：本轮只交付 Windows 构建产物，没有做其他平台构建。

## 当前状态与操作边界

- 源码：`master` 包含 `302e44c92`，已推送到 `fork/master`；工作区只剩未跟踪的 `.lcode/` 草稿目录，未提交。
- 安装包：位于 `D:\purelive\local-artifacts\3.1.19-4108\`，没有发布。
- 版本：仍是 `3.1.19+4108`，属于同版本本地重建，不是新版本发布。
- 生效范围：Kick 公开弹幕使用新协议；播放媒体链路和卡顿问题不在本轮范围。
- 验证边界：本说明证明源码修复、真实协议探针、静态分析、完整测试和 Windows 构建产物事实；不证明 Windows 界面内的最终弹幕呈现，也不证明生产发布可用性。

## 相关文档

- AI 技术交接：[KICK_WINDOWS_RESTORE_HANDOFF_2026_11_18.md](KICK_WINDOWS_RESTORE_HANDOFF_2026_11_18.md)
- 平台兼容性：[PLATFORM_COMPATIBILITY.md](PLATFORM_COMPATIBILITY.md)
- 旧 Pusher 审计（已被本次 Centrifugo 迁移取代）：[KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md](KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md)
