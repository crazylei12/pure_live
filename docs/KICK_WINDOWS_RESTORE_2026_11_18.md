# Kick 恢复（仅 Windows）工作结果说明

2026-11-18

## 结论

Windows 上的 Kick 支持已恢复到源码和本机 Debug 构建：Kick 只在 Windows 注册，公开目录、搜索、房间详情、HLS 质量解析、媒体请求头和 Pusher 聊天传输均按当前架构重新接入；kick.com 的 JSON 请求走 Windows 原生 WinHTTP/Schannel 通道，媒体仍走普通 dart:io/dio。定向测试、全仓 Analyze 和 Windows Debug 构建均通过；真实播放器 UI 播放、真实 Pusher 连接和发布包尚未验收。

本批源码已本地提交 `adf311fcf`（`feat(kick): restore Windows-only Kick support`），文档在该源码提交之后的文档提交中；**推送失败**：`origin`（`github.com/liuchuancong/pure_live.git`）返回 403，当前系统账号 `crazylei12` 无该仓库写权限。未使用强推，也未改写远端。

## 本次完成

- **平台注册**：Windows 构建把 `kick` 加入支持站点、Logo、适配器构造、搜索能力和本地面板；非 Windows 构建继续按退役平台处理。平台目录迁移新增 v39，已有 Windows 用户会重新得到 Kick 入口。
- **数据层**：恢复 `KickLink`、`KickHls`、`KickApi`、`KickDanmaku`、`KickSite`，按 2026-11-18 实际接口核对：目录项从 `channel.playback_url` 取播放地址，`channel_id` 与嵌套频道一致；搜索频道使用 `isLive`；房间详情缺少 `livestream` 时按离线频道返回；`show_view_count` 缺失或为 false 时不展示在线人数。
- **原生通道**：Windows runner 新增 `pure_live/native_http` 方法通道和 `getKickJson`，只允许 `https://kick.com/`（含端口校验路径），其余主机在原生层拒绝；支持应用代理设置，超时 1–60 秒，响应上限 8 MB。Dart 端只把 kick.com 路由到该通道，`*.live-video.net` 媒体不经过它。
- **链接与头**：Kick 链接重新被手动输入/网页搜索识别；播放请求头按频道 slug 生成 `Referer`/`Origin`。Kick 在线人数按实时并发人数登记。
- **文档**：`docs/PLATFORM_COMPATIBILITY.md` 已把 Kick 从“历史下线”改为“仅 Windows 恢复”，并更正 Windows/其他平台的注册数量。

## 验证结果

| 验证项 | 结果 | 证据 |
|---|---|---|
| Kick 定向测试 | 通过，16 个测试 | `test/shared/platforms/kick_transport_routing_test.dart`、`kick_danmaku_test.dart`、`test/domains/live/playback_header_resolver_test.dart`；质量记录 `local-artifacts/build-records/20261117T234754780Z-quality-focused.json` |
| 全仓 Analyze | 通过，无问题 | 同上，`No issues found!`（22.5 秒） |
| Windows Debug 构建 | 通过 | `local-artifacts/build-records/20261117T233529184Z-build-windowsx64-debug.json`，产物 `local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-windows-x64-debug.zip` |
| 原生通道实跑 | 通过 | 用真实 Windows runner 构建 `tool/probes/kick_native_probe.dart` 并运行；`%TEMP%\pure_live_kick_probe.json` 返回 `supportsKick: true`、目录 HTTP 200、目录键完整、`example.com` 被拒绝 |
| 集成测试 `integration_test/native_http_kick_test.dart` | 未能运行 | Flutter 3.47 的 `flutter test -d windows` 在构建前删除了生成的 `windows/flutter/ephemeral/cpp_client_wrapper/*.cc`，MSBuild 因缺文件失败；两次尝试均停在该工具链问题，未进入测试体 |
| 架构严格校验 | 未通过（既有问题） | `python tool/validate_architecture.py --strict` 报告 1 条未批准违规：`lib/domains/recorder/presentation/pages/local_player/local_video_player_controller.dart:15` 导入 `domains/live/domain/global_player_service.dart`。该文件本批未修改 |

原生通道探针进程在写入结果后没有自动退出，已手动结束；结果文件完整，结论不受影响。

## 尚未完成 / 未验证

- 未在真实应用 UI 中打开 Kick 房间、播放视频、切换清晰度或查看弹幕；只验证了底层通道、适配器合同和构建。
- 未真实连接 `wss://ws-us2.pusher.com` 验证订阅和聊天；聊天解析、订阅帧和重连逻辑只有单元测试。
- 未在非 Windows 平台实跑“隐藏 Kick/按退役处理”的用户路径；该行为由注册表和单元测试约束。
- 未更新版本号、未生成 Windows Release/安装包、未发布 Release。
- 集成测试运行器问题属于 Flutter 3.47 工具链，未修改 SDK 或绕过该测试。

## 当前状态与操作边界

- 源码状态：本地 `master` 在 `521f3ae06` 之上有源码提交 `adf311fcf` 及其后的文档提交，工作区只剩未跟踪的 `.lcode/` 草稿目录。
- 推送状态：未推送。需要具备 `liuchuancong/pure_live` 写权限的账号或修正远端权限后重试；不要强推。
- 仅 Windows 生效。Windows 之外的构建不应展示 Kick；已保存的 Kick 房间会按退役平台处理。
- 该通道依赖 Cloudflare 当前接受 Windows Schannel 的 TLS 指纹，后续可能再次失效。

## 相关文档

- AI 技术交接：[KICK_WINDOWS_RESTORE_HANDOFF_2026_11_18.md](KICK_WINDOWS_RESTORE_HANDOFF_2026_11_18.md)
- 平台兼容性：[PLATFORM_COMPATIBILITY.md](PLATFORM_COMPATIBILITY.md)
