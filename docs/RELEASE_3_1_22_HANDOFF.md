# Pure Live 3.1.22 技术交接

2026-11-23。对应 [工作结果说明](RELEASE_3_1_22_RESULT.md)。工作区 `D:\purelive`；分支 `release/3.1.22`；版本 `3.1.22+4111`。

## 1. 最终结果与源码基线

已完成源码修改、4 项定向测试、Analyze、314 项完整应用测试、Android 正式签名包及 Windows 安装/便携包构建，并发布 [v3.1.22](https://github.com/crazylei12/pure_live/releases/tag/v3.1.22)，设为 latest、非 draft、非 prerelease。

构建源码及远端标签：`f1b6cdc907b736b6821c78828c9e887f6f1f15f5`，标题 `feat(release): disable automatic updates and unify Android Windows 3.1.22`。已 push 到 `fork/release/3.1.22` 并 ls-remote 核验。后续交付文档/发布历史索引同步提交不重打已发布包、不移动标签。

仓库：`fork=https://github.com/crazylei12/pure_live.git`；`origin` 仍为 `liuchuancong/pure_live`。只向 fork 推送/发布，不改远端、不强推、不误传 origin。GitHub CLI 当前账号 `crazylei12`，对 fork 为 ADMIN。

## 2. 最新需求与覆盖关系

用户明确要求取消 Android / Windows 自动更新检查，手动入口指向我们仓库最新 Release，统一双平台版本，构建正式版上传 Release。本次授权覆盖旧交接中「无发布授权」与 Windows 维持旧版本的限制。此前功能由用户确认可用，本轮不重新调查 Kick 播放卡顿。

没有设备/UI 授权，不做 ADB、设备发现、安装、模拟器或 Windows GUI 操作，不关闭既有应用，不改用户数据。未启用动态工作流或子代理，全部重型阶段串行。

## 3. 已改文件与关键接口

- `lib/features/home/home_page.dart`：删除启动更新延时/网络调用/弹窗及相关测试注入，保留本地 `VersionUtil.initPackageInfo()`。
- `lib/features/settings/pages/general_settings_page.dart`：移除自动检查开关。
- `lib/core/config/app_settings_controller.dart`：旧字段保留兼容导入导出，默认及缺省导入 false；即使旧值 true 也没有启动更新调用点。
- `lib/features/about/about_page.dart`：手动入口 `_openLatestRelease()`，外部浏览器，重复点击保护和失败提示。
- `lib/core/release/version_util.dart`：新增 `latestReleaseUrl`；旧版本页/下载代码保留，关于页不再进入版本检查页。
- `.env/.env.dev/.env.prod` 与生成的 `lib/gen/env.g.dart`：update owner=crazylei12；native bundle owner 仍为 wzgrx，不替换原生依赖。
- 版本同步：`pubspec.yaml`、`assets/version.json` 顶层/Android/Windows、MSIX 配置、现存手动构建工作流 tag、README、Release Notes、Windows installer publisher URL。其他平台元数据未抬升。
- `test/features/update_policy_test.dart`：2 个源码策略断言 + Android/Windows 两个 Widget 链接测试。内存 Hive、SettingsService、GetMaterialApp；字体测试子类仅覆盖 ensureInitialized；mock url_launcher 不启动真实浏览器；结束时恢复平台 override。
- 发布后同步 `assets/releases.json` 新条目，仅前置本次 fork Release，保留历史来源；该索引同步不是对已发布包重新构建的声明。

## 4. 本轮命令与证据

1. Git status/remotes；gh auth/account/repo 权限检查；Git 工具 `fetch fork --tags`；确认 v3.1.22 不存在后创建 release 分支。
2. 资源守卫内 `tool/flutterw.ps1 dart run enven --env-files '.env,.env.prod' --class-name AppConfig`。PowerShell 逗号串必须加引号，初次未加引号失败后修正生成成功。
3. `tool/local_ci.ps1 -Scope Focused -TestPath test/features/update_policy_test.dart -Analyze`：4/4 通过，Analyze `No issues found!`（12.5 秒）；记录 `local-artifacts/build-records/20261123T093015084Z-quality-focused.json`。早期红灯/harness 错误保留日志，不算应用回归；已修正。
4. `tool/local_ci.ps1 -Scope Full`：失败，缺失 audit-upstream 工作流；记录 `20261123T093040625Z-quality-full.json`。未降级/更改门禁。
5. 资源守卫内 `tool/flutterw.ps1 test --no-pub --concurrency=12`：**314/314 通过**；记录 `20261123T093218585Z-release-3.1.22-full-flutter-tests.json`，源码=f1b6cdc，峰值 CPU 12.19%、内存约 1.32 GiB。
6. 测试后资源守卫内 `build apk --release --config-only --split-per-abi --target-platform android-arm64 --build-name=3.1.22 --build-number=4111`，确认 GeneratedPluginRegistrant 无 IntegrationTestPlugin，再运行 `tool/build_local_release.ps1 -Target AndroidArm64 -Configuration Release -SkipQuality -RequireReleaseSigning`。
7. Android 首次构建约 304 秒，已有文档改动令 metadata dirty=true；临时保存无关文档后同源码增量构建 49 秒，最终 metadata dirty=false。最终记录 `20261123T094310208Z-build-androidarm64-release.json`，峰值 CPU 77.17%、内存约 2.46 GiB。
8. `tool/build_local_release.ps1 -Target WindowsX64 -Configuration Release -SkipQuality`：224.6 秒，记录 `20261123T094157721Z-build-windowsx64-release.json`，metadata dirty=false，峰值 CPU 16.69%、内存约 2.20 GiB。
9. `apksigner verify --verbose --print-certs`：v2=true，证书符合下述 SHA；APK 内容与 ELF/ZIP 16 KB 校验由构建脚本通过。Windows mt.exe 提取清单、版本资源、运行库和便携 ZIP 检查通过；两端 checksum 文件逐项验证通过。
10. `gh release create v3.1.22 <7 files> --repo crazylei12/pure_live --target f1b6cdc907b736b6821c78828c9e887f6f1f15f5 --latest --notes-file ...`：成功。GitHub API 再核对 latest、非 draft/prerelease、tag SHA、7 附件 state/size/digest 均符合。远端 tag 与 release branch 构建时一致。

可复用本地临时脚本：`.lcode/release-3.1.22-full-tests.ps1`、`release-3.1.22-android.ps1`、`release-3.1.22-artifact-verify.ps1`、`verify-release-3.1.22.py`；日志位于本会话 LCode exec 目录及 local-artifacts/build-records。临时脚本不纳入 Git，不能假定换机存在。

## 5. 产物与签名

产物根目录 `D:\purelive\local-artifacts\3.1.22-4111`；共 3 个程序包 + 4 个校验/元数据文件，均上传 Release。

- APK：139037221 字节，SHA256 `9f648bcc5c6033d3e7584b9c1e678db935ff823120f4070438791f05bbc3ffe6`。
- Windows setup：63035124 字节，SHA256 `3aad580ca1c3968f78926adfc9a8b2239f28825cbf1dbb39c1db984ee9ba46c2`。
- Windows ZIP：81003354 字节，SHA256 `ffda987a0c435f0618d1e905abd67543fb5e552432d5d57a0614d27c952ee29c`。
- Android versionName=3.1.22，base code=4111，Manifest code=6111（ABI offset 2000），minSdk=26，ABI arm64-v8a，18 个原生库 LOAD >= 0x4000。
- 沿用本机 `android/key.properties` 既有正式密钥，证书 SHA256 `35bc29c164a8eb97b775b1c77d9ee485a358a3446ccc4d5b25e8d041d0803280`。不读取/记录密码、不轮换密钥、不回退 debug 签名。
- Windows 显示 FileVersion/ProductVersion=3.1.22+4111，数字版本=3.1.22.4111；installer ProductVersion=3.1.22；未做 Authenticode 签名。

## 6. 已知未解决项与不可扩大范围

- Full 包装器：`tool/validate_build_policy.ps1:48` 缺失 `.github/workflows/audit-upstream.yml`；后续还含旧插件路径、旧 owner/已删除工作流引用。不要为发布重建整个旧自动化链。
- 严格架构：`lib/domains/recorder/presentation/pages/local_player/local_video_player_controller.dart:15` 导入 live 的 GlobalPlayerService。该文件上次修改 `87c17c94369fbe4fd0a7592a04c379ab3f79da54`，本轮与起点 diff 为空，属既有未解决问题。
- `test_release_workflow_data.py` 最初因 Bash 探测跳过；显式 BASH_EXE 后失败于已删除 feature-build.yml。应用测试通过不能掩盖这些失败。
- Android 构建仍有 Firebase KGP、Cupertino font 警告，本次成功，未升级依赖。无新的性能/设备/UI 验收。
- 用户已有两份 Kick 诊断文档改动保留。为产生准确干净元数据，临时 stash `c11e49a3e504c8a54aa7b00d12f69a30893bd55a`，构建后已 apply 恢复；该 stash 暂留为额外备份，勿自动 pop/drop 未确认归属的 stash。`.lcode/` 与 `.lcodeignore` 仍是本地未跟踪内容。

本轮目标已完成，无后续构建/部署承诺。若用户要求设备验收再按设备轮转规范执行；若单独要求治理历史门禁，再建立独立变更，不挪动已发布标签、不覆盖资产。
