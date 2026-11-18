# Kick 弹幕修复（Windows）AI 技术交接

2026-11-18 · 源码基线 `302e44c92` · 分支 `master`

## 1. 最新有效需求与边界

用户当前要求：

1. **先修 Kick 弹幕**，目标是 Windows 端能收到公开聊天。
2. 交付可用的 Windows 安装包。
3. **Kick 播放卡顿问题暂缓**；用户已明确说“卡的问题不用管了，先修弹幕”。没有新指示前不要恢复卡顿调查。

本批有效范围：

- 只修公开弹幕接收链路，不发送聊天消息。
- Windows 优先；共享 `KickDanmaku` 的实现会同时影响 Android 源码，但本轮没有重建 Android APK。
- 不改变播放器、清晰度、媒体请求头、卡顿策略或录制链路。
- 不递增版本、不创建 GitHub Release、不上传附件、不刷新 `assets/releases.json`。
- 没有当前明确的设备请求，不做 ADB、真机、模拟器或 Windows GUI 安装/启动验收。

## 2. 工作区、Git 与状态

- 工作区：`D:\purelive`；分支 `master`。
- 源码提交：`302e44c92ad7c7bf6a98d8374ce28f3d3e935d48` `fix(kick): 迁移公开弹幕到 Centrifugo 实时网关`，4 个文件，+514/−77。
- 上一源码基线：`cccae4bb1` `docs: 记录 Kick Android 恢复与双平台安装包`。
- 更早的 Kick Android/Windows 恢复基线：`d7d9c3e8d`。
- 远端：
  - `fork` = `https://github.com/crazylei12/pure_live.git`，本批推送目标。
  - `origin` = `https://github.com/liuchuancong/pure_live.git`，历史记录显示无写权限（403）；本批没有推送它。
  - `upstream` = `https://github.com/Jackiu1997/pure_live.git`，只读。
- **推送状态：源码提交已推送到 `fork/master`。** 远端 head 已核对为 `302e44c92ad7c7bf6a98d8374ce28f3d3e935d48`。
- 文档更新已推送；其哈希以 `git log` 为准。文档提交不改变应用源码基线。
- 工作区只剩未跟踪的 `.lcode/`；不要提交、不要删除其中的历史草稿。
- 没有版本 tag、GitHub Release、附件上传或 `assets/releases.json` 更新。

## 3. 根因与协议事实

### 3.1 旧链路的第一错状态

旧实现连接：

`wss://ws-us2.pusher.com/app/32cbd69e4b950bf97679?...`

并订阅 `chatrooms.<id>.v2`。本轮实测 `ws-us2`、`ws-us3`、`ws-eu`、`ws-ap1`、`ws-ap2`、`ws-mt1` 六个集群全部返回：

`4001 App key ... not in this cluster`

即旧 Pusher 应用 key 已失效，订阅从未成功。不要再把 4001 当作房间号、网络、代理或 UI 问题，也不要恢复该 key。

### 3.2 当前有效链路

1. `GET https://kick.com/api/v2/channels/<slug>` 取独立 `chatroom.id`。频道 ID、用户 ID 和 chatroom ID 可以不同，不能猜测。
2. `POST https://web.kick.com/api/v1/realtime/channels/<chatroomId>/chat/connection`，body：
   `{"client":{"id":"<uuid>","type":"web"},"capabilities":{"accepted_providers":[{"provider":"pusher"},{"provider":"centrifugo"}]}}`
   从 `data.connections[]` 中选择 `provider=centrifugo`，读取 `credentials.url`。
3. `POST https://web.kick.com/api/v1/realtime/auth/connection`，body `{"client_id":"<uuid>"}`，读取 `data.token`（游客 JWT）。
4. WebSocket 发送 `{"connect":{"token":"<jwt>","name":"js"},"id":1}`；收到 `{"id":1,"connect":{...}}` 后发送 `{"subscribe":{"channel":"chatrooms.<id>.v2","flag":1},"id":2}`；收到 `{"id":2,"subscribe":{}}` 才认为订阅成功。
5. 消息形状：`{"push":{"channel":"chatrooms.<id>.v2","pub":{"data":{"event":"App\\Events\\ChatMessageEvent","data":"<json string>"}}}}`。
6. Centrifugo keepalive 是空 JSON `{}`，收到后回复 `{}`；不要发送 Pusher 的 `pusher:ping`。

`kick.com` 对 dart:io 仍返回 403，频道 JSON 继续走既有 Windows WinHTTP / Android HttpURLConnection 原生 TLS 通道。`web.kick.com` 和 `realtime.*.platform.kick.com` 在本机 dart:io/dio 可直连，本轮没有扩大原生 TLS 主机白名单。

## 4. 本批源码改动

### 4.1 `lib/shared/platforms/kick/kick_api.dart`

新增：

- `typedef KickPostRequest` 和构造参数 `post`，测试可注入 POST。
- `realtimeOrigin = 'https://web.kick.com'`、`realtimeBase = '$realtimeOrigin/api/v1/realtime'`、`realtimeResponseLimit = 256 * 1024`、`realtimeHeaders`。
- `chatConnection({chatroomId, clientId, cancel})`：校验正整数 chatroom ID 和 UUID；POST 连接申请；只选择 `centrifugo` provider；交给 `_realtimeSocket` 校验。
- `chatToken({clientId, cancel})`：校验 UUID；POST 游客 JWT；交给 `_validGuestToken` 校验。
- `_defaultPost`：走 `HttpClient.instance.dio`，支持代理、取消和 20 秒超时，流式读取并限制 256 KiB。
- `_postJson`、`_failure`、`_realtimeSocket`、`_validGuestToken`。

安全约束：

- WebSocket 只接受 `wss://realtime.<region>.platform.kick.com/connection/websocket`。
- 必须无 userInfo、无 query、无 fragment，端口为 443 或缺省。
- UUID 必须符合标准 8-4-4-4-12 小写十六进制格式。
- JWT 必须是三段 `eyJ...` 形状，长度不超过 4096。
- 不恢复旧 Pusher key、不扩展原生 TLS 白名单、不猜测 chatroom ID。

既有 `chatroomId()` 保留；频道请求仍通过 `kick.com` 原生 TLS。

### 4.2 `lib/shared/platforms/kick/kick_danmaku.dart`

- 重写为 Centrifugo 引擎，保留 `LiveDanmaku` 生命周期和 `WebScoketUtils` 的有限重连、心跳超时、单一 socket 所有权。
- 每个会话生成 UUIDv4 游客客户端 ID；连接前获取 JWT；重连时 `_handshake` 重新获取 JWT。
- `connect` 成功后按 `subscribe` 回复；只有订阅成功才 `markConnected()` 并触发 `onReady`。
- 空 JSON `{}` 作为 keepalive，回复 `{}`。
- `parseFrame` 支持 `connect`、`subscribe`、错误帧、`push.disconnect`、当前和旧版聊天消息形状。
- 只转发目标 `chatrooms.<id>.v2` 的消息；`App\Events\ChatMessageEvent` 和 `App\Events\ChatMessageSentEvent` 均接受。
- 保留消息 ID、用户名、颜色、发送时间；`[emote:<id>:<name>]` 转为表情名称。
- `_generation` 防止旧会话在 stop/reconnect 后回写；`_subscriptionTimer` 在 10 秒内未订阅成功时触发重连。

### 4.3 测试与探针

- `test/shared/platforms/kick_danmaku_test.dart`：
  - chatroom 解析与身份不匹配拒绝。
  - 连接地址选择、非法 provider/URL/端口/query/path 拒绝。
  - JWT 格式校验。
  - 完整 `connect` → `subscribe` → 消息 → 关闭。
  - 旧消息形状、错误帧、空对象心跳、emote 文本。
- `tool/probes/kick_chat_probe_test.dart`：
  - 可选真实网络探针，不在普通 `test/` 目录，不会被常规测试自动执行。
  - 用 curl 获取频道 JSON（规避本机测试环境对 `kick.com` 的 TLS 限制），注入 request，仅替换测试 dio 适配器，真实调用生产 `KickApi` + `KickDanmaku`。
  - 默认频道 `xqc`，可用 `PURELIVE_KICK_SLUG` 覆盖；只输出聚合计数。
  - 本轮输出 `00:08 +1: All tests passed!`，收到真实聊天消息。

## 5. 验证记录

环境：Windows 10.0.26200，Flutter 3.47.5（`.fvmrc`），`tool/flutterw.ps1`。

### 5.1 本轮在干净提交上执行

- Analyze：
  `powershell -NoProfile -ExecutionPolicy Bypass -File tool/local_ci.ps1 -Scope Focused -Analyze -SkipPubGet`
  结果 `No issues found!`，Analyze 14.6 秒；记录
  `local-artifacts/build-records/20261118T113834952Z-quality-focused.json`，`source_commit=302e44c92`。
  记录中的 `source_worktree_dirty=true` 仅因未跟踪 `.lcode/`；跟踪文件干净，Windows 构建元数据也记录 `tracked_files_dirty=false`。
- 完整测试：
  `flutter test --no-pub --concurrency=12`（在 `tool/build_resource_guard.ps1` 的重型任务租约内）
  结果 **298/298 通过**，约 31 秒；日志
  `local-artifacts/build-records/20261118T113834952Z-kick-full-tests.log`。
- 旧的 Full 包装器尝试：
  `tool/local_ci.ps1 -Scope Full` 在 `repository_preflight` 失败：
  `Build policy file is missing: .github\workflows\audit-upstream.yml`
  记录 `local-artifacts/build-records/20261118T112542552Z-quality-full.json`。
  这是既有仓库策略漂移，不是本批 Kick 代码失败。不要把直接运行的 Analyze/测试说成 Full 包装器通过。

### 5.2 Windows Release 构建

命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_local_release.ps1 `
  -Target WindowsX64 -Configuration Release -SkipQuality
```

- 构建记录：`local-artifacts/build-records/20261118T113703179Z-build-windowsx64-release.json`
  - `status=succeeded`，`duration_seconds=308.703`
  - `source_commit=302e44c92...`
  - `quality=external-focused-or-existing-evidence`
- 安装程序：`D:\purelive\local-artifacts\3.1.19-4108\PureLive-3.1.19-4108-windows-x64-setup.exe`
  - 63,026,122 字节
  - SHA-256 `1c3396d09d650a1e35cb2aaa53de315394a82786d5771d56476733b8d516f962`
  - Authenticode `NotSigned`，ProductVersion `3.1.19`
- 便携包：`D:\purelive\local-artifacts\3.1.19-4108\PureLive-3.1.19-4108-windows-x64-portable.zip`
  - 80,992,861 字节
  - SHA-256 `078cd3d2a22d8d51f506a0b0607ced96aff85599faedc7b3eba252d26f493ca8`
- 元数据：`WINDOWS_BUILD_METADATA.json` 记录 `source_commit=302e44c92...`、`tracked_files_dirty=false`。
- 便携包含 `msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`。
- 从便携包解出的 `data/app.so` 与 `build/windows/x64/runner/Release/data/app.so` 哈希一致：
  `069681adf530a9fecf7f97c181259cad1d28bb26ddfb222b689139eda5c846ed`
  且包含 `web.kick.com`、`chatrooms.`、`App\Events\ChatMessageEvent`，确认构建的是新代码。
- 构建使用 `-SkipQuality` 的原因：Full 包装器被上述既有缺失工作流阻断；但本提交已在干净工作树上直接完成 Analyze 和 298 个测试。构建脚本自身完成 FFmpeg/Firebase 缓存核验、Windows 运行库白名单、便携 ZIP、Inno Setup 和哈希/元数据生成。

### 5.3 明确未执行

- Windows 安装程序安装、启动、Kick 房间播放、弹幕呈现、长时间运行。
- Android APK 重建或真机/模拟器验收；同目录的 Android APK 是修复前产物，不含 Centrifugo 修复。
- GitHub Release、附件上传、正式签名、`assets/releases.json` 刷新。
- 播放卡顿调查（用户明确暂缓）。

## 6. 已知缺陷 / 风险 / 阻断

- **Full 质量包装器阻断**：`tool/validate_build_policy.ps1` 仍要求已被 `4a0cf09fe` 删除的 `.github/workflows/audit-upstream.yml`，还引用了同样被删除的 `sign-staged-android.yml`、`feature-build.yml`、`local-signed-android.yml`、`publish-staged-release.yml` 等。不要为了通过门禁盲目恢复这些工作流，也不要修改业务源码去迎合旧策略。
- **插件路径校验漂移**：同一校验器仍按旧的 `plugins/flv_lzc/android/...` 路径检查 16 KB fplayer AAR，而当前 `flv_lzc` 是 Git 依赖（`pubspec.lock` 锁定 `162030d6...`），实际路径在 Pub cache，应用 `android/build.gradle.kts` 使用 `rootProject.project(":flv_lzc").projectDir.resolve("libs")`。如果未来修复该验证器，应按 `.dart_tool/package_config.json` 解析当前 Git 插件根目录并继续核验同一 AAR 哈希 `3643B36B...`；不要恢复 4 KB 公共 AAR，不要放宽为无条件通过。
- **Windows 界面未验收**：构建成功、包内代码正确不等于真实播放页弹幕已显示；必须由用户安装后确认。
- **安装包未签名**：SmartScreen 可能拦截。
- **版本未递增**：`3.1.19+4108`；不是新版本发布。
- **旧 Android APK 陷阱**：`local-artifacts/3.1.19-4108/` 下的 Android APK 构建于本次修复之前，不能当作包含 Centrifugo 的 Android 包。
- **真实网络依赖**：`web.kick.com` 和 realtime 主机当前直连可用；未来协议或主机可能再次变化。探针是可选网络测试，不应加入常规 CI 的必经路径。
- **未覆盖风险**：长时间 token 过期、网络切换、服务端主动断开、后台恢复和代理组合未做真实环境长跑；只有单元测试分支覆盖。

## 7. 剩余任务与建议顺序

1. **用户验收 Windows**：运行 setup.exe 或解压便携包，进入 Kick 直播间，确认弹幕能出现、能滚动、颜色和 emote 文本正常；同时观察长时间连接。
2. 如果 Windows 验收通过且用户仍要 Android：重新构建 Android arm64 Release（共享 `KickDanmaku` 已包含修复），再做真机验收；旧 APK 不要复用。
3. 如果要做正式交付：先决定是否修复 Full 包装器阻断；在干净收敛提交上完成完整门禁，再按 `BUILD_POLICY.md` 做版本递增、签名、tag/Release、附件和索引更新。
4. 只有在用户重新提出时才恢复 Kick 播放卡顿调查；不要因为修复了弹幕就顺手改播放器。
5. 文档提交已推送；如需在交付说明中引用文档提交哈希，以 `git log` 为准；不要改写已推送的源码提交。

## 8. 操作权限与禁止事项

- 当前授权范围：提交/推送本批源码，构建 Windows 本机安装包，更新交付文档。
- 不得在无当前设备请求时做 ADB、真机、模拟器或 Windows GUI 操作。
- 不得创建 GitHub Release、上传附件、更新发布索引或递增版本，除非用户明确要求。
- 不得强推、改写远端历史、删除无关分支或覆盖用户数据。
- 不得提交 `.lcode/`、`android/key.properties`、签名文件、密钥或未脱敏日志。
- 不得把未签名的 setup.exe 说成正式发布包。
- 不得把“构建成功”或“单元测试通过”说成 Windows 界面弹幕验收通过。
- 不得恢复已失效的 Pusher key、已删除的发布工作流或 4 KB fplayer AAR 来绕过门禁。
- 不得用“重试/刷新/延迟”替代对失败原因的诊断。

## 9. 关键命令

```powershell
# 干净提交上的 Analyze
powershell -NoProfile -ExecutionPolicy Bypass -File tool/local_ci.ps1 `
  -Scope Focused -Analyze -SkipPubGet

# 完整测试（资源守卫内；不要与构建并行）
. .\tool\build_resource_guard.ps1
$lease = Enter-PureLiveHeavyTaskSlot -TaskName "Kick full test suite"
try {
  .\tool\flutterw.ps1 test --no-pub --concurrency=12
} finally {
  Exit-PureLiveHeavyTaskSlot -Lease $lease
}

# 真实网络生产链路探针（可选，需要 curl 和可用的 Kick 频道）
.\tool\flutterw.ps1 test tool/probes/kick_chat_probe_test.dart

# Windows x64 Release（本轮实际命令）
powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_local_release.ps1 `
  -Target WindowsX64 -Configuration Release -SkipQuality
```

> `flutterw.ps1` 的 `--device-id` 必须用长参数；PowerShell 会把 `-d` 绑定到自己的 `-Debug` 开关。

## 10. 关联文档

- 用户结果说明：[KICK_WINDOWS_RESTORE_2026_11_18.md](KICK_WINDOWS_RESTORE_2026_11_18.md)
- 平台兼容性：[PLATFORM_COMPATIBILITY.md](PLATFORM_COMPATIBILITY.md)
- 旧 Pusher 审计（已被本次 Centrifugo 迁移取代，仅保留历史证据）：[KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md](KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md)
- 历史平台探针：[PLATFORM_PROBE_2026_09_25.md](PLATFORM_PROBE_2026_09_25.md)
