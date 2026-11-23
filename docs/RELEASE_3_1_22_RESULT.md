# Pure Live 3.1.22 工作结果说明

2026-11-23：**Android 与 Windows 均已统一为 `3.1.22+4111`，完成正式包构建并发布为最新 GitHub Release。**

- [正式 Release / 下载](https://github.com/crazylei12/pure_live/releases/tag/v3.1.22)
- [最新正式版入口](https://github.com/crazylei12/pure_live/releases/latest)
- [技术交接](RELEASE_3_1_22_HANDOFF.md)
- 源码基线、构建提交与 Release 标签：`f1b6cdc907b736b6821c78828c9e887f6f1f15f5`，分支 `release/3.1.22`，已推送到 `fork`（`crazylei12/pure_live`）。后续交付文档/历史索引提交不改变发布标签和安装包。

## 1. 本次变更与提交

源码提交：`f1b6cdc907b736b6821c78828c9e887f6f1f15f5`，标题 `feat(release): disable automatic updates and unify Android Windows 3.1.22`。

- 取消首页启动更新任务、计时器与提示，不再后台请求更新源；旧配置即使为 true 也不生效。
- 移除自动检查更新设置入口，保留旧配置字段用于兼容导入/导出，新配置默认 false。
- 「关于 → 在线更新」直接在外部浏览器打开 `https://github.com/crazylei12/pure_live/releases/latest`。
- `.env`、开发/生产配置和生成配置指向本维护仓库；Android / Windows / MSIX 版本元数据同步。
- 既有播放器、多目标同步弹幕及 Kick 功能保留，不在本轮重新调查范围。

## 2. 已构建并发布的文件

本地目录：`D:\purelive\local-artifacts\3.1.22-4111`。

| 文件 | 大小 | SHA-256 |
| --- | ---: | --- |
| `PureLive-3.1.22-4111-android-arm64-v8a-release.apk` | 139,037,221 字节 | `9f648bcc5c6033d3e7584b9c1e678db935ff823120f4070438791f05bbc3ffe6` |
| `PureLive-3.1.22-4111-windows-x64-setup.exe` | 63,035,124 字节 | `3aad580ca1c3968f78926adfc9a8b2239f28825cbf1dbb39c1db984ee9ba46c2` |
| `PureLive-3.1.22-4111-windows-x64-portable.zip` | 81,003,354 字节 | `ffda987a0c435f0618d1e905abd67543fb5e552432d5d57a0614d27c952ee29c` |

另外发布 `BUILD_METADATA.json`、`SHA256SUMS.txt`、`WINDOWS_BUILD_METADATA.json`、`WINDOWS_SHA256SUMS.txt`，共 7 个附件。已从 GitHub API 核对全部附件为 uploaded，大小、摘要均与本地一致；正式/非预发布/latest 状态和远端标签 SHA 一并核验。

## 3. 本轮验证

- 更新策略定向测试 **4/4 通过**：取消启动任务/开关、Android 和 Windows 布局下手动入口外部链接。
- `flutter analyze`：**No issues found!**（12.5 秒），记录 `20261123T093015084Z-quality-focused.json`。
- 应用完整测试：**314/314 通过**，记录 `20261123T093218585Z-release-3.1.22-full-flutter-tests.json`。
- Android：版本 `3.1.22`，Manifest code `6111`（基础 4111 + arm64 偏移 2000），minSdk 26，单 ABI arm64-v8a，18 个原生库 ELF LOAD >= 16 KB，ZIP 对齐验证通过；APK v2 签名通过，正式证书与上一版一致。
- Android 正式证书 SHA-256：`35bc29c164a8eb97b775b1c77d9ee485a358a3446ccc4d5b25e8d041d0803280`。
- Windows：显示版本 `3.1.22+4111`，数字版本 `3.1.22.4111`；安装程序、便携包、嵌入 Manifest 的 DPI/Windows 10/11 声明、Flutter/MPV/FFmpeg/VC 运行库及无用户数据/Debug blob 检查通过。
- 两端最终 BUILD_METADATA 的源码均为 `f1b6cdc...`，跟踪文件 dirty=false。无关诊断文档改动临时保存后原样恢复，未混入包或提交。

## 4. 未通过的历史门禁与验证边界

- 仓库 Full 包装器 **失败**：`tool/validate_build_policy.ps1:48` 要求已删除的 `.github/workflows/audit-upstream.yml`，记录 `20261123T093040625Z-quality-full.json`。独立完整应用测试通过，不能说全仓 Full 通过。
- 架构严格检查 **失败**：既有 `lib/domains/recorder/presentation/pages/local_player/local_video_player_controller.dart:15` 跨域导入 live 的 GlobalPlayerService；本次未修改该文件。
- 发布工作流数据 Python 测试最初因 Bash 探测跳过；指定 Bash 后 **失败**，原因是测试引用已删除的 `.github/workflows/feature-build.yml`。不恢复旧工作流、不改历史归属来伪造门禁通过。
- Android 构建仍有 Firebase 旧 Kotlin Gradle Plugin / Cupertino font 既有警告，本次构建成功；未在本轮升级依赖。
- **未做新一轮真机、模拟器或 Windows GUI 安装/启动验收，也未做性能或生产环境实战。**
- Windows 无 Authenticode 签名，可能出现未知发布者提示；Android 使用既有正式密钥，不创建或轮换密钥。

## 5. 当前状态与边界

Release 已公开发布并设为 latest；用户安装新包后上述更新策略生效。没有自动替换本机或手机现有应用，没有操作设备、关闭应用进程或修改用户数据。仅发布 Android arm64-v8a 与 Windows x64；其他平台/ABI、MSIX 包不在本次交付范围。原有两份 Kick 诊断文档及 `.lcode` 本地资料保留。
