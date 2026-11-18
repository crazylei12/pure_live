# Kick 恢复（仅 Windows）AI 技术交接

2026-11-18 · 源码基线 `521f3ae06` + 本批提交 `adf311fcf` · 分支 `master`

## 1. 最新有效需求与边界

用户要求：**恢复 Kick，先只做 Windows 平台**。

本批有效范围：

- 只在 Windows 构建注册 Kick；非 Windows 不显示 Kick 入口，已保存的 Kick 房间按退役平台处理。
- 允许使用 Windows 原生 WinHTTP/Schannel 访问 kick.com JSON；媒体继续使用 dart:io/dio。
- 不新增 Android/iOS/Linux/macOS 原生通道。
- 未要求版本递增、Release 包或发布；本批没有做。
- 旧的“3.2.11 全面下线 Kick”要求被本批 Windows 恢复覆盖；其他平台的下线结论仍有效。

## 2. 工作区、Git 与发布状态

- 工作区：`D:\purelive`（同时存在 SUBST `P:\` → `D:\`；Flutter 构建产物常以 `P:\purelive` 出现）。
- 分支：`master`。
- 本批源码提交：`adf311fcf` `feat(kick): restore Windows-only Kick support`，24 个文件，+1794/−8。
- 本批文档提交紧随源码提交，提交信息为 `docs: 记录 Kick Windows 恢复结果与交接`；其自身哈希会随文档修订变化，以 `git log` 为准。
- 上一源码基线：`521f3ae06`。
- 远端：`origin` = `https://github.com/liuchuancong/pure_live.git`；`upstream` = `https://github.com/Jackiu1997/pure_live.git`；`fork` = `https://github.com/crazylei12/pure_live.git`（2026-11-18 从 `origin` fork 到 `crazylei12`，`master` 起点 `d94078377`）。
- **推送状态：已推送至 `fork` 的 `master`。** 2026-11-18 从 `d94078377` 快进推送；`b8380eaf9` 是合并提交，用于合入 `origin/master` 上唯一的发布数据提交 `d94078377`（仅 `assets/releases.json`）；`adf311fcf` 和文档提交哈希未改写。随后文档更正提交也推送到同一分支，实际远端 head 以 `git ls-remote fork master` 为准。
- **原 `origin` 仍不可写。** `git push origin master` 返回 403：`Permission to liuchuancong/pure_live.git denied to crazylei12`；`gh auth status` 显示 `crazylei12` 已登录且有 `repo` scope，但没有目标仓库写权限。不要切换或猜测账号，不要强推。

## 3. 已改文件与关键接口

### 新增

- `lib/core/platform/native_http.dart`：`NativeHttp.getKickJson({url, headers, proxyHost?, proxyPort?, timeoutMillis?})`，MethodChannel `pure_live/native_http`，返回 `({int status, String body})`；`supportsKick => Platform.isWindows`。
- `lib/shared/platforms/kick/kick_link.dart`：`kick.com`/`www.kick.com` 链接规整为 slug；保留字（auth/browse/categories/category/dashboard/following/search/settings/video）拒绝；`url(slug)`。
- `lib/shared/platforms/kick/kick_hls.dart`：master playlist 解析为 `KickHlsVariant`（uri/height/frameRate/bandwidth），上限 4 MB。
- `lib/shared/platforms/kick/kick_api.dart`：
  - `KickApi({KickRequest? request})`；`KickRequest` 可注入测试。
  - `usesPlatformTls(uri, {native})` 只对 `https://kick.com/...` 返回 true，`native` 由 `NativeHttp.supportsKick` 传入。
  - `directory(page, limit)`：`/stream/livestreams/en?page=&limit=`，limit 上限 30；校验 `next_page_url` 主机。
  - `search(word)`：`/api/search?searched_word=`，直播匹配来自 `livestreams.tags`，频道来自 `channels`。
  - `room(slug)`：`/api/v2/channels/<slug>`。
  - `chatroomId(slug)`：从频道响应 `chatroom.id` 取，校验 slug 一致且为正整数。
  - `headers` / `mediaHeaders(slug)`；图片/媒体主机白名单（`files.kick.com`、`images.kick.com`、`static.kick.com`、`*.live-video.net`）。
  - 403 → 访问失败，404 → 房间缺失，429 → 限流，5xx → 服务失败；传输失败实现 `SiteTransportFailure.isSiteUnreachable`。
- `lib/shared/platforms/kick/kick_danmaku.dart`：Pusher 公共端点，订阅 `chatrooms.<id>.v2`；`KickDanmaku({KickApi? api, WebSocketConnector? connector})`；10 秒订阅看门狗；支持 `pusher:ping/pong`、订阅成功、`App\Events\ChatMessageEvent` 和旧版 `ChatMessageSentEvent`；emote `[emote:id:name]` 转为 name。
- `lib/shared/platforms/kick/kick_site.dart`：实现 `LiveSite`、`LiveSiteExternalRoomResolver`、`LiveSiteRoomRefresher`、`LiveSiteDirectoryPager`、`LiveSiteCategoryDirectoryProvider`、`LiveSiteRecordRoomResolver`、`LivePlayRecoveryResolver`；`detail.data` 保存 `_KickPlayback`（slug + HLS 质量）；外部目标 `https://kick.com/<slug>`；目录 notice `kick_public_directory`，聊天 notice `kick_mature_notice`。
- `test/shared/platforms/kick_transport_routing_test.dart`：传输路由、媒体头、链接、Windows 注册/退役。
- `test/shared/platforms/kick_danmaku_test.dart`：chatroom id、房间刷新身份、订阅/聊天/关闭、缺失身份、chatroom 作用域、旧消息、emote。
- `integration_test/native_http_kick_test.dart`：真实 Windows runner 通道测试；**本机被 Flutter 工具链阻塞，见 §6**。
- `tool/probes/kick_native_probe.dart`：正常 `flutter build windows` 构建的通道探针入口，结果写 `%TEMP%\pure_live_kick_probe.json`。
- `windows/runner/native_http.{h,cpp}`：WinHTTP 实现；`NativeHttpIsAllowedKickUrl` 只允许 `https://kick.com/...`；`NativeHttpGet` 支持代理、超时、8 MB 上限。
- `windows/runner/flutter_window.cpp/.h`：注册 `pure_live/native_http`，`getKickJson` 在后台线程执行，经 `WM_APP+0x3A1` 回平台线程。
- `windows/runner/CMakeLists.txt`：加入 `native_http.cpp`，链接 `winhttp.lib`。

### 修改

- `lib/domains/live/data/platforms/sites.dart`：
  - `import 'dart:io'`；`_baseSupportedSiteIds` 保持不变；`supportedSiteIds` 改为 `static final`，Windows 追加 `kick`。
  - `retiredSiteIds` 仍含 `'kick'`，`isRetired` 改为“不受支持且在退役集合”；`isRetiredLink` 在 Windows 对 kick.com 跳过退役判断；`logoForId` 用 `isRetired`。
  - `_logos` 加 `kick.png`；`_createSite` 加 kick；`_supportedSites` 仅在 Windows 加 kick。
- `lib/domains/live/data/favorite_room_controller.dart`：目录迁移 `currentSiteCatalogMigration = 39`，新增 v39 `Sites.kickSite`；v17 注释更新。Windows 旧用户会追加 kick，非 Windows 因退役检查跳过。
- `lib/core/models/live_room.dart`：`audienceCapabilities['kick']` 按 `roomList` 实时在线人数。
- `lib/domains/live/data/link/`：`live_url_tool.dart`、`web_search_room_parser.dart` 接入 `KickLink.parse`。
- `lib/domains/live/data/playback_header_resolver.dart`：kick 分支使用 `KickApi.mediaHeaders(roomId)`。
- `lib/domains/live/presentation/search/search_capability.dart`：Kick 原生直播+未开播频道，单页/无分页，无网页搜索。
- `lib/domains/live/presentation/playback/widgets/local_interaction/local_interaction_controller.dart`：Kick 本地面板包。
- `test/domains/live/playback_header_resolver_test.dart`：新增 Kick 媒体头测试。
- `docs/PLATFORM_COMPATIBILITY.md`：Kick 改为仅 Windows 恢复；Windows 34 直播站 + IPTV，其他平台 33 + IPTV。

### 未改动（刻意保留）

- `retiredSiteIds` 中继续保留 `'kick'`，用于非 Windows 的退役提示。
- 未新增其他平台的原生通道。
- 未改版本号、pubspec、发布脚本、Android 配置。
- `.lcode/kick_restore/` 是历史参考草稿，未提交；确认不再需要后可删。

## 4. 当前 Kick 接口事实（2026-11-18 本机 WinHTTP 探针）

- 目录：`GET https://kick.com/stream/livestreams/en?page=1&limit=5` → 200；根键 `current_page,data,first_page_url,from,next_page_url,path,per_page,prev_page_url,to`。
- 目录项键：`id,slug,channel_id,session_title,is_live,viewer_count,show_view_count,channel,categories,...`；`item.playback_url` 为空，播放地址在 `item.channel.playback_url`。
- 频道详情：`GET /api/v2/channels/<slug>`；根含 `id,slug,playback_url,livestream,user,chatroom,followers_count,...`。直播中的 `livestream` 含 `channel_id`、`is_live`、`viewer_count`、`session_title`、`categories`，**没有嵌套 `channel`**；解析器用根频道 id 作为 owner 校验。
- 搜索：`GET /api/search?searched_word=xqc`；`livestreams.tags` 可能为 0；`channels` 项含 `id,slug,isLive,user{username,bio,profilePic},followersCount`。
- 聊天：`wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?...`，聊天室 id 由频道响应 `chatroom.id` 决定；本批未实连。
- 同 URL 用 Dart HttpClient 仍为 403 `Request blocked by security policy`；WinHTTP COM 和本批原生探针均 200。
- IVS 媒体 `*.live-video.net` 用普通 dart:io 可达，绝不要接入只放行 kick.com 的原生通道。

## 5. 验证记录（实际执行）

环境：Windows 10.0.26200，Flutter 3.47.5（`.fvmrc`），`tool/flutterw.ps1`。

1. `tool/flutterw.ps1 test test/shared/platforms/kick_transport_routing_test.dart test/shared/platforms/kick_danmaku_test.dart` → 通过（早期 10 个测试）。
2. 最终 `tool/local_ci.ps1 -Scope Focused -TestPath ... -Analyze -SkipPubGet` → 16 个测试全部通过；Analyze `No issues found! (ran in 22.5s)`；质量记录 `local-artifacts/build-records/20261117T234754780Z-quality-focused.json`。
3. `tool/build_local_release.ps1 -Target WindowsX64 -Configuration Debug -SkipQuality` → 成功（115.6 秒）；记录 `local-artifacts/build-records/20261117T233529184Z-build-windowsx64-debug.json`；产物 `local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-windows-x64-debug.zip`。构建记录中的 `source_commit` 写的是基线 `521f3ae06`，实际工作树包含本批未提交改动。
4. 原生通道实跑：清理 `.dart_tool/flutter_build` 后执行 `flutter build windows --debug -t tool/probes/kick_native_probe.dart` → 成功；运行 runner 后 `%TEMP%\pure_live_kick_probe.json` 内容：
   ```json
   {
     "supportsKick": true,
     "directoryStatus": 200,
     "directoryKeys": ["current_page","data","first_page_url","from","next_page_url","path","per_page","prev_page_url","to"],
     "rejectedOtherHost": true
   }
   ```
   探针进程写入结果后未自行退出，已手动结束，未影响结果。
5. `python tool/validate_architecture.py --strict` → 失败，1 条未批准硬违规：`lib/domains/recorder/presentation/pages/local_player/local_video_player_controller.dart:15` 导入 `package:pure_live/domains/live/domain/global_player_service.dart`。该文件本批未改，属既有基线问题，未擅自修复。
6. `integration_test/native_http_kick_test.dart` 两次尝试均在构建阶段失败：`flutter test -d windows` 会先删除 `windows/flutter/ephemeral/cpp_client_wrapper/*.cc`，MSBuild 随后 `C1083` 找不到 `core_implementations.cc` 等文件。清理 build cache 后普通 `flutter build` 可恢复这些文件，但 `flutter test` 再次删除。未修改 Flutter SDK。

## 6. 已知缺陷 / 风险

- **原仓库推送权限**：见 §2，本批已推送到 fork `crazylei12/pure_live`；原 `origin` 仍因 403 不可写。
- **真实 UI 未验收**：未打开 Kick 房间、未播放、未切清晰度、未看弹幕；原生探针只覆盖通道和目录。
- **Pusher 未实连**：订阅、聊天、重连只有单元测试；Cloudflare/Pusher 策略变化可能失效。
- **非 Windows 行为未实跑**：注册表条件、退役提示、保存房间失败路径只有单元测试/静态约束。
- **集成测试工具链问题**：见 §5.6；后续可升级 Flutter 或改用可用的 runner 路径，不要用删除生成文件的方式长期绕过。
- **架构严格校验既有失败**：见 §5.5。
- **Cloudflare 依赖**：WinHTTP/Schannel 目前被接受，未来可能被拦截。

## 7. 剩余任务与建议顺序

1. 仅在需要推送到原仓库时：解决 `liuchuancong/pure_live` 的写权限（使用有权限的账号或修正远端），推送前 `git fetch origin` 检查分叉，禁止强推；fork `crazylei12/pure_live` 已包含本批提交。
2. 在真实 Windows UI 中打开一个正在直播的 Kick 房间，验证目录、搜索、房间详情、清晰度、媒体头、外部打开、收藏和重启后的迁移。
3. 真实连接 Pusher，确认订阅成功、聊天延迟、ping/pong 和断线重连；记录实际频道和结果，不要只引用单测。
4. 在非 Windows 构建上确认 Kick 不出现在平台选择、链接按退役处理、保存的 Kick 房间有可理解提示。
5. 评估 `integration_test` 的 Flutter 工具链问题；修复后把 `native_http_kick_test.dart` 纳入真实 runner 验收。
6. 决定是否需要 Windows Release 包/版本递增；本批用户未要求，因此未做。发布必须遵守 BUILD_POLICY 的签名、哈希和来源检查。
7. 删除 `.lcode/kick_restore/` 历史草稿前先确认不再需要对照；不要提交该目录。

## 8. 操作权限与禁止事项

- 只允许当前明确授权的 Windows 范围；不要顺带新增 Android/iOS/Linux/macOS Kick 通道。
- 设备/ADB/真机操作需要新的明确请求；本批未做。
- 不要提交 `.lcode/`、密钥、签名或未脱敏日志。
- 不要强推、删除无关分支、改写远端历史。
- 不要在没有新证据时声称 UI、聊天或发布包已验收。
- 不要用“重试/刷新/延迟”替代对失败原因的诊断。
- 修改 Dart 后按仓库策略格式化改动文件并跑受影响测试；分析在 Dart 改动收敛后跑一次。

## 9. 关键命令

```powershell
# 定向测试 + Analyze
powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'D:\purelive\tool\local_ci.ps1' -Scope Focused -TestPath 'test/shared/platforms/kick_transport_routing_test.dart','test/shared/platforms/kick_danmaku_test.dart','test/domains/live/playback_header_resolver_test.dart' -Analyze -SkipPubGet"

# Windows Debug 构建
powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_local_release.ps1 -Target WindowsX64 -Configuration Debug -SkipQuality

# 原生通道探针（构建后运行 exe，读取 %TEMP%\pure_live_kick_probe.json）
flutter build windows --debug --no-pub -t tool/probes/kick_native_probe.dart
```

如遇 `cpp_client_wrapper/*.cc` 缺失，先删除整个 `windows/flutter/ephemeral/cpp_client_wrapper` 再走普通 `flutter build windows`；该目录是生成物，不要手工提交。

## 10. 关联文档

- 用户结果说明：[KICK_WINDOWS_RESTORE_2026_11_18.md](KICK_WINDOWS_RESTORE_2026_11_18.md)
- 平台兼容性：[PLATFORM_COMPATIBILITY.md](PLATFORM_COMPATIBILITY.md)
- 历史聊天审计：[KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md](KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md)
