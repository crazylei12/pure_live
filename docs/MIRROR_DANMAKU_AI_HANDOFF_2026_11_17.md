# 同房间同步弹幕功能：AI 接手与技术交接

- 日期：2026-11-17
- 状态：功能已本地提交（`826bc203d`、`233a252ac`），Windows x64 Release 便携包与安装程序已构建并核验；推送被 403 阻塞；真实平台与完整手工验收未完成
- 面向用户的说明：[MIRROR_DANMAKU_DESIGN_2026_11_17.md](./MIRROR_DANMAKU_DESIGN_2026_11_17.md)
- 源码基线：`master` @ `233a252ac5502477c2eb21ebd80204d577b2e125`；本文档提交后 `HEAD` 会再前进一个 docs 提交
- 应用版本：`3.1.19+4108`（[pubspec.yaml](../pubspec.yaml)）
- Flutter：`3.47.5`（[.fvmrc](../.fvmrc)）

本文是给下一次 AI 对话的独立交接：记录最新需求、实际实现、关键接口、已知缺陷与证据、已执行命令、未执行项、剩余任务和禁止事项。**“已提交”只代表本地 `master` 有提交，“已构建”只代表本机产物生成并核验；都不代表已推送、已发布、已安装或已完成真实平台验收。**

## 1. 最新有效需求

用户希望在 Pure Live 的 A 直播间中，同时显示另一个 B 直播间的弹幕：

- 打开 A 后，从房间右上角应用菜单配置 B 的直播间地址；
- 解析出 B 的弹幕源并连接；
- B 的聊天弹幕同时出现在 A 的视频画面滚动层、侧栏弹幕列表和小窗/悬浮弹幕层；
- 配置按 A 房间持久化，下次打开 A 自动恢复；
- 进入 C 等其他直播间不受影响，不能把 A 的 B 弹幕带到 C。

已确认的首版范围（2026-11-17，仍然有效）：

- **一个 A 配一个 B**：不做多 B 列表，也不做多会话管理。
- **入口在右上角应用菜单**：新增“同步弹幕”，不单独加设置齿轮，不加侧栏状态卡。
- **B 消息不加前缀**：不修改 `LiveMessage`，不加来源字段；侧栏、画面和小窗无法从文本区分 A/B。
- **包含小窗/悬浮层**：B 消息必须进入 `sendFloatingDanmaku`，B 会话跟随 A 的悬浮保留与最终释放。

用户原话回答：`1 1个 / 2 A / 3B / 4A`。

### 已被覆盖的旧要求/旧假设

- “必须做成运行时插件”不成立：项目没有运行时插件/UI 扩展点，Flutter AOT 不能动态加载任意 Dart UI/业务代码；实际落地为源码级自包含模块 + 少量接入点。
- 旧文档的“功能尚未实现、只做文档”检查点已被本轮实现覆盖。当前不要按“还没有代码”重新规划；也**不要回滚**已经存在的实现。
- 旧设计写“每次转发前调用 `DanmakuEmoteLoader.ensureRegistered`”；实现改为**不把 B 的表情注册进全局 `EmojiAtlas`**。原因是 atlas 只按表情 code 作键，B 覆盖同 code 的 A 平台表情会污染 A 的侧栏、画面和小窗（见 `mirror_danmaku_session.dart:240-245`）。这是有意的取舍，不是漏写。
- 旧接口草案只列了 `applyMirrorChat`；实际实现把“历史/画面/小窗”三出口抽成可测试的 `deliverMirrorChatToRoom`，宿主接口另外包含身份、当前性和悬浮保留判断（见第 3.4 节）。
- “先别操作，先把文档补齐”是上一轮的历史指令；本轮用户要求更新文档，功能实现已经发生，不要据此删代码或把状态改回“未实现”。

## 2. 工作区与仓库基线

- 工作区：`D:\purelive`
- 当前分支：`master`；本地功能提交 `826bc203d`、`233a252ac`；`origin/master` 仍是 `07ee34b9d`
- 两次本地提交：
  - `826bc203d feat(live): 支持同房间同步显示另一间直播的聊天弹幕`
  - `233a252ac build(ffmpeg): 恢复五平台 FFmpeg 9.0.2 原生资产地址`
- `origin`：`https://github.com/liuchuancong/pure_live.git`（用户 fork）
- `upstream`：`https://github.com/Jackiu1997/pure_live.git`
- 推送：`git push origin master` 返回 **403**（`Permission to liuchuancong/pure_live.git denied to crazylei12`）。没有 force-push，没有改远端，提交保留在本地。
- 跟踪文件在 Release 构建时是干净的（构建记录 `tracked_files_dirty=false`）；未跟踪项只有 `.lcode/backups/mirror_danmaku_partial_2026_11_17_0934/*.bak` 和两份交接文档。`.lcode/` **不是生效源码，也不是交付物**，不要提交或删除。
- `pubspec.yaml` 的 9.0.2 平台地址已作为独立提交 `233a252ac` 纳入；构建脚本按 Windows ZIP 哈希 `e61684a9…` 校验，缺失时干净环境会回退到插件默认 9.0.1。

## 3. 实际实现

### 3.1 数据层

目录：`lib/domains/live/data/mirror_danmaku/`

- `mirror_danmaku_config.dart:8-91`
  - 字段：`platform`、`roomId`、`sourceUrl`、`nick`、`title`、`enabled`、`version`（`currentVersion=1`）。
  - `identityKey` 为 `platform:roomId` 归一化形式；`matchesHost` 用于拒绝 B=A。
  - `fromJson` 在版本不符、平台/房间号为空、非 Map 时返回 `null`；不保存 `danmakuData`/cookie/token。
- `mirror_danmaku_store.dart:16-61`
  - 键：`mirror_danmaku_v1:<host.identityKey>`；`keyFor` 在 `:31`。
  - 读/写/删可注入（`:8-10`），默认走 `HivePrefUtil`。
  - `read` 捕获 JSON 异常并记日志；`write`/`remove` 失败返回 `false`，不清空或假装成功。
- `mirror_danmaku_resolver.dart:48-180`
  - 失败枚举（`:12-21`）：`emptyInput`、`invalidLink`、`unsupportedPlatform`、`sameAsHost`、`detailFailed`、`danmakuUnavailable`、`timeout`、`cancelled`。
  - `resolve`（`:68-112`）：`LiveUrlTool.parseLiveUrl` → 平台/房间归一化 → `Sites.supportsDanmakuTransport` → 拒绝 B=A → `resolveRoom`。
  - `resolveRoom`（`:116-161`）：重新拉详情、再校验身份、未开播返回 `success(canConnect:false)`、检查 `danmakuData` 是否可用（字符串非空或虎牙 `topSid>0`，`:163-168`）。
  - 默认超时 15 秒（`:52`），`CancelToken` 可中断等待（`:170-179`）。

### 3.2 第二弹幕会话

`lib/domains/live/presentation/playback/services/mirror_danmaku_session.dart:61-280`

- 依赖注入：`MirrorDanmakuEngineFactory`（`:12`）和 `MirrorDanmakuFilterPolicyProvider`（`:54`），测试不需要真实网络。
- `MirrorDanmakuFilterPolicy.fromAppState`（`:35-51`）读取 `FavoriteRoomController` 的屏蔽用户/关键词与 `SettingsService.to.danmaku` 的重复/相似度配置。
- `connect`/`disconnect` 通过 `_serialize`（`:268-279`）串行化；epoch 和引擎实例双重校验（`:175-209`），断开后旧回调不生效。
- `supportsRoom`（`:101-108`）要求平台支持、`danmakuData` 非空、虎牙 `topSid>0`。
- 只处理 `LiveMessageType.chat`（`:211-212`）；消息 gate、屏蔽用户、关键词、重复折叠、相似度过滤在 `:213-238`。
- 启动超时 20 秒、停止超时 5 秒（`:69-70`）；启动失败/超时释放引擎并上报 `onTerminalError`（`:128-145`）。
- **表情策略**：不调用 `DanmakuEmoteLoader.ensureRegistered`，不写全局 `EmojiAtlas`（`:240-245`）。B 的 `message.emotes` 原样保留，供侧栏渲染。

### 3.3 房间级控制器与宿主接口

`lib/domains/live/presentation/playback/controllers/mirror_danmaku_controller.dart:65-477`

- 状态：`MirrorDanmakuStatus { idle, disabled, resolving, connecting, connected, offline, failed }`（`:12`）；状态对象保存 `config`、`target`、`status`、`message`（`:14-44`）。
- 构造时创建内部 session，并可选监听全局 `hideDanmaku`（`:66-88`）。
- 公共方法：
  - `attachHost(LiveRoom)`（`:114-146`）：同一宿主幂等；同身份再次调用会刷新房间并 `ensureConnected`；不同宿主先 `detachHost`；无配置清空状态；停用或不可运行则不解析。
  - `detachHost()`（`:150-159`）：递增 epoch、取消解析、清空状态、断开 session。
  - `preview(input)`（`:162-168`）：只解析，不改已保存目标。
  - `saveAndApply(config, {resolved})`（`:172-221`）：先写存储，失败返回 `false` 且不报告已启用；匹配预览时可直接连接；否则重新解析。
  - `disable()`（`:223-248`）、`remove()`（`:250-268`）：写存储成功后递增 epoch、取消解析并断开；写失败保持原状态。
  - `retry()`（`:270-284`）：不写存储；递增 epoch、取消解析、清空失败文本、置 `idle`、断开旧 session，然后重新解析/连接。
  - `ensureConnected()`（`:289-308`）：PiP/前台恢复时调用；可运行时若已连接或正在忙碌则 no-op；不可运行时会使在途连接失效并断开。
  - `dispose()`（`:461-471`）/`onClose()`（`:473-476`）：`onClose` 在宿主保留悬浮资源时不销毁，等 `_disposeAppFloatingResourcesAsync` 最终调用 `dispose`。
- 可运行条件 `_hostEligible`（`:426-435`）：`isLiveNow` 为真、`isRecord != true`、`isCatchUpActive` 为假、非 IPTV/CC、平台支持弹幕；`_canRun`（`:415-418`）再叠加全局弹幕开关和宿主身份/当前性检查。
- 异步隔离：解析、连接、消息回调都检查 `_disposed`、epoch、`_canRun`（`:310-361`）；旧 B 或切房后的晚到结果不能写入 A。
- 系统消息：连接成功（`:363-371`）、终端失败（`:379-384`、`:404-409`）通过 `host.addMirrorSystemMessage` 提示；未开播只在重试/保存路径提示（`:335-338`、`:210-213`），首次 `attachHost` 只显示离线状态。

宿主接口：`lib/domains/live/presentation/playback/controllers/mirror_danmaku_host.dart:7-17`

```dart
abstract interface class MirrorDanmakuHost {
  String get hostIdentity;
  bool get isHostCurrent;
  bool get keepsMirrorDanmakuForFloating;
  void applyMirrorChat(LiveMessage message);
  void addMirrorSystemMessage(String text);
}
```

### 3.4 `LivePlayController` 接入点

均在 `lib/domains/live/presentation/playback/controllers/live_play_controller.dart`：

- `deliverMirrorChatToRoom`：`:69-78`，`@visibleForTesting`；按历史 → 画面（可空）→ 小窗顺序写同一对象。
- 声明 `mirrorDanmakuController`：`:94`；在 `_initControllers` 创建并传入 `SettingsService.to.danmaku.hideDanmaku`：`:278`。
- PiP/前台恢复：`_recoverDanmakuAfterPresentation` 在 A 弹幕恢复后调用 `ensureConnected`：`:250-273`（`:264`）。
- 从悬浮窗恢复：`:340`。
- A 确认在播：`:831`。
- A 不在播：`:858`。
- 未知状态且无播放源：`:902`。
- 切到 IPTV 分支：`:951`。
- `switchRoom` 且不同房间：`:977`。
- 宿主实现：`:1157-1186`
  - `hostIdentity` 优先取当前房间详情的 `identityKey`；
  - `isHostCurrent` 在路由关闭但保留悬浮时为真；
  - `applyMirrorChat` 在 `isClosed` 且保留悬浮时只写小窗；否则同时写侧栏/画面/小窗；
  - `addMirrorSystemMessage` 在非保留悬浮且已关闭时丢弃，否则交给 `addSystemMessage`。
- 小窗最终释放：`_disposeAppFloatingResourcesAsync` 先 `mirrorDanmakuController.dispose()`：`:1257`。
- 路由 `onClose`：`:1297` 调 `mirrorDanmakuController.onClose()`，由宿主保留判断决定是否延后销毁。

### 3.5 菜单与对话框

- `lib/domains/live/presentation/playback/widgets/button/live_play_menu_button.dart`
  - 导入对话框：`:13`；菜单 `case 9`：`:82`。
  - 可用条件 `_canConfigureMirrorDanmaku`：`:172-178`，与控制器 `_hostEligible` 一致；不满足时 Toast `mirror_danmaku_unavailable`。
  - 菜单项：`:228`，使用 `_item(..., enabled: ...)`（`:232-239`），不改现有 0–8 的 value。
- `lib/domains/live/presentation/playback/dialogs/mirror_danmaku_dialog.dart`
  - `MirrorDanmakuEditor` 是公开的 `@visibleForTesting` widget（`:24`）；`MirrorDanmakuDialog.show` 从 `controller.state.value.room.detail` 取宿主房间。
  - `initState` 在 `attachHost` 前用 `MirrorDanmakuController.readSavedConfig(hostRoom)` 读持久化配置，避免默认启用/空 URL 覆盖已停用配置（`:52-60`；控制器入口 `mirror_danmaku_controller.dart:113-115`）。
  - 停用 `_disable()` 只在控制器返回 `disabled == true` 时把开关置为关闭，写盘失败保持开启并提示（`:151-160`）。
  - 预览/保存、删除确认和状态行布局沿用原实现；未解析且 URL 有新输入时拒绝保存（`mirror_danmaku_preview_required`）。

### 3.6 文案

- `assets/translations/zh.json`、`assets/translations/en.json` 各新增 47 个 `mirror_danmaku*` 键；本次校验两边的镜像键集合完全一致。
- 连接成功/失败/未开播系统消息使用 `mirror_danmaku_connected_message`、`mirror_danmaku_connect_failed_message`、`mirror_danmaku_offline_message`。

## 4. 行为与约束（接手时必须保持）

- **按 A 的房间身份持久化**：键包含 A 的 `identityKey`；C 房间没有键，既不读取也不能删除 A 的配置。
- **只镜像聊天**：`LiveMessageType.chat`；礼物、在线人数、Super Chat、通知、撤回不得进入 A 的状态。
- **不改消息文本/用户名/身份字段**：不构造 `[B] ` 前缀，不改 `userName`、`userId`、`messageId`、`color`、`emotes`、`sentAt`；否则“屏蔽该用户”和撤回关联会出错。
- **只写三个出口**：侧栏历史、当前视频控制器、悬浮层；不写 `updateRuntimeAudience`、`superChats`、公告、撤回或 A 的 `DanmakuController` 会话状态。
- **回放/轮播/回看/录制不自动连接**：`_hostEligible` 与菜单使用同一门禁，避免把 B 的直播弹幕注入回放画面，也避免出现用户无法关闭的连接。
- **全局弹幕开关**：关闭时停止 B 并清空目标；重新打开后按条件重连。房间本地的 `hideDanmaku` 不停止 B（只影响画面层），与 A 现有行为一致。
- **悬浮保留**：A 把播放交给应用小窗后，路由关闭不能停止 B；最终释放小窗资源时才 `dispose`。不要在 `onClose` 无条件断开。
- **表情防污染**：不要把 B 的表情注册进全局 `EmojiAtlas`。若将来要解决 B 在视频/小窗的表情显示，必须先设计按来源/房间隔离的键，不能直接回到 `ensureRegistered`。
- **失败提示**：写盘失败不得报告已启用；连接失败/未开播要提示；中断重连不要刷屏（控制器对相同失败文本去重）。

## 5. 已知缺陷、限制与证据

### 5.1 独立审查发现的状态

独立代码审查已执行；**原始审查记录不在当前工作区**（`local-artifacts/` 只有 quality-focused 记录），以下按审查条目核对当前工作区（审查快照的行号与当前文件不完全一致）：

| # | 审查问题（严重度） | 当前状态 | 证据 |
| --- | --- | --- | --- |
| 1 | 镜像会话把 B 表情注册进进程级 `EmojiAtlas`，覆盖 A 同 code 表情（medium，verified） | **当前工作区已包含修复**：会话不再注册 B 表情，并新增 atlas 不变测试 | `mirror_danmaku_session.dart:240-245`；`mirror_danmaku_session_test.dart:120-147` 断言 `EmojiAtlas.instance.find(code)` 为空且消息仍携带 emotes |
| 2 | `danmaku_emote_loader.dart:26` 在并发上限达到时先记 `_handled`，且 `EmojiAtlas.clear()` 后不清空（low，unconfirmed） | **不在本次镜像链路**：镜像会话已不调用该 loader；这是既有共享 loader 的行为，本次未修改，也没有新增证据证明它对镜像有影响 | `mirror_danmaku_session.dart` 无 `ensureRegistered` 调用；`danmaku_emote_loader.dart` 未被本次 diff 触碰 |
| 3 | 自动运行缺少 `isLiveNow`/`isRecord`/`isCatchUpActive` 门禁，回放/轮播仍连接 B 且入口不可用（medium，verified） | **当前工作区已包含修复**：`_hostEligible` 与菜单都检查三种状态，并有回放/轮播/录制测试 | `mirror_danmaku_controller.dart:426-435`；`live_play_menu_button.dart:172-178`；`mirror_danmaku_controller_test.dart:181-199`（A 从直播变回放在 `:201-221`） |
| 4 | 对话框在 `attachHost` 读配置前初始化开关/URL，之后不回填；保存可能覆盖已停用配置或迫使用户重输 URL（low，unconfirmed） | **已修复** | `MirrorDanmakuEditor.initState` 用 `readSavedConfig` 先读持久化配置（`mirror_danmaku_dialog.dart:52-60`、`mirror_danmaku_controller.dart:113-115`）；回归 `mirror_danmaku_dialog_test.dart:103` |
| 5 | 停用写盘失败时对话框仍把开关置为关闭，用户会理解为已停用，但存储和 B 会话仍启用（low，unconfirmed） | **已修复** | `_disable()` 仅在 `disabled == true` 时置 `_enabled = false`，失败保持开启并提示（`mirror_danmaku_dialog.dart:151-160`）；回归 `mirror_danmaku_dialog_test.dart:123` |
| 6 | 路由关闭、仅剩应用小窗时镜像系统消息被丢弃（low，unconfirmed） | **已修复**：新增 `deliverMirrorSystemMessage` 按 `isClosed`/保留小窗路由 | `live_play_controller.dart:94-105`、`:1206-1214`；回归 `mirror_danmaku_forwarding_test.dart:46`；`FakeMirrorDanmakuHost` 仍不经过真实 `isClosed` UI 路径 |
| 7 | 新增测试未覆盖多个失败分支（low，unconfirmed） | **关键用例已补**：对话框初始化、停用写失败、系统消息路由已有测试；仍无菜单 widget 测试和真实路由关闭 UI 测试 | `mirror_danmaku_dialog_test.dart:103`、`:123`；`mirror_danmaku_forwarding_test.dart:46`、`:63`、`:79`；fakes 仍不模拟真实 `isClosed` |

第 1、3、4、5、6 条相对审查快照已修复，**没有经过审查者复审**；本表只是对当前代码和测试的核对。

### 5.2 仓库基线架构违规（不是本次引入）

- `python tool/validate_architecture.py --strict`（本轮在 `D:\purelive` 复跑）：

  ```text
  domains/recorder -> domains/live/domain/global_player_service.dart   [domains/recorder/presentation/pages/local_player/local_video_player_controller.dart]

  hard violations: 1 unapproved + 21 approved   stale ledger entries: 0   soft advisories: 120
  EXIT:1
  ```

- 源文件：`lib/domains/recorder/presentation/pages/local_player/local_video_player_controller.dart:15` 导入 `package:pure_live/domains/live/domain/global_player_service.dart`，命中 `tool/validate_architecture.py:149-150` 的跨域硬规则。
- 该文件不在本次改动中：`git status --porcelain` 不含它；`git diff --stat HEAD -- <该文件>` 无输出；`git show HEAD:<该文件> | sed -n '15p'` 仍是同一 import。
- 引入提交：`f1dd6cfb4`（2026-10-07 11:59:20 +0800，`fix(recorder): 进入录像播放先暂停直播间…`），已是 HEAD 祖先（`git merge-base --is-ancestor` 返回 0）。
- ledger（`tool/validate_architecture.py:44-66`）没有这条边；ledger 最近更新 `e1475e9aa`（2026-10-03，`ledger 38 -> 21`）早于引入提交。
- 结论：**本次提交的功能改动没有引入新的硬违规**；`--strict` 的唯一未批准项属于已提交、已推送的仓库基线。不要把这条违规写成本次修复成果，也不要为了变绿把它加入 `BASELINE`（需要单独的架构决策/修复）。
- 与本次修改文件相关的既有已批准违规只有一条：`domains/live -> domains/recorder/presentation/pages/recorder/recorder_controller.dart [domains/live/presentation/playback/controllers/live_play_controller.dart]`（ledger 在 `tool/validate_architecture.py:61`；导入在 `live_play_controller.dart:19`，本次未改该行）。
- 新增代码的软提示：`--soft` 过滤本次文件共 13 条，其中 10 条为新增同域 `presentation -> data`（`mirror_danmaku_controller.dart` 4、`mirror_danmaku_dialog.dart` 3、`mirror_danmaku_session.dart` 2、`live_play_menu_button.dart` 1）；另外 3 条是 `live_play_controller.dart` 既有的 data 导入。软提示不会让 `--strict` 失败（`tool/validate_architecture.py:156-167`、`:207`）。
- 扫描根只有 `lib`（`tool/validate_architecture.py:40`）；`test/`、翻译和 `pubspec.yaml` 不在门禁范围。
- **CI 说明**：`AGENTS.md:16-17` 声称 `.github/workflows/architecture.yml` 在 CI 执行该检查，但当前工作区 `.github/workflows` 只有 `build_pure_live_release.yml` 和 `update_releases.yml`；`grep -rn validate_architecture .github` 无结果。本环境无法验证 CI 门禁；这与本次功能无关，也不能据此断定基线违规长期未被拦截。

### 5.3 其他已确认限制

- B 的网络表情不在全局 atlas：侧栏可用 `message.emotes`（`danmaku_list_view.dart:596-598`），视频/小窗只查 atlas（`player_danmaku_surface.dart:92`、`compact_danmaku_overlay.dart:135`），因此 B 表情在画面/小窗可能显示为文字代码。这是避免覆盖 A 表情的取舍，真实效果未验收。
- B 未开播只保存、不连接、不轮询；需要手动重试。
- 礼物/SC/观众数/公告/撤回不转发；撤回的消息可能留在历史。
- 屏蔽用户/关键词是全局设置，屏蔽 B 的用户会影响 A/C。
- A/B 若为同一主播多平台推流，可能出现重复内容。
- Windows 多实例不实时同步同一 A 的配置。
- 全屏弹幕设置面板没有镜像入口；只在房间应用菜单。
- Windows Release 安装程序由本机 Inno Setup 生成且未签名；本轮没有执行安装/卸载验收。
- 当前 Windows 版本仍为 `3.1.19+4108`；本轮安装包不是新版本发布，不改变 `assets/version.json` 或 GitHub Release。

## 6. 已执行命令与结果

### 6.1 功能实现、提交与质量门

- 本地提交：`826bc203d`（功能）、`233a252ac`（FFmpeg 地址）。
- 全量质量门（源码 `233a252ac`）：`.\tool\local_ci.ps1 -Scope Focused -TestPath test -Analyze -SkipPubGet`，记录 `local-artifacts/build-records/20261117T144813778Z-quality-focused.json`：`status=succeeded`、284/284 测试通过、Analyze `No issues found`、`format_mode=apply` 且 0 个文件被改动、`source_changed_during_run=false`、`duration_seconds=168.997`。
- `Full` 门禁的前置检查因既有缺失文件 `.github/workflows/audit-upstream.yml` 失败（`tool/validate_build_policy.ps1`；文件在 `4a0cf09fe` 被删除，`docs/ISSUE_927_PORTRAIT_LIVE_LAYOUT_AUDIT_2026_11_01.md` 记录过同一基线问题）。因此没有声称 `local_ci -Scope Full` 通过。
- 独立代码审查的历史发现及当前状态见第 5.1 节；原始审查记录不在工作区。

### 6.2 本轮交付核验

- `git status --porcelain=v1 -uall`、`git log --oneline -3`：确认两次本地提交和未跟踪项；Release 构建记录 `tracked_files_dirty=false`，`source_commit=233a252ac`。
- `python tool/validate_architecture.py --strict`：`EXIT:1`，唯一未批准项仍是 `domains/recorder -> domains/live` 基线违规（见 5.2）。
- 构建：`.\tool\build_local_release.ps1 -Target WindowsX64 -Configuration Release -SkipQuality`，记录 `20261117T145437322Z-build-windowsx64-release.json`：`status=succeeded`、`duration_seconds=327.536`、`active_heavy_processes_after=0`。
- 产物哈希（重算与 `WINDOWS_SHA256SUMS.txt` 一致）：
  - `PureLive-3.1.19-4108-windows-x64-setup.exe`：63,000,207 字节，SHA-256 `744e5ec78214b4fcc2609a31dffcea1fdde3d98fb72bdb466e810dcb48ee4366`
  - `PureLive-3.1.19-4108-windows-x64-portable.zip`：80,950,621 字节，SHA-256 `b2304afa2a3f353800f3842c806926408141ad5becf7c239fd345b8d3dac432d`
- 便携包（1351 项）核对：`pure_live.exe`、`msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll`、`WebView2Loader.dll`、`libffmpegkit.dll` 均存在；无 `data\flutter_assets\kernel_blob.bin`，无 `.pdb/.ilk/.lib/.exp`；`zh.json` 有 47 个 `mirror_danmaku*` 键。
- `pure_live.exe` 版本 `3.1.19+4108`；`libffmpegkit.dll` SHA-256 `302d978048f389dbb07f01c1a34a4988a92d1e3ebf0e960e2dd8314f83632b34`（固定 9.0.2）。
- 安装程序：Inno Setup 6.7.3（用户目录 `%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`）生成，ProductVersion `3.1.19`、ProductName “纯粹直播”，`Get-AuthenticodeSignature` 为 `NotSigned`。

### 6.3 未执行

- `tool/local_ci.ps1 -Scope Full`（被既有缺失策略文件阻塞）。
- 安装程序的实际安装/卸载、Release 运行时手工验收。
- 真实 B 平台连接、登录/cookie、短链、限流、地区限制验证。
- 侧栏/画面/小窗的镜像收发、PiP 与小窗悬浮完整手工验收。
- Android 构建、ADB、设备 UI、日志抓取。
- 推送（403）、发布、上游合并。
- 用户已自行试用 Windows 构建并反馈正常；该结论来自用户，不是本轮独立复现。

## 7. 剩余任务与建议顺序

1. **推送本地提交**：当前账号 `crazylei12` 对 `liuchuancong/pure_live` 无写权限；换有权限的账号后 `git push origin master`，不要 force-push。
2. **安装包运行时验收**：安装 `PureLive-3.1.19-4108-windows-x64-setup.exe`，验证菜单、对话框、侧栏/画面/小窗镜像和 PiP；当前安装程序未签名。
3. **真实 B 平台验收**：至少两个平台（例如 B 站 + 斗鱼/虎牙）、普通链接与短链、未开播、断线、A 切房、全局弹幕开关、屏蔽用户/关键词、表情。
4. **小窗/悬浮与 PiP 验收**：A 进入小窗后 B 继续、关闭小窗后 B 停止、路由关闭顺序、系统消息可见性。
5. **补测试（可选）**：菜单 widget 测试、真实 `isClosed` 路由关闭路径；如要保证表情显示，再加视频/小窗表情的针对性测试（当前策略是不注册 B 表情）。
6. **架构门禁**：基线违规是独立问题，不能塞进本次功能提交；如要让 `--strict` 变绿，需单独修复 recorder 的跨域导入或走明确的 ledger 变更评审。
7. **发布/上游**：功能稳定且验收通过后，按 [UPSTREAM_REVIEW_POLICY.md](../UPSTREAM_REVIEW_POLICY.md) 整理独立 PR；本轮不做。

## 8. 操作权限与禁止事项

- 本轮已完成源码提交、全量测试、Windows Release 构建和两份文档更新；不要按“只允许改文档”的旧限制回滚或拒绝后续验收。后续修改仍需用户明确授权，并按第 7 节顺序执行。
- 后续获授权的开发轮次默认只做源码、测试和本地构建；手机发现、ADB、安装、日志、设备 UI 需要当前明确的设备请求；历史设备连接不构成持续授权。
- 不运行重型构建/并发构建；按 [BUILD_POLICY.md](../BUILD_POLICY.md) 一次一项重型任务/一个平台变体。
- 不使用 `--force` 推送；不删除无关分支或产物；保留未发布工作。当前 `crazylei12` 无 `liuchuancong/pure_live` 写权限，换账号后再推送，不要绕过 403。
- 本轮安装程序未签名；不要描述成已签名或已发布的正式版本。安装/卸载属于用户侧操作，除非用户明确要求，不要擅自改动其已安装应用。
- 不把签名、密钥、cookie、token 写入仓库或文档。
- 不在没有授权的情况下做上游合并；只读比较和本地修复不等于上游合并。
- 不修改 A 的 `DanmakuController` 单会话语义，不把 B 塞进 A 的 `_liveDanmaku`。
- 不引入 `data -> presentation` 或跨 domain 依赖；不要为了通过检查把新耦合加入架构 baseline。
- 不擅自把首版扩大为多个 B、B 的礼物/Super Chat、B 的账号切换或 core 消息模型改造。
- 不自行添加 `[B] ` 前缀，不给 `LiveMessage` 加来源字段；首版已确认无来源标记。
- 不把已确认的小窗/悬浮层做成“可选后补”；不要移除 `keepsMirrorDanmakuForFloating` 的延后销毁逻辑。
- 不把 B 的表情直接注册进全局 `EmojiAtlas`；如要修，先解决同 code 覆盖问题。
- 不把单元测试通过当成真实平台验收；不把 Focused 通过当成仓库级全绿；不把“已实现”写成“已发布”。
- 不把 `.lcode/backups/*.bak` 当作源码；不要回滚当前工作区实现到旧的“仅文档”状态。

## 9. 工作流状态与不可擅自恢复的限制

- 当前是**功能已本地提交 + Windows Release 产物已生成**的检查点，不是已推送、已发布或已完成验收。
- 本地提交：`826bc203d`、`233a252ac`，外加本文档的 docs 提交；`origin/master` 未前进。
- 已完成：全量 284/284 测试 + Analyze；Windows Release 构建、便携包/安装程序生成和内容/哈希核验；用户手工试用了 Windows 构建。
- 未完成：推送（403）、安装程序安装验收、真实 B 平台与完整 UI 验收、Android 构建、发布。
- 架构 `--strict` 当前为红，原因是基线违规；不要把它误报成“本次改动失败”，也不要在本轮顺手修 recorder。
- 如果下一次接手时 `HEAD` 已前进，先重新确认第 3 节的文件/行号和 `git status`，再继续；不要把本文件的行号当成永久事实。
- 上一轮的“先别操作、只补文档”限制已被实现覆盖；除用户新的明确限制外，不要据此阻止后续修复或验收。

## 10. 相关文档

- [面向用户的工作结果说明](./MIRROR_DANMAKU_DESIGN_2026_11_17.md)
- [AI 与维护工作流](./AGENT_WORKFLOW.md)
- [构建策略](../BUILD_POLICY.md)
- [上游审查策略](../UPSTREAM_REVIEW_POLICY.md)
- [维护策略](../MAINTENANCE_POLICY.md)
- [架构校验脚本](../tool/validate_architecture.py)
- [Android 设备测试轮换](./ANDROID_DEVICE_TEST_ROTATION.md)
