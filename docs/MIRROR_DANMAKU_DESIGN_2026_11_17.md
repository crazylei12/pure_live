# 同房间同步显示另一间直播弹幕：工作结果说明

- 日期：2026-11-17
- 状态：功能已提交到本地 `master`（未推送）；Windows x64 Release 便携包与安装程序已构建并核验；用户已手工试用 Windows 构建；真实平台与完整设备验收仍未完成
- 源码基线：`master` @ `233a252ac5502477c2eb21ebd80204d577b2e125`，应用版本 `3.1.19+4108`（Windows 构建号 4108）
- 技术交接文档：[MIRROR_DANMAKU_AI_HANDOFF_2026_11_17.md](./MIRROR_DANMAKU_AI_HANDOFF_2026_11_17.md)

## 结果

功能已经按“源码级自包含模块”的方式落地，而不是运行时插件。现在打开 A 直播间后，可以从右上角应用菜单进入“同步弹幕”，为当前房间保存一个 B 直播间；B 的**聊天弹幕**会同时进入 A 的侧栏列表、视频滚动层和小窗/悬浮弹幕层。配置按 A 的房间身份（`platform:roomId`）持久化，进入 C 房间不会继承 A 的 B。

本轮达到的是“代码已提交到本地 + 全量测试与 Analyze 通过 + Windows Release 安装包已生成”的本地交付检查点。Windows 构建已由用户实际试用；我没有重新执行真实 B 房间收发、小窗/悬浮和安装程序的完整手工验收，也没有成功推送、发布或做 Android 构建。仓库的架构严格检查仍因一条已提交的基线违规返回 `EXIT:1`（不是本次改动引入）；`local_ci -Scope Full` 仍被缺失的既有策略文件 `audit-upstream.yml` 阻塞。

运行时插件方案仍然不可行：项目没有运行时插件注册表或 UI/弹幕扩展点，Flutter Release/AOT 不能动态加载任意 Dart UI 和业务代码。首版继续采用 `lib/domains/live` 内的模块 + 少量接入点，后续可作为独立 PR 提交上游。

## 本次变更与提交状态

- **两次本地提交，尚未推送**：`826bc203d`（`feat(live): 支持同房间同步显示另一间直播的聊天弹幕`）和 `233a252ac`（`build(ffmpeg): 恢复五平台 FFmpeg 9.0.2 原生资产地址`）。
- 功能提交包含 5 个修改文件与 7 个新增源码文件、7 个测试文件 + 1 个 fakes 辅助文件、中英文各 47 个文案键；`pubspec.yaml` 的 FFmpeg 地址单独提交，因为构建脚本按 9.0.2 原生包哈希校验，缺失时干净环境会回退到 9.0.1。
- `git push origin master` 返回 **403**：当前 `gh` 登录账号 `crazylei12` 对 `liuchuancong/pure_live` 没有写权限。提交保留在本地，没有 force-push，也没有改远端。
- `.lcode/` 仍是未跟踪目录（含早期 `.bak` 备份），未提交，也不属于交付物。

## 已完成

### 1. 配置、持久化与解析

- `lib/domains/live/data/mirror_danmaku/mirror_danmaku_config.dart`
  - 每个 A 房间保存一个 B：`platform`、`roomId`、`sourceUrl`、`nick`、`title`、`enabled`、`version`。
  - 不持久化 `danmakuData`、cookie、token；每次进入房间重新解析。
  - JSON 版本不符、平台/房间号为空或非对象输入都按“未配置”处理。
- `lib/domains/live/data/mirror_danmaku/mirror_danmaku_store.dart`
  - Hive 键固定为 `mirror_danmaku_v1:<A 的 identityKey>`，C 房间读写不到 A 的配置。
  - 写入/删除失败返回 `false`；损坏 JSON 记日志后返回未配置，不阻塞房间。
- `lib/domains/live/data/mirror_danmaku/mirror_danmaku_resolver.dart`
  - 解析链接/分享文本，校验平台是否支持弹幕、是否指向 A 自己、详情是否可用；默认 15 秒超时，支持取消。
  - B 未开播时允许保存，但 `canConnect=false`，不建立连接；可手动重试。
  - 详情请求失败、平台不支持、弹幕参数缺失等都有明确失败类型。

### 2. 第二弹幕会话

`lib/domains/live/presentation/playback/services/mirror_danmaku_session.dart`

- 独立于 A 的 `DanmakuController`，使用自己的引擎、epoch 和串行队列；启动超时 20 秒，停止超时 5 秒。
- 只转发 `LiveMessageType.chat`；礼物、在线人数、Super Chat、通知、撤回全部忽略。
- 应用 A 现有设置：屏蔽用户、屏蔽关键词、重复弹幕折叠、相似度过滤。
- 断开后旧引擎回调失效；终端关闭上报错误，不做无上限自动重连。
- 不把 B 的网络表情注册进进程级 `EmojiAtlas`，避免覆盖 A 平台同 code 的表情。

### 3. 房间级控制器与生命周期

`lib/domains/live/presentation/playback/controllers/mirror_danmaku_controller.dart` 和 `mirror_danmaku_host.dart`

- 每个 `LivePlayController` 持有一个实例，不是全局单例；所有异步结果都按宿主身份和 epoch 隔离。
- 支持：进入 A 自动恢复、解析/预览、保存并启用、停用、删除、重试连接。
- 只在 A 当前是直播、非录播/轮播/回看、非 IPTV/CC 且平台支持弹幕时运行；B 未开播只显示离线状态。
- 跟随 A 的生命周期：
  - A 确认在播后 `attachHost`，从悬浮窗恢复后重新 `ensureConnected`；
  - 切到 C 房间、A 不在播、加载失败或 IPTV 分支时 `detachHost`；
  - 全局弹幕开关关闭时断开，打开后在条件满足时重连；
  - A 把播放交给应用小窗时，路由关闭不提前停止 B；小窗资源最终释放时再 `dispose`。
- 连接成功、终端失败会向 A 的侧栏写系统消息；目标未开播在重试/保存路径提示，首次进入 A 时只显示离线状态。

### 4. 消息出口

`live_play_controller.dart` 中的 `deliverMirrorChatToRoom` 把同一条 `LiveMessage` 原样写入：

- 侧栏历史：`addDanmakuMessage`（沿用 64ms 批量、500 条历史上限、200 条待批上限）；
- 视频滚动层：当前 `videoController.sendDanmaku`；
- 小窗/悬浮层：`GlobalPlayerService.instance.player.sendFloatingDanmaku`。

不复制消息、不加前缀、不改用户名/用户 id/message id/表情 span；侧栏“屏蔽该用户”仍使用 B 的真实用户名。

### 5. 界面与文案

- 右上角应用菜单新增第 9 项“同步弹幕”（`live_play_menu_button.dart:228`）。房间详情未就绪、录播/轮播/回看、IPTV/CC 或平台不支持弹幕时置灰；强行进入会提示“当前房间无法使用同步弹幕”。
- `mirror_danmaku_dialog.dart` 提供：启用开关、链接输入、解析/预览、保存并启用、停用、删除、重试，以及解析中/未开播/连接中/已连接/失败状态。
- 中文和英文各新增 47 个 `mirror_danmaku*` 文案键，键集合一致。

### 6. 测试

7 个测试文件（另有一个 fakes 辅助文件；本轮全量套件已全部包含并通过）：

- `test/domains/live/mirror_danmaku_config_test.dart`：JSON 往返、版本/身份校验、自己房间判断；
- `test/domains/live/mirror_danmaku_store_test.dart`：按 A 隔离、C 读不到、损坏 JSON、写/删失败；
- `test/domains/live/mirror_danmaku_resolver_test.dart`：正常解析、空输入/非法链接/不支持平台/指向自己、未开播、弹幕参数缺失、详情失败、超时、取消、重试路径；
- `test/domains/live/mirror_danmaku_session_test.dart`：只转发 chat、屏蔽用户/关键词、重复折叠、表情不写全局 atlas、启动失败/超时、旧引擎回调失效、终端关闭、停止超时、无弹幕参数拒绝；
- `test/domains/live/mirror_danmaku_controller_test.dart`：自动连接、C 隔离、旧消息隔离、未开播、重复 attach 幂等、回放/轮播/录制不连接、A 从直播变回放断开、停用/删除、写入失败、全局弹幕开关、小窗保留与释放；
- `test/domains/live/mirror_danmaku_forwarding_test.dart`：原对象同时进入历史/画面/小窗，画面层不可用时其余两层仍写入；路由关闭且保留小窗时系统消息写入小窗，未关闭时只写历史；
- `test/domains/live/mirror_danmaku_dialog_test.dart`：对话框在 `attachHost` 完成前按持久化配置初始化，保存不会重新启用已停用配置；停用写盘失败时开关保持启用并提示保存失败。

### 7. 质量门

- 本工作流在源码提交 `233a252ac` 上执行等价全量门禁：`.\tool\local_ci.ps1 -Scope Focused -TestPath test -Analyze -SkipPubGet`，记录 `local-artifacts/build-records/20261117T144813778Z-quality-focused.json`：`status=succeeded`，全量测试 **284/284 通过**，`flutter analyze` **No issues found**，`format_mode=apply` 且 0 个文件被改动，`source_changed_during_run=false`，耗时 168.997 秒。
- `.\tool\build_local_release.ps1 -Target WindowsX64 -Configuration Release -FullRegression` 在 `repository_preflight` 阶段被 `tool/validate_build_policy.ps1` 阻塞：缺少 `.github/workflows/audit-upstream.yml`。该文件在 `4a0cf09fe` 被删除，属于既有基线不一致（[ISSUE_927 审计](./ISSUE_927_PORTRAIT_LIVE_LAYOUT_AUDIT_2026_11_01.md) 记录过同一问题），不是本次改动引入。因此改用上面的等价门禁，并以 `-SkipQuality` 完成 Release 构建；构建记录 `20261117T145437322Z-build-windowsx64-release.json`，`status=succeeded`，耗时 327.536 秒。
- Windows 产物核验：`pure_live.exe` 版本 `3.1.19+4108`；`libffmpegkit.dll` SHA-256 `302d9780…` 与固定 9.0.2 值一致；便携包含 `msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`、`WebView2Loader.dll`，无 `kernel_blob.bin` 或 `.pdb/.ilk/.lib/.exp`；包内 `zh.json` 含 47 个 `mirror_danmaku*` 键。安装程序由 Inno Setup 6.7.3 生成，ProductVersion `3.1.19`，未签名。
- 本轮复跑 `python tool/validate_architecture.py --strict`，输出：

  ```text
  domains/recorder -> domains/live/domain/global_player_service.dart   [domains/recorder/presentation/pages/local_player/local_video_player_controller.dart]

  hard violations: 1 unapproved + 21 approved   stale ledger entries: 0   soft advisories: 120
  EXIT:1
  ```

  该未批准违规来自已提交的 `domains/recorder` 文件，不在本次改动范围内；本次新文件没有引入新的硬违规，新增 10 条同域 `presentation -> data` 软提示。

## 已知问题与审查项状态

| 问题 | 影响 | 关键证据 |
| --- | --- | --- |
| 架构严格检查未通过（既有基线） | 不能声称 `--strict` 全绿；交付门禁仍为红 | `lib/domains/recorder/presentation/pages/local_player/local_video_player_controller.dart:15` 导入 live 域；该文件未被本次修改（`git diff --stat HEAD -- <该文件>` 无输出）；引入提交 `f1dd6cfb4`（2026-10-07）是 HEAD 祖先；ledger 未登记该边 |
| 对话框初始化存在竞态 | 打开对话框时若 `attachHost` 尚未读完配置，开关默认“启用”；随后保存可能把已停用的配置重新启用，或要求用户重输 URL | **已修复**：`MirrorDanmakuEditor` 在 `initState` 用 `readSavedConfig` 先读持久化配置（`mirror_danmaku_dialog.dart:52-60`、`mirror_danmaku_controller.dart:113-115`）；回归见 `mirror_danmaku_dialog_test.dart:103` |
| 停用写盘失败时开关仍被置为关闭 | 用户会以为镜像已关闭，但存储和 B 会话仍保持启用 | **已修复**：`_disable()` 只在 `disabled == true` 时置 `_enabled = false`，失败保持开关开启并提示（`mirror_danmaku_dialog.dart:151-160`）；回归见 `mirror_danmaku_dialog_test.dart:123` |
| 仅剩应用小窗时镜像系统消息丢失 | 小窗用户看不到“连接失败/未开播”等镜像提示 | **已修复**：新增 `deliverMirrorSystemMessage`，`addMirrorSystemMessage` 按 `isClosed`/保留小窗路由（`live_play_controller.dart:94-105`、`:1206-1214`）；回归见 `mirror_danmaku_forwarding_test.dart:46` |
| B 的网络表情在视频/小窗层可能显示为文字代码 | 侧栏可用消息自带的 emote URL 渲染；视频/小窗只查全局 `EmojiAtlas`，而 B 表情刻意未注册到 atlas | 会话在 `mirror_danmaku_session.dart:240-245` 明确不注册；侧栏走 `danmaku_list_view.dart:596-598` 的 `message.emotes`；画面/小窗分别使用 `player_danmaku_surface.dart:92`、`compact_danmaku_overlay.dart:135` 的全局 atlas |
| 测试未覆盖上述失败分支 | 当前通过结果不能证明这些路径正确 | **已补关键用例**：对话框初始化、停用写失败、系统消息路由均有测试；仍没有菜单 widget 测试和真实 `isClosed` 路径的 UI 级验证 |

另外，仓库 `AGENTS.md:16-17` 称 `.github/workflows/architecture.yml` 在 CI 执行架构检查，但当前工作区 `.github/workflows` 只有 `build_pure_live_release.yml` 和 `update_releases.yml`，`grep -rn validate_architecture .github` 无结果；本环境无法验证 CI 门禁，也不能据此断定既有违规从未或长期未被拦截。这不属于本次功能改动。

## 尚未实现或仅部分实现

以下多数是已确认的首版取舍，不是遗漏：

- **多个 B**：每个 A 最多一个 B；不支持列表、多会话管理。
- **来源标记**：B 消息不加前缀，也不给 `LiveMessage` 增加来源字段；侧栏、画面、小窗中无法从文本区分 A/B。
- **B 的礼物/SC/观众数/公告/撤回**：不转发；B 已撤回的消息可能留在 A 的历史里，直到被 500 条上限挤出。
- **B 未开播自动恢复**：只保存配置、手动重试，不做定时轮询；A 打开期间 B 开播不会自动连接。
- **全屏弹幕设置面板入口**：首版只有右上角应用菜单；全屏面板没有房间上下文，未扩展。
- **每个镜像独立账号**：B 使用 App 现有平台账号/cookie 上下文。
- **Windows 多实例配置同步**：一个窗口改配置，另一个窗口不会实时同步。
- **真实平台与设备验收**：尚未由我连接真实 B 房间验证收发、断线、短链和多平台；Windows 构建已由用户试用，但安装程序和 Release 运行未做完整手工验收。
- **推送、发布、上游 PR**：本地提交已完成；推送被 403 阻塞；未发布、未开上游 PR。
- **Widget/UI 测试**：已新增两个对话框隔离用例；仍无菜单 widget 测试和真实关闭路径测试。
- **Android 构建与设备测试**：本轮按用户要求只做 Windows，未构建 Android。

## 验证结果与验收边界

已执行并有记录：

- 全量质量门：`.\tool\local_ci.ps1 -Scope Focused -TestPath test -Analyze -SkipPubGet`，284/284 测试通过、Analyze 无问题、0 个文件需格式化（记录 `20261117T144813778Z-quality-focused.json`）。
- Windows x64 Release 构建：`-SkipQuality`，记录 `20261117T145437322Z-build-windowsx64-release.json`，产物与哈希见“本次变更与提交状态”。
- 便携包内容核验：`pure_live.exe` 3.1.19+4108、MSVC 运行库齐全、`libffmpegkit.dll` 为 9.0.2、无调试残留、翻译含 47 个镜像键。
- 用户已手工试用 Windows 构建并反馈正常；这是用户侧验收，不是我本轮独立复现。
- 本轮复跑架构严格检查，得到上述 `EXIT:1`；该违规来自已提交的 `domains/recorder` 文件。
- 便携包内 `zh.json` 核对：含 47 个 `mirror_danmaku*` 键；中英文源文件键集在此前轮次已核对一致。

未执行：

- 安装程序的实际安装/卸载和 Release 运行时手工验收；
- 真实 B 平台连接（登录、cookie、地区限制、短链跳转、限流均未验证）；
- 侧栏/画面/小窗的镜像收发、PiP 与小窗悬浮完整手工验收；
- Android 构建与设备安装；
- 推送（403，未成功）、发布、上游合并。

因此：

- “单元测试通过”不等于“真实平台可用”；
- “代码已实现”不等于“已发布/已部署”；
- “等价全量门禁通过”不等于“仓库级 `Full` 全绿”：`Full` 被既有缺失策略文件阻塞，架构严格检查仍是红的；
- 小窗/悬浮层和表情渲染必须用真机和真实平台单独验收。

## 当前状态

当前是“**功能已本地提交、Windows Release 安装包已生成、尚未推送和发布**”的检查点。`HEAD` 为 `233a252ac` 或之后的 docs 提交，跟踪文件干净；`.lcode/` 备份和两份文档仍未跟踪（文档将在本轮末尾提交）。

安装包位置：`local-artifacts/3.1.19-4108/PureLive-3.1.19-4108-windows-x64-setup.exe`（未签名，ProductVersion 3.1.19）；便携包为同目录 `PureLive-3.1.19-4108-windows-x64-portable.zip`。

后续接手建议：先在具备 `liuchuancong/pure_live` 写权限的账号下推送本地提交；再安装本轮安装包做一次 Release 运行时验收（菜单、对话框、侧栏/画面/小窗镜像、PiP）；真实 B 平台至少验证两个平台和未开播/断线场景；最后才谈发布或上游 PR。不要回滚已提交的对话框修复和表情隔离策略。

## 相关文档

- [技术交接与实施细节](./MIRROR_DANMAKU_AI_HANDOFF_2026_11_17.md)
- [维护与质量工作流](./AGENT_WORKFLOW.md)
- [构建策略](../BUILD_POLICY.md)
- [上游审查策略](../UPSTREAM_REVIEW_POLICY.md)
- [维护策略](../MAINTENANCE_POLICY.md)
- [架构校验脚本](../tool/validate_architecture.py)
