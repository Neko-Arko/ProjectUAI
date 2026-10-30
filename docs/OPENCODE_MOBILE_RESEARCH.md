# OpenCode 移动端调查

调查日期：2026 年 10 月 18 日。本文记录了一项手机变通方案的证据；
它并不认证 Android 伴生端或原生手机执行器。

## 后续用户报告 —— 2026 年 10 月 18 日

在本次调查之后，用户确认：在手动重试一次初始错误之后，OpenCode 在一台 Delta
Android 手机上通过 UAI Relay 正常工作：

> Relay rejected the request (400): invalid executor request Inference was not
> resubmitted. (599).

该重试产生了推理。移动端 OpenCode 现在需要来自 Discord 的 UAI Relay 应用
（https://discord.gg/9xYyyYuKap）。在该报告发布时，最初的 400 尚未解决；
一次成功的重试确认的是推理，而不是手机工具执行、
工具结果重放或后台存活。下面的调查证据是在该报告之前收集的。

**2026 年 10 月 19 日 / 3.6.0 跟进：** 一次精确的修复前服务器复现
成功认证了明文状态（200），随后以
`{"error":"invalid executor request"}`（400）拒绝了有效的 gzip JSON，此时尚未接受任务或派发
上游。同样的明文 JSON 针对本地 mock 上游则成功（202）。
伴生端 3.6.0 增加了有界 gzip 解码，同时保留认证和任务
标识；参见 [3.6.0 验证记录](TESTING_3.6.0.md)。失败手机的
传输线编码未被捕获，因此这证明了服务器压缩缺陷，但并未
确立该手机故障的原因。它没有提供关于
设备端推理或渲染的新验证。

当前证据**并不**确立 OpenCode 免费模型会一概
排除 Android。存在可行的传输和运行时候选方案，但无论是
模型列表还是能够启动的 CLI 都不能证明推理可用。决定性的
检查是通过实际的 Android
HTTP 栈进行文本、工具调用和工具结果重放，随后经由伴生端和手机执行器。

## 已观察到的情况

| 检查 | 结果 | 确立了什么 |
| --- | --- | --- |
| 10 月 18 日从 Windows Node 向 `big-pickle` 发起请求，带有标识性的 Project UAI User-Agent | HTTP 403 | 该请求身份在所测试的连接上被拒绝。 |
| 使用现有桌面兼容身份和工具声明进行同样的基线测试 | HTTP 200、`PONG`、约 1.8 秒 | 现有请求形态从 Windows 仍然可用。这不是 Android 证据。 |
| Windows Java 17、真实 OkHttp 4.12.0、`big-pickle` 文本/工具/重放 | 三次 HTTP 200 响应；精确的 `PONG`、经过校验的 `uai_probe` 参数、精确的 `NEBULA_42` 重放 | OkHttp 在 Windows JVM 上使用伴生端的连接设置能够承载被接受的请求形态。这并未测试 Android TLS。 |
| 官方 npm 元数据 | `@opencode/cli` 及其 Linux ARM64 musl 包都报告 `2.0.32` | 存在当前官方的 ARM64 Linux 二进制文件。 |
| 使用 OkHttp 的 Android 模拟器 | 未执行：宿主模拟器在 Android 启动之前就失败了 | 实际 Android 上的提供方接受情况仍未验证。 |

包含真实工具/重放检查的历史桌面矩阵位于
[OpenCode 3.2 验证](OPENCODE_3.2_VALIDATION.md)。其 Windows 结果不得
被提升为移动端支持声明。

实机 JVM 探针仅以内存方式使用经授权的次级凭据，通过 stdin 传入
Java 进程。它使用了伴生端的 OkHttp 4.12.0 设置：
15 秒连接建立、无读/写/总调用截止时间、禁用重试和
重定向，以及 `accept-encoding: identity`。这三次请求保留了
相同的会话头和兼容性声明。文本耗时 **3278 ms**，
无害的 fixture 工具请求 **3953 ms**，工具结果重放 **4090 ms**。
未执行任何真实宿主或 Roblox 工具。公开探测首先确认
`big-pickle` 可用。探针源码位于本地且被忽略；未把任何密钥、请求
载荷或原始提供方响应写入报告。

未连接任何物理 Android 设备。在此 Windows 宿主上，模拟器 37 的崩溃
处理程序在 Android 内核启动之前就挂起了 QEMU。模拟器 33 在使用
x86 和 x64 镜像以及软件 CPU/GPU 变体测试时，在启动之前以 Windows 访问
违规 `0xc0000005` 退出。这些宿主故障不能提供关于
伴生端在 Android 上行为的任何证据。JVM 测试和成功的 APK 编译
无法替代 Android TLS、执行器回环访问、后台存活
或原生渲染/输入检查。
[无需凭据的设备中继探针](../companion/tools/README.md) 现在提供了
传输测量：一次至少耗时 35 秒的受控回复、
短执行器调用、恰好一次上游派发以及确认取消。
其三个本地 HTTP fixture 测试通过，包括一次 35.15 秒的延迟，且
模拟的 Lua 探针约定通过了 406 项检查。这些测试框架结果
与真实手机运行是分开的。

剩余的验收要求是一台运行伴生端和移动 Roblox 执行器的真实 Android 手机：
首先收集一份通过的传输报告，
然后通过同一台手机的伴生端验证 OpenCode 文本、无害工具调用和工具结果重放。
在目标设备上确认 Stop 和后台行为。
成功的受控 fixture 本身并不能测试 OpenCode；JVM 上的
OpenCode 响应本身也不能测试手机。本文顶部的带日期 Delta 报告
确认了通过中继的 OpenCode 推理；手机上的工具
调用、工具结果重放和后台存活仍未被观察到。

## 本次调查中发现的伴生端缺陷

源码审查在任何提供方请求之前就发现了一处具体的协议不匹配：
客户端把其余超时序列化为小数秒，而 Kotlin 的
`SubmitRequest.timeout` 是整数。因此，花在前置 hello 上的时间
可能使本来有效的提交在解码时失败。客户端现在会把
有限的线上预算四舍五入为整数秒。

客户端还强制了 300 秒的总等待时间，尽管伴生端拥有
提供方连接。更新后的约定仅在 hello 通告
`capabilities.inference = {schema:1, unlimited:true}` 时协商 `timeout:0`。显式的调用方
预算和旧版伴生端仍保持有限；每次执行器可见的交换都保持
简短。提供方侧的限制仍然适用。

客户端回归套件在 15 个用例中通过了 54 项断言，包括全部四个
超过 300 秒的提供方协议、一次停滞的原生轮询、精确的调用方截止时间、
配对修复、Roblox 发现之后启动以及取消。在重建并检查原生
包之后，现有的中继、生命周期和提供方检查也通过了。这些离线结果解释并验证了
特定的客户端故障模式；
它们并不能确立 Android 上的提供方接受情况或原生执行器兼容性。
参见 [客户端回归用例](../test/mobile_deadlines.lua) 和
[伴生端引擎测试](../companion/app/src/test/kotlin/dev/projectuai/relay/engine/JobEngineTest.kt)。

## 候选路径

| 路径 | 证据 | 仍需证明 |
| --- | --- | --- |
| 现有 Kotlin 伴生端使用 OkHttp 转发被接受的请求形态 | 在 Windows JVM 上使用伴生端连接设置的实机 OkHttp 文本/工具/重放已成功。伴生端拥有长连接并暴露短回环轮询。 | 实际的 Android 文本/工具/重放、执行器回环访问、取消和后台存活。这是首个应当测试的候选方案，因为它不需要 CLI 运行时。 |
| 由 Termux 托管官方 OpenCode v2 musl CLI；伴生端调用其已认证的本地服务器 | 一个社区包装器和上游报告描述了在无需 root 或 proot 的情况下可用的 Android CLI/服务器安装。 | 当前二进制的启动、DNS/TLS、免费推理、工具交接和 Android 进程生命周期。仅凭安装报告是不够的。 |
| 把官方 CLI 和 musl 加载器打包进伴生端 APK | 前台 `serve` 是真实的上游命令；Android 允许打包的原生可执行代码。 | APK 打包、原生依赖、可执行内存限制、DNS、seccomp、内存使用和完整推理。这是一个架构选项，不是已实现的回退方案。 |
| 手机连接到计算机或私有主机上的 OpenCode 服务器 | 上游记录了经过认证的网络服务器和浏览器访问。 | UAI 集成和实际的手机连接。这需要另一台主机，并未解决仅用手机的方案。 |

这些候选方案都不需要公开代理。已退役的 UAI OpenCode 代理
保持退役状态。OpenCode Go 订阅权益与免费
模型调查是分开的。

## 当前官方运行时与 Android 限制

v2 包是 [`@opencode/cli`](https://registry.npmjs.org/@opencode/cli/latest)，
当前为 `2.0.32`。[`@opencode/cli-linux-arm64-musl`](https://registry.npmjs.org/@opencode/cli-linux-arm64-musl/latest)
具有相同版本，解包后约 206 MB，并带有 npm SHA-512 完整性
元数据。旧版 `opencode-ai` 包当前报告 `1.19.3`；更旧的
`@opencode-ai/cli` 命名空间同样不能标识当前稳定的 v2 包。
安装器必须选择正确的命名空间并校验下载的产物。

官方 [postinstall 源码](https://github.com/anomalyco/opencode/blob/dev/packages/cli/script/postinstall.mjs)
仍未在其平台映射中包含 Android。在
[PR #48405](https://github.com/anomalyco/opencode/pull/48405) 中提出的 Android 映射在未
合并的情况下被关闭。Linux musl 和 Android Bionic 是不同的运行时；Linux 包
的存在并不是 Android 预构建。

当前的 [CLI 构建](https://github.com/anomalyco/opencode/blob/dev/packages/cli/script/build.ts)
使用带编译的 `Bun.build`。还存在一个独立的
[Node 构建](https://github.com/anomalyco/opencode/blob/dev/packages/cli/script/build-node.ts)。
一些社区报告称 v2 完全取代了 Bun；当前源码
并不支持把该说法当作通用运行时保证。

[nemoobc/opencode-termux](https://github.com/nemoobc/opencode-termux) 改编了
官方 musl 可执行文件。其当前包装器只修补 `PT_INTERP` 并通过
`LD_LIBRARY_PATH` 提供库：它早先的 RPATH 补丁会在
大型二进制文件上导致崩溃。其 ARM64 musl 加载器会把解析器文件重定向到 Termux 的 prefix。
该包装器的 [上游报告](https://github.com/anomalyco/opencode/issues/50203)
描述了 Android TUI 和后台服务器的成功。这些是社区报告，
不是 Project UAI 的设备测试，也不是对未经审查的安装器脚本的认可。
该包装器当前固定了一个较旧的上游版本，因此安装它并不
等同于测试官方 `2.0.32`。

伴生端的目标是 Android 36。Android 的
[执行限制](https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission)
阻止现代应用从可写的应用存储中执行下载的代码。
内嵌运行时需要打包的原生代码，并采用适当的
[原生库提取](https://developer.android.com/guide/topics/manifest/application-element#extractNativeLibs)，
而不是下载后 chmod 安装到 `filesDir`。上游的
[前台服务器代码](https://github.com/anomalyco/opencode/blob/dev/packages/cli/src/server-process.ts)
可以直接运行；这避免依赖 CLI 的后台服务自我重启
路径。它并不能证明每个原生依赖都能在 APK 内正常工作。

## 免费层拒绝意味着什么、不意味着什么

[Issue #52903](https://github.com/anomalyco/opencode/issues/52903) 报告官方 v2 CLI
在 Android 16、Termux 和 proot Ubuntu 下启动，随后在
免费推理上失败。报告者后来写了 "Fixed"，但未说明方法。
这说明为何启动成功是一个不充分的验收测试。

同样的消息也出现在官方桌面安装上。受控的
[#56334 中的网络对比](https://github.com/anomalyco/opencode/issues/56334)
描述了同一客户端、账号和模型在一条连接上成功，而在原始连接上
再次失败。10 月 18 日
[#56681 中的 WSL2 报告](https://github.com/anomalyco/opencode/issues/56681) 同样
报告在 `2.0.32` 下 Wi-Fi 失败而移动热点成功。这些报告
并未指出服务器的规则，但它们与把该错误文本当作
Android 本身被禁止的证据相矛盾。

[Issue #50627](https://github.com/anomalyco/opencode/issues/50627) 还记录了
在官方客户端内移除工具会触发同样的拒绝。保持
所需声明可见，同时让宿主操作仍需审批，这与现有 UAI CLI 适配器
是一致的。变通方案不能仅仅为了获得模型文本而授予 shell
或文件系统执行权限。

对于远程操作，上游记录了
[服务器认证](https://opencode.ai/docs/server/) 和
[网络浏览器访问](https://opencode.ai/docs/web/)。当前 v2 服务器的
实际 OpenAPI 和认证行为必须被检查：一些文字示例
仍在描述较旧的 API 界面。远程托管的服务器仍是与
仅用手机的伴生端不同的独立选项。
