# Pure Live 3.1.22 技术交接

对应用户结果：[RELEASE_3_1_22_RESULT.md](RELEASE_3_1_22_RESULT.md)。工作区 `D:\purelive`；起点 `58b44b861`；分支 `release/3.1.22`；版本 `3.1.22+4111`。

## 最新需求与覆盖关系

2026-11-23 用户明确要求关闭 Android / Windows 自动检查更新，手动检查指向我们仓库最新 Release，统一 Windows/Android 版本，构建最新正式包并上传 Release。这覆盖历史文档中「尚无发布授权」及 Windows 保持旧版本的限制。此前功能由用户确认可用，本轮不重新调查 Kick 播放卡顿。

远端：`fork=https://github.com/crazylei12/pure_live.git`；`origin` 仍是 `liuchuancong/pure_live`，不得把本次包传到 origin。GitHub CLI 当前有效账号 `crazylei12`，对 fork 为 ADMIN。不改变全局账号、不改远端映射、不强推。

## 已改接口与实现

- `lib/features/home/home_page.dart` 删除启动更新延时/请求/对话框及仅用于该任务的测试注入，保留本地 `VersionUtil.initPackageInfo()`。
- `lib/features/settings/pages/general_settings_page.dart` 删除自动检查开关。
- `lib/core/config/app_settings_controller.dart` 保留旧字段兼容，默认/缺省导入 false；即使旧值 true 也无调用点恢复启动检查。
- `lib/features/about/about_page.dart` 手动入口 `_openLatestRelease()`，外部浏览器、并发点击保护、打开失败提示。
- `lib/core/release/version_util.dart` 新增 `latestReleaseUrl`；旧版本页/下载功能保留，主入口不再进入版本检查页。
- `.env*` 和 `lib/gen/env.g.dart` 更新源 owner 改为 crazylei12，native bundle owner 仍为 wzgrx，不替换原生依赖。
- 版本同步：pubspec、version.json 的顶层/Android/Windows、MSIX、现存手动构建工作流默认 tag、README、Release Notes、Windows installer publisher URL。
- `test/features/update_policy_test.dart`：2 个源码策略断言 + Android/Windows 两个 Widget 链接测试。字体设置使用无初始化副作用的测试子类，内存 Hive，mock url_launcher method channel，不启动真实浏览器。

## 现存无关工作与构建边界

启动时已有未提交的 `docs/KICK_WINDOWS_RESTORE_2026_11_18.md` 和 `docs/KICK_WINDOWS_RESTORE_HANDOFF_2026_11_18.md`；不得覆盖或混入提交。`.lcode/`、`.lcodeignore` 本地内容同样保留。因此构建元数据若标记工作树 dirty，必须明确实际仅为这些无关文档，不可伪造干净状态。

历史 Full 问题：`tool/validate_build_policy.ps1` 要求已删除的 audit-upstream/feature-build/sign-staged 等工作流、旧插件 AAR 路径，且硬编码旧发布 owner；`sync_owner_refs.ps1` 还试图重写历史 releases.json 链接。不得为了通过恢复历史工作流或盲改历史归属。优先记录失败后以资源守卫执行实际 analyze 和完整 Flutter tests，但不能说 Full 包装器通过。

Android Release 使用既有 `android/key.properties` 指向的本机正式 keystore，密钥/密码不得读出或入 Git。历史证书 SHA-256：`35bc29c164a8eb97b775b1c77d9ee485a358a3446ccc4d5b25e8d041d0803280`。构建必须 `-RequireReleaseSigning`。测试后先 `build apk --release --config-only --split-per-abi --target-platform android-arm64 --build-name=3.1.22 --build-number=4111` 恢复 Release 插件注册表，确保无 IntegrationTestPlugin，再构建；Manifest code 预期 `6111`（基础 4111 + arm64 偏移 2000）。

## 命令与当前进度

- 已执行 Git status/remotes、gh auth/account/repo 权限检查，fork fetch --tags；v3.1.22 尚不存在，fork/master 与起点一致。
- 配置生成命令：`tool/flutterw.ps1 dart run enven --env-files '.env,.env.prod' --class-name AppConfig`，在资源锁内运行。PowerShell 必须给逗号串加引号；首次未加引号失败，修正后生成成功。
- 红灯验证证明原首页有启动检查和设置开关。Widget harness 先后补齐 GetMaterialApp、SettingsService、内存 Hive 和字体设置；这不是应用回归。
- `-SkipPubGet` 因未提交的 pubspec 版本变动被严格门禁拒绝，后续不再使用此参数直到版本提交。
- 定向测试 4/4 通过，Analyze `No issues found!`（12.5 秒），记录 `local-artifacts/build-records/20261123T093015084Z-quality-focused.json`。
- Release workflow data 测试 2 项跳过（本机该 Python 测试未解析出 Bash）；不算通过。
- 完整测试、构建/发布结果待完成后更新。

## 权限与未执行项

当前授权：本轮源码提交/推送到 fork，Android/Windows 本机构建与 GitHub Release 发布。没有设备/UI 请求，不做 ADB、安装、GUI 启动或进程关闭。不覆盖旧 Release/旧包、不轮换密钥、不改其他平台版本、不恢复 Kick 卡顿调查。无动态工作流或子代理；各重型阶段串行并走 build_resource_guard。
