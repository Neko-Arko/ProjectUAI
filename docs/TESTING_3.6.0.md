# Project UAI 3.6.0 验证

编制于 2026 年 10 月 19 日。本次发布处理一个已复现的 Android 中继请求解析失败，简化配套应用界面，并更新桌面端 OpenCode 发现、浏览器响应与公共网站。客户端、桥接、Windows 桌面端与 Android 配套应用使用版本 3.6.0；Android version code 为 5。

源代码、文档、测试与构建输入在相应构建与聚焦验证之前均经人工审阅。生成的输出经检查，修复在重测之前经审阅。完整的原生套件未运行。

## 配套应用错误：已复现的内容

所报告的消息包含 `Relay rejected the request (400): invalid executor request`，其后为 `Inference was not resubmitted. (599)`。当外层 `/api/executor` JSON 信封无法解码或其 schema 无效时，中继会发出内层的 400。此事发生在令牌校验与提供方分派之前；它与坏令牌拒绝不同。

一项 JVM 对比使用了上一个已发布版本的服务器源代码（仅重命名，以便与当前实现并排运行），配合真实本地 HTTP 套接字与本地模拟提供方。它确立了如下序列：

1. 普通配对与一次带认证的状态请求以状态 200 成功。服务器记录到活跃的客户端联系。
2. 一个有效的大型执行器信封，包含嵌套 JSON、引号、反斜杠、换行与 Unicode，以 `Content-Encoding: gzip` 发送。
3. 旧服务器返回执行器状态 400 与精确响应体 `{"error":"invalid executor request"}`。未接受任何作业，模拟提供方未收到任何请求。
4. 同一未压缩信封返回状态 202。恰好一个本地模拟提供方请求到达，其正文被精确保留。

这复现了所报告错误的一个具体成因，以及“已连接、发送时却失败”的表观序列。旧服务器将压缩字节当作文本解码。它**不**证明用户的 Delta 构建压缩了失败请求：当时没有来自该手机的抓包，且执行器 `HttpPost` 签名各不相同。未在“每个执行器都以相同方式实现”的假设下，向客户端添加任何未文档化的压缩参数。

当前的[请求体读取器](../companion/app/src/main/kotlin/dev/projectuai/relay/server/RequestBody.kt)接受明文与 gzip 正文，并在 JSON 解析之前对接收字节与展开字节加以限界。[服务器回归测试](../companion/app/src/test/kotlin/dev/projectuai/relay/server/RelayServerTest.kt)验证大型嵌套 JSON、保留配对、同 ID 处理、直接与执行器路由、畸形压缩、不支持的编码与尺寸拒绝（且不发生提供方分派）。认证、来源限制、取消，以及既有的“不重提交不确定推理”规则仍受覆盖。

基线为额外一项通过的测试，独立于当前的 20 项配套应用测试。它是服务器源代码对比，而非 Android 上的新旧 APK 对比。本地证据：[基线结果](../refer/release-3.6.0/relay-baseline/baseline-result.xml)与[基线夹具](../refer/release-3.6.0/relay-baseline/source/dev/projectuai/relay/server/LegacyRelayCompressionTest.kt)。这些证据文件被忽略且不随发布提供；参见下文的证据说明。

## 聚焦验证

| 检查 | 结果与范围 |
| --- | --- |
| 配套应用发现 | 50 个用例 / 207 项断言通过 |
| 移动端中继 | 28 项检查通过 |
| 移动端截止期限 | 15 个用例 / 54 项断言通过 |
| 原生静态审计 | 217 个文件；零失败与警告；非完整原生套件 |
| 桌面端桥接发现 | 40 项检查通过 |
| 桥接安装器 | 70 项检查通过 |
| 运行时变更日志与模态框 | 2 个聚焦场景 / 435 项检查通过，包括宽/窄视口与已读标记 |
| 客户端构建与编译器 | 最终原生捆绑包新鲜度通过；变更的 Lua 源代码以官方 Luau 编译器编译 |
| 配套应用 JVM 服务器与呈现 | 20 项测试通过：15 项服务器测试与 5 项状态呈现测试；零失败、错误或跳过 |
| 先前服务器 gzip 对比 | 1 项测试通过；在分派前复现了精确的旧错误，并配有未压缩对照 |
| Android 发布打包器 | 10 项测试通过；最终签名 APK 新鲜度检查通过 |
| OpenCode 发现与原生适配器 | 17 项测试通过；1 项仅限 Unix 的测试在 Windows 上跳过 |
| 桥接更新器与桌面 Node 测试 | 21 项测试通过；零失败或跳过 |
| 最终浏览器响应/UI 验证 | 在最终取消布局修复后，3 个聚焦 Chromium 套件通过；桌面端与窄屏截图经检查 |
| 最终 Windows 可执行文件 | 36 项自检、5 项打包冒烟检查与 5 项原生窗口检查通过；正常/紧凑预览经检查 |
| 公共网站 | 8,447 项静态检查通过；全部聚焦 Chromium 检查在 320、390、768 与 1440px 下通过；截图经检查 |

配套应用结果记录在本地[服务器 XML](../refer/release-3.6.0/relay-baseline/current-results/TEST-dev.projectuai.relay.server.RelayServerTest.xml)、[呈现 XML](../refer/release-3.6.0/relay-baseline/current-results/TEST-dev.projectuai.relay.ui.RelayPresentationTest.xml)与 [Gradle 日志](../companion/.cache/tests-3.6.0.log)中。最新的更新器/桌面 Node 运行记录位于 [bridge-release-tests-3.6.0-final.log](../companion/.cache/bridge-release-tests-3.6.0-final.log)。

呈现测试区分活动监听者与已认证的 Roblox 联系，在不过度声称监听者已停止的情况下使过期联系失效，并避免待处理的 Android 安装显示为可接受新消息。它们不演练 Android 输入、服务生命周期或渲染。

## 桥接响应呈现

最终的 `browser-response-layout.js`、`browser-tool-cards.js` 与 `browser-visual-rework.js` 套件针对已审阅的桥接源代码通过。它们演练分组答案与可选活动、格式化后的实时与已保存推理、精确的 Copy 操作、保留的选中内容、七个中继/提供方错误分类用例、原始诊断披露、草稿保留，以及在审阅失败消息时零命令/推理 POST。真实本地 SSE 中断与 HTTP 取消验证终止状态且不发生重放。

压力覆盖超过 450 条嵌套条目，并验证有界保留、聚焦控件与清理。桌面端与 320/390px 布局、强制颜色、减少动效与延迟用户排序均受覆盖。最终的取消布局会在撰写框上方保留完整错误卡片，便于跟随响应的读者查看。先前的 `browser.js` 集成套件亦通过，含 320 条消息历史；它早于最终的推理/错误迭代。

本地[验证说明](../refer/release-3.6.0/browser/verification.txt)与[最终截图](../refer/release-3.6.0/browser/reasoning-errors-final/)指明了确切的检查与已审阅图像。桥接包新鲜度通过。这些 Chromium 夹具不确立 Roblox 原生渲染或执行器输入。

## 公共网站

重新设计的页面采用白色单色调色板、投影 3D Canvas 主视觉与动画 SVG 图示。渲染器将绘制上限设为 30 FPS，设备像素比上限设为 1–1.5，并在离屏或文档隐藏时挂起动画。动效可暂停；减少动效设置以下次加载时的暂停状态启动。无 Canvas 时仍保留静态 SVG 可用。录制的工作流具有原生控件，且页面加载时不自动播放。

在源代码审阅之后，`node tools/build_site.js` 生成了发布镜像。生成的 HTML、样式、脚本、版本与完整的 174 个工具/21 个分组目录均经检查。根目录与 `docs/` 副本逐字节一致。`python test/site_static.py` 通过 8,447 项结构、链接、对比度与目录检查。聚焦的 `node test/site_browser.js` 门禁通过了响应式几何、导航与焦点、精确的加载器复制与剪贴板被拒回退、目录搜索/类别/风险筛选、披露/重置行为、示例标签页、官方下载目标、动效暂停/恢复与离屏挂起。Canvas 失败与禁用 JavaScript 的场景保留了可用内容与导航。

桌面端与窄屏截图经检查。一项仅测试的搜索预期被更正：搜索 "raycast" 会正确地同时找到匹配的工具名与另一项描述中包含该词的。该夹具在重跑之前经审阅；无需产品变更。浏览器门禁检查发布链接目标，但不下载二进制文件。

本地[验证说明](../refer/release-3.6.0/site-verification/verification.txt)与[桌面端预览](../refer/release-3.6.0/website/monochrome-review/desktop-hero.png)记录了最终设计与检查。其他桌面端/移动端预览位于该图像旁。整页截图可能将粘性导航置于其捕获的滚动位置；视口截图亦经审阅。

## Windows 桌面端包

独立的 3.6.0 可执行文件在最终的浏览器与客户端变更日志改动之后重建。全部 30 个内嵌桥接/客户端/许可文件与其清单一致；内嵌桥接源代码、Web 资产与原生客户端捆绑包与已审阅的发布输入一致。FileVersion 为 `3.6.0.0`。

`desktop/verify.ps1` 仅将可执行文件复制到隔离目录。其 36 项自检、5 项打包生命周期冒烟检查与 5 项原生窗口检查通过，且无相邻的运行时或桥接目录。正常与紧凑的原生启动器预览经检查。这些检查包括原生发现、集成开关、最小化/还原/关闭行为、分阶段更新保留与所属桥接关闭。它们使用模拟的游戏连接。

本地证据位于[验证日志](../companion/.cache/desktop-verify-3.6.0-final.log)与 `desktop/.build/verification/`。最终包不捆绑 Node.js 或 OpenCode；Node 会被检测或下载，OpenCode 使用既有安装。

## 配套应用构建与视觉审阅

在最终的大字号调整之后，发布装配与关键发布 lint 通过。包检查确认 `dev.projectuai.relay`、版本 3.6.0/code 5、最低 API 26、目标 API 36，且无调试标记。`apksigner` 验证了既有的生产签名者，其公共证书 SHA-256 为：

`ad7d215b8ad67ce70ae2ce89ad3ea959b68202b5c38e72141a68f7d54331f4b5`

最终的 `node tools/build_companion.js --apk companion/app/build/outputs/apk/release/app-release.apk --check` 通过。构建证据位于本地[最终装配日志](../companion/.cache/assemble-3.6.0-final.log)。

界面现在将连接状态与单一的 Start/Stop 操作置于最前，提供三个简短的设置步骤，并保持连接设置与诊断折叠。更新安装与恢复操作在需要时仍然可见。从 Android 设置返回时，电池权限状态会刷新。

清晰标注的 Chromium 模拟稿在 360 x 800 与 360 x 640（150% 文字）下经审阅。其颜色、标签、间距与排版尺寸遵循 Compose 源代码。审阅发现文字放大时三列消息总计过于拥挤；Compose 卡片现在在字体缩放为 1.2 或更大时堆叠这些总计。修订后的模拟稿经检查，全部五个场景均保持在其 360 像素内容宽度内。这些检查仅评估设计与密度；Android 文本测量、系统内边距、控件与无障碍输入可能不同。

本地视觉证据及其局限位于[模拟稿 README](../companion/.cache/companion-preview/README.md)，包括[正常文本](../companion/.cache/companion-preview/companion-mock-360x800-connected-text1-full.png)与[放大文本](../companion/.cache/companion-preview/companion-mock-360x640-connected-text1.5-full.png)。这些并非运行中 APK 的截图。

## OpenCode 实机发现

一次只读探测发现了已安装的原生 OpenCode CLI 版本 2.0.32，启动其所属本地 API，并以十个免费模型 ID 达到就绪状态。探测随后关闭其所属进程，未留下任何私有临时目录。它发出**零**次提供方推理请求。这验证的是已安装二进制的发现与模型列表 API，而非模型回复或手机兼容性。本地证据：[聚焦测试](../refer/release-3.6.0/opencode/focused-tests-serial.log)与[实机结果](../refer/release-3.6.0/opencode/live-result.json)。

## 产物标识

当前原生客户端捆绑包为构建 `3.6.0-c1be873b5ea20949`，含 221 个模块。Android 包保留 protocol 2 与生产签名密钥。

| 产物 | 字节 | SHA-256 |
| --- | ---: | --- |
| `dist/uai.lua` | 3,416,928 | `057092fc13a7b830849f7b22a6e1d0243cbd3ade569c91ced46cf29f3ab79d15` |
| `UAI-Relay-3.6.0.apk` | 9,655,526 | `687575277cbe346c0eb5c0adcd11e39431e1386c26a1d8caebce239f5060448e` |
| `uai-bridge-package.json` | 1,234,850 | `3c28c08b17e3ce49aca315206cf3ebf6bd0d8f9bbe9408af41e9232d9e0bcc10` |
| `UAI-Bridge-3.6.0-win-x64.exe` | 53,968,710 | `a2728f4f1c1e7dc1d77e424b31014de455496e09a6c3d60b22db3a516649f32e` |

配套应用发布清单与相邻的 APK 校验文件与上述 APK 标识一致。这些是本地产物结果；它们不确立远程发布或既有 Android 客户端的成功安装。

## 原生设备限制与证据可获取性

未连接任何实体 Android 设备。模拟器 37.2.12 在 Android 启动前失败：其崩溃报告器记录了 Windows 异常 `0x80000003`，软件模拟尝试以 `0xC0000005`（访问冲突）退出。另下载了较早的官方模拟器 33.1.24，并对照 Google 公布的 SHA-256 验证。其默认 CPU 与保守的 qemu64 配置也均在启动前以 `0xC0000005` 退出；默认 CPU 记录了不受支持的 TCG AVX/F16C 特性。AMD A8-7600 主机在固件中启用了虚拟化，但缺少 Android Emulator 虚拟机监控程序驱动。未更改任何驱动或宿主设置。

没有可用的 adb 设备。本次对比未安装旧版或新版 APK。Android 原生渲染、Start/Stop 与设置输入、安装/恢复行为、后台存活，以及更新后的 Delta 推理路径均未在手机上验证。用户先前成功的 OpenCode 手机变通方案仍是记录在 HttpPost 更正说明（已归档）中的历史结果；它不是对 3.6.0 APK 的测试。未连接任何 Roblox Studio 实例用于原生客户端检查。

`companion/.cache/` 与 `refer/release-3.6.0/` 下的路径是本地、被忽略的验证证据。指向它们的链接在发布工作区中有效，但这些日志、夹具与模拟图像不提交，也不随发布提供。已提交的测试源代码与产物标识记录了可复现的范围。全新检出必须重跑相应检查，而不能将缺失的被忽略文件视为已发布证据。
