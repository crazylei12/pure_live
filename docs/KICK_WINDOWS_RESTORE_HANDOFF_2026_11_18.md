# Kick 弹幕修复（Windows + Android）AI 技术交接

2026-11-18 · Kick 源码基线 `302e44c92` · Android 版本提交 `224f937d9` · 分支 `master`

## 1. 最新有效需求与边界

用户当前要求：

1. 修复 Kick 弹幕，Windows 端要能收到公开聊天。
2. Windows 包交付后，**再更新 Android**，并且**递增版本号**。
3. Android 使用**正式签名**，之后由用户独立维护；不要再用 Debug 证书回退。
4. **Kick 播放卡顿暂缓**；没有新指示前不要恢复卡顿调查。

本批范围：

- 只修公开弹幕接收，不发送聊天消息，不改播放器/清晰度/媒体链路。
- Windows 包保持 `3.1.19+4108`；Android 递增到 `3.1.20+4109`。
- Android 只构建 `arm64-v8a` Release APK。
- 生成独立 Release keystore 并签名；签名材料不进入 Git。
- 没有当前设备请求，不做 ADB、真机、模拟器或 Windows GUI 安装/启动验收。
- 没有创建 GitHub Release、tag、附件上传或发布索引更新。

## 2. 工作区、Git 与发布状态

- 工作区：`D:\purelive`；分支 `master`。
- 关键提交：
  - `302e44c92ad7c7bf6a98d8374ce28f3d3e935d48` `fix(kick): 迁移公开弹幕到 Centrifugo 实时网关`，4 个文件，+514/−77。
  - `224f937d92d3a8b40b880ae2927bc84c49b28e67` `chore(release): 递增 Android 版本到 3.1.20+4109`，只改 `pubspec.yaml` 和 `assets/version.json` 的顶层/Android 条目。
  - 早期交付文档提交：`7fbe9898f`、`6833c8690`。
  - 本轮最终文档提交在 `224f937d9` 之后，哈希以 `git log` 为准。
- 远端：
  - `fork` = `https://github.com/crazylei12/pure_live.git`，本批推送目标。
  - `origin` = `https://github.com/liuchuancong/pure_live.git`，历史记录显示无写权限（403），本批没有推送。
  - `upstream` = `https://github.com/Jackiu1997/pure_live.git`，只读。
- **源码已推送到 `fork/master`。** 最终 head 以 `git ls-remote fork refs/heads/master` 为准。
- 工作区跟踪文件干净；只剩未跟踪 `.lcode/`，不要提交或删除其中的历史草稿。
- `local-artifacts/` 是本机构建产物目录，不是 Git 内容。

## 3. 版本号现状

- `pubspec.yaml`：`3.1.20+4109`。
- `assets/version.json`：
  - 顶层：`3.1.20` / `4109` / `version_num=301204109` / `download_url=.../v3.1.20`。
  - Android：`3.1.20` / `4109` / `301204109` / `v3.1.20`。
  - Windows：仍为 `3.1.19` / `4108` / `301184108` / `v3.1.19`。
  - Linux/macOS/iOS：仍为 `3.1.19`，本轮没有重建这些平台。
- `windows/packaging/msix/make_config.yaml`：仍为 `3.1.19.4108`，与 Windows 版本条目一致。
- `assets/releases.json`：仍是已发布的 `3.1.19` 索引，**没有**加入 3.1.20；因为本轮没有发布 Release。
- `RELEASE_NOTES.md`：文件顶部是更晚的 3.2.x 线，且没有 3.1.19/3.1.20 段落；本轮没有改写，避免把两个版本线混在一起。若后续正式发布，需要单独决定如何整理发布说明。
- `.github/workflows/build_pure_live_release.yml` 的默认 tag 仍是 `v3.1.18`，属于既有漂移；本轮没有改，避免手动工作流误用 3.1.20 去构建仍是 3.1.19 的 Windows 包。

## 4. Android 签名材料（重要）

已生成独立 Release 签名材料：

- Keystore：`D:\purelive-signing\purelive-release.p12`
  - PKCS12，RSA 4096，别名 `purelive`，有效期 36500 天。
  - 证书主体：`CN=Pure Live Release, OU=Android, O=Pure Live, C=CN`
  - 证书 SHA-256：`35:BC:29:C1:64:A8:EB:97:B7:75:B1:C7:7D:9E:E4:85:A3:58:A3:44:6C:CC:4D:5B:25:E8:D0:41:D0:80`
- 本机备份：`D:\purelive-signing\backup\purelive-release.p12` 和 `backup\key.properties`。
- Gradle 配置：`D:\purelive\android\key.properties`，已被 `.gitignore` 忽略。
- 说明：`D:\purelive-signing\SIGNING_README.txt`。
- 密码只存在于 `android/key.properties` 和备份 `key.properties`，**不在本文档、不在 Git、不要打印到日志**。

注意事项：

- 这是 Android 应用更新身份；丢失 keystore 或密码后，无法覆盖安装后续版本。必须做离线备份，最好放到另一块磁盘/离线介质。
- 不要提交 `android/key.properties`、`.p12`、`.jks`、`key.properties` 备份或任何密码。
- 构建 Release 必须显式加 `-RequireReleaseSigning`；脚本在缺少签名配置时仍允许回退 Debug 证书。
- 当前 APK 只启用 **APK Signature Scheme v2**，没有 v3/v3.1 密钥轮换。Android 7.0+ 可验证；若以后要做密钥轮换，需要另行规划。
- CI 还没有这套签名密钥；如果要在 GitHub Actions 签名，需要把 keystore 和密码写入仓库 Secrets，并重建/恢复签名工作流。不要直接把密钥提交到仓库。

## 5. 根因与协议事实

### 5.1 旧链路第一错状态

旧实现使用 Pusher key `32cbd69e4b950bf97679`，实测 `ws-us2`、`us3`、`eu`、`ap1`、`ap2`、`mt1` 六个集群全部返回：

`4001 App key ... not in this cluster`

订阅从未成功。不要再把 4001 当作房间号、网络、代理或 UI 问题，也不要恢复该 key。

### 5.2 当前有效链路

1. `GET https://kick.com/api/v2/channels/<slug>` 取独立 `chatroom.id`；频道 ID、用户 ID 和 chatroom ID 可以不同，不能猜测。
2. `POST https://web.kick.com/api/v1/realtime/channels/<chatroomId>/chat/connection`，body：
   `{"client":{"id":"<uuid>","type":"web"},"capabilities":{"accepted_providers":[{"provider":"pusher"},{"provider":"centrifugo"}]}}`
   从 `data.connections[]` 选择 `provider=centrifugo`，读取 `credentials.url`。
3. `POST https://web.kick.com/api/v1/realtime/auth/connection`，body `{"client_id":"<uuid>"}`，读取游客 JWT。
4. WebSocket 发送 `{"connect":{"token":"<jwt>","name":"js"},"id":1}`；收到 `{"id":1,"connect":{...}}` 后发送 `{"subscribe":{"channel":"chatrooms.<id>.v2","flag":1},"id":2}`；收到 `{"id":2,"subscribe":{}}` 才标记订阅成功。
5. 消息形状：`{"push":{"channel":"chatrooms.<id>.v2","pub":{"data":{"event":"App\\Events\\ChatMessageEvent","data":"<json string>"}}}}`。
6. Centrifugo keepalive 是空 JSON `{}`，收到后回复 `{}`。

`kick.com` 对 dart:io 仍返回 403，频道 JSON 继续走 Windows WinHTTP / Android HttpURLConnection 原生 TLS 通道。`web.kick.com` 和 `realtime.*.platform.kick.com` 在本机 dart:io/dio 可直连，没有扩大原生 TLS 白名单。

## 6. 源码改动

### 6.1 `lib/shared/platforms/kick/kick_api.dart`

- 新增可注入 `post`、`KickPostRequest`。
- 新增 `realtimeOrigin`、`realtimeBase`、`realtimeResponseLimit=256*1024`、`realtimeHeaders`。
- 新增 `chatConnection({chatroomId, clientId, cancel})`、`chatToken({clientId, cancel})`。
- 新增 `_defaultPost`、`_postJson`、`_failure`、`_realtimeSocket`、`_validGuestToken`。
- WebSocket 只接受 `wss://realtime.<region>.platform.kick.com/connection/websocket`、443/缺省端口、无 userInfo/query/fragment。
- 校验 UUID 和 JWT 形状；实时响应限制 256 KiB。
- 既有 `chatroomId()` 保留，继续走 `kick.com` 原生 TLS。

### 6.2 `lib/shared/platforms/kick/kick_danmaku.dart`

- 重写为 Centrifugo 引擎，保留 `LiveDanmaku` 生命周期、有限重连、心跳超时和单一 socket 所有权。
- 每个会话生成 UUIDv4 游客客户端 ID；连接和重连时获取 JWT。
- `connect` 后按 `subscribe` 回复；订阅成功才 `markConnected()` / `onReady`。
- 空 JSON `{}` keepalive 回复 `{}`。
- 支持当前和旧版消息形状、错误帧、`push.disconnect`、消息房间校验。
- 保留消息 ID、用户名、颜色、时间；`[emote:<id>:<name>]` 转为表情名称。
- `_generation` 防止旧会话回写；订阅 10 秒超时触发重连。

### 6.3 测试与探针

- `test/shared/platforms/kick_danmaku_test.dart`：chatroom 解析/身份拒绝、连接地址安全、JWT 校验、完整握手/订阅/消息/关闭、旧消息形状、错误帧、keepalive、emote。
- `tool/probes/kick_chat_probe_test.dart`：可选真实网络探针；用 curl 取频道 JSON，仅替换测试 dio 适配器，真实调用生产 `KickApi` + `KickDanmaku`。本轮输出 `00:08 +1: All tests passed!`。

## 7. Android 构建事实与关键坑

### 7.1 实际命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_local_release.ps1 `
  -Target AndroidArm64 -Configuration Release -SkipQuality -RequireReleaseSigning
```

- 构建记录：`local-artifacts/build-records/20261118T115523193Z-build-androidarm64-release.json`
  - `status=succeeded`，`source_commit=224f937d9...`，`duration_seconds=374.004`
  - `tracked_files_dirty=false`，`android_signing=release`
- **记录器 caveat**：构建记录的 `command` 字段没有写出 `-RequireReleaseSigning`（脚本既有省略），但 `BUILD_METADATA.json` 的 `android_signing=release` 和 APK 签名证书证明实际使用了 Release 密钥。不要因为 `command` 字段缺开关就误判成 Debug 签名。

### 7.2 APK 事实

- 路径：`D:\purelive\local-artifacts\3.1.20-4109\PureLive-3.1.20-4109-android-arm64-v8a-release.apk`
- 139,036,981 字节
- SHA-256 `e908c978a87e93734aa758f641dc787c6634ccda67cebbbbb2dee352be20fdb3`
- `versionName=3.1.20`，Manifest `versionCode=6109`，`minSdk=26`，`targetSdk=37`
- 仅 `arm64-v8a`；18 个原生库
- 最小 ELF LOAD 对齐 `0x4000`，zipalign 通过
- `apksigner verify`：v2 签名通过，证书 SHA-256 `35bc29c164a8eb97b775b1c77d9ee485a358a3446ccc4d5b25e8d041d0803280`
- 包内 `lib/arm64-v8a/libapp.so` 含 `web.kick.com`、`chatrooms.`、`App\Events\ChatMessageEvent`
- `classes.dex` 无 `IntegrationTestPlugin`
- 元数据：`local-artifacts/3.1.20-4109/BUILD_METADATA.json`、`SHA256SUMS.txt`

### 7.3 Release 插件注册表坑（必须记住）

`flutter test`、`flutter analyze` 或普通 Debug 配置会把 `integration_test` 写回：

`android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`

Android Release 构建前必须先执行：

```powershell
.\tool\flutterw.ps1 build apk --release --config-only `
  --split-per-abi --target-platform android-arm64 `
  --build-name=3.1.20 --build-number=4109
```

然后确认：

```powershell
Select-String -Path android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java `
  -Pattern integration_test
```

必须无匹配，再运行 `build_local_release.ps1 ... -SkipQuality -RequireReleaseSigning`。本轮已经在最终测试后重新执行了 config-only，当前注册表是干净的；但下次测试后要重新做。

## 8. 质量验证

### 8.1 本批在 `224f937d9` 上执行

- Analyze：
  `tool/local_ci.ps1 -Scope Focused -Analyze -SkipPubGet`
  - `No issues found!`，13.9 秒
  - 记录：`local-artifacts/build-records/20261118T115740778Z-quality-focused.json`
  - 记录 `source_commit=224f937d9`；`source_worktree_dirty=true` 仅因未跟踪 `.lcode/`，跟踪文件干净。
- 完整测试：
  `flutter test --no-pub --concurrency=12`（资源守卫租约内）
  - **298/298 通过**，约 45 秒
  - 日志：`local-artifacts/build-records/20261118T115740778Z-android-full-tests.log`

### 8.2 Full 包装器阻断

`tool/local_ci.ps1 -Scope Full` 仍在仓库预检失败：

`Build policy file is missing: .github\workflows\audit-upstream.yml`

该文件已在历史提交 `4a0cf09fe` 中删除，但 `tool/validate_build_policy.ps1` 仍要求它；同一校验器还引用了同样被删除的 `sign-staged-android.yml`、`feature-build.yml`、`local-signed-android.yml`、`publish-staged-release.yml` 等，并按旧的 `plugins/flv_lzc/android/...` 路径检查 AAR。不要为了过门禁盲目恢复旧工作流或旧 4 KB AAR。上面的 Analyze/298 测试是直接运行的真实结果，不是 Full 包装器通过。

## 9. 已确认未解决 / 风险

- Android 真机安装、Kick 播放、弹幕呈现、长时间稳定性未验收。
- Windows 安装程序安装/启动/界面未验收。
- Full 质量包装器被既有缺失工作流阻断。
- Windows setup.exe 未做 Authenticode 签名。
- Android APK 仅 v2 签名，没有 v3/密钥轮换。
- 签名材料只有本机副本；没有离线/异机备份。
- 没有 tag、GitHub Release、附件上传、`assets/releases.json` 更新或 Release Notes 更新。
- 版本线：Android 3.1.20，Windows 3.1.19；不要误以为 Windows 包也更新了。
- Android 其他 ABI 未构建。
- 长时间 token 过期、网络切换、后台恢复未做真实环境长跑。
- Kick 播放卡顿未调查。

## 10. 剩余任务与建议顺序

1. **用户验收 Android**：安装 `PureLive-3.1.20-4109-android-arm64-v8a-release.apk`，进入 Kick 房间确认弹幕、播放、颜色和 emote 文本；观察断网重连。
2. **用户验收 Windows**：安装 `PureLive-3.1.19-4108-windows-x64-setup.exe` 或解压便携包，确认 Kick 弹幕。
3. **备份签名材料**：把 `D:\purelive-signing`（keystore + 备份 + key.properties）复制到离线介质；不要提交到 Git。
4. 如果要做正式发布：决定是否更新 `RELEASE_NOTES.md`/`assets/releases.json`，创建 `v3.1.20` tag/Release，上传 APK 并核对哈希；如要走 CI 签名，配置 GitHub Secrets，不要提交密钥。
5. 如果 Full 门禁必须通过：单独修复 `validate_build_policy.ps1` 的缺失工作流和 Git 插件路径漂移，保留 16 KB AAR 哈希校验；不要在业务提交里夹带。
6. 如果用户要求 Windows 也升到 3.1.20：同步 Windows feed/MSIX 并重新构建 Windows，不能把 3.1.19 包标成 3.1.20。
7. 只有用户重新提出时才恢复 Kick 播放卡顿调查。

## 11. 操作权限与禁止事项

- 当前授权：提交/推送源码和文档、构建 Android/Windows 本机包、生成本机 Release 签名材料。
- 不得在无当前设备请求时做 ADB、真机、模拟器或 Windows GUI 操作。
- 不得提交 `android/key.properties`、`.p12`/`.jks`、密码或包含密码的日志。
- 不得删除、覆盖或轮换现有 Release keystore；丢失将导致无法覆盖更新。
- 不得在 Release 构建中省略 `-RequireReleaseSigning`，也不得在测试后跳过 config-only 直接构建。
- 不得创建 GitHub Release、上传附件或更新 `assets/releases.json`，除非用户明确要求。
- 不得强推、改写远端历史、删除无关分支或覆盖用户数据。
- 不得把构建成功、单元测试或签名验证说成真实设备/界面验收。
- 不得把 Windows 3.1.19 包说成 Android 同一版本或已发布版本。
- 不得恢复旧 Pusher key、被删除的发布工作流或 4 KB fplayer AAR 来绕过门禁。
- 不得用“重试/刷新/延迟”替代对失败原因的诊断。

## 12. 关键命令

```powershell
# 版本一致性检查（注意 PowerShell 读取 UTF-8 JSON 要显式 -Encoding UTF8）
$j = Get-Content -LiteralPath assets\version.json -Raw -Encoding UTF8 | ConvertFrom-Json
$j.version; $j.build_number; $j.platforms.android.version; $j.platforms.windows.version

# Analyze
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

# 测试后恢复 Release 插件注册表
.\tool\flutterw.ps1 build apk --release --config-only `
  --split-per-abi --target-platform android-arm64 `
  --build-name=3.1.20 --build-number=4109

# Android Release（正式签名）
powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_local_release.ps1 `
  -Target AndroidArm64 -Configuration Release -SkipQuality -RequireReleaseSigning

# 验证签名和证书
& "$env:ANDROID_HOME\build-tools\37.0.0\apksigner.bat" verify --verbose --print-certs `
  local-artifacts\3.1.20-4109\PureLive-3.1.20-4109-android-arm64-v8a-release.apk
```

## 13. 关联文档

- 用户结果说明：[KICK_WINDOWS_RESTORE_2026_11_18.md](KICK_WINDOWS_RESTORE_2026_11_18.md)
- 平台兼容性：[PLATFORM_COMPATIBILITY.md](PLATFORM_COMPATIBILITY.md)
- 旧 Pusher 审计（已被 Centrifugo 迁移取代，仅保留历史证据）：[KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md](KICK_PUBLIC_CHAT_AUDIT_2026_09_23.md)
- 历史平台探针：[PLATFORM_PROBE_2026_09_25.md](PLATFORM_PROBE_2026_09_25.md)
