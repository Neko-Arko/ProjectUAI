# UAI Relay（Android 伴生端）

版本 **3.7.0**（Android version code 7）。

**Settings > Kilo tunnel** 启用自动匿名 Kilo 配额恢复。原生 Tor 仅在出现明确的
配额拒绝之后才启动，如果首个出口受限则重试一次线路。停止中继即可更改该开关。
Roblox 中的 Cowork 和伴生端都会显示其状态。共享出口保留各自的配额；这并不保证
无限访问。参见 [设置与证据](../docs/KILO_TUNNEL.md)。

这是一个前台服务，在 Project UAI 客户端通过短回环调用提交和轮询期间，保持上游
提供方连接。客户端把每次交换的预算限制在最多五秒。某些移动执行器会在推理轮次
完成之前切断较长的 `request()` 调用；轮询让伴生端能够保持该提供方连接打开，
直到答案就绪。它**不是** Cowork 桥接：没有 Web UI，没有静态文件服务，没有智能体
状态，也没有命令。只有
[docs/MOBILE_COMPANION.md](../docs/MOBILE_COMPANION.md) 第 4 节中的中继约定。

## 环境要求

- Android 8.0+（`minSdk 26`）。仅限侧载；不依赖 Play。
- 一个可暴露 `request` / `http_request` / `syn.request` /
  `http.request` / `fluxus.request` 的移动执行器。普通的 `HttpService` 无法访问
  回环的明文 HTTP；执行器必须在手机上本地执行请求。
- 客户端的 `relay.mode` 默认为 `auto`：脚本会探测
  `127.0.0.1:8790`，配对一次以获得稳定令牌，此后经由中继传输。
  **Always** 模式要求必须使用中继，会报告伴生端不可用，而不是
  直接打开提供方请求。Auto 模式保留其直接回退。

## 构建

需要 JDK 17 和 Android SDK platform **37.1**。已检入的 Gradle wrapper 通过 SHA-256
校验 Gradle 9.6.0；Android Gradle plugin 9.4.1 提供 Kotlin 2.2.10。Tor Android
0.4.9.14 需要较新的 compile API。应用仍支持 Android 8+（`minSdk 26`），并保留
`targetSdk 36`。

```powershell
# From companion/
./gradlew :app:assembleDebug          # APK at app/build/outputs/apk/debug/
./gradlew :app:testDebugUnitTest      # JVM contract tests, no device
```

如果未设置 `ANDROID_HOME`，`local.properties` 必须指向 SDK：

```properties
sdk.dir=C\:\\Android\\Sdk
```

使用 `adb install -r app/build/outputs/apk/debug/app-debug.apk` 安装。

有关生产签名、自动更新和发布打包，请遵循
[Android 伴生端更新](UPDATES.md)。应用会在启动时以及其进程存活期间每 15 分钟
检查官方发布，默认下载兼容的更新，并且只有在点击 **Install update** 之后才请求
Android 执行安装。首次从调试签名 APK 过渡到生产签名密钥需要卸载调试应用并重新
配对；后续更新会保持同一个生产签名者。

## 使用

1. 启动应用并点击 **Start relay**。通知出现，中继只在 `127.0.0.1:8790` 上监听。
2. 在 Roblox 中运行 Project UAI 脚本。Cowork 面板的 Relay 卡片在配对完成后会显示
   伴生端 —— 无需复制令牌。
3. 保持 Roblox 和中继运行。应用中的 **Stop relay** 是权威操作：在你再次启动之前，
   看门狗保持关闭。

如果 Roblox 无法找到伴生端，请先确认应用状态显示
**Relay on this phone: Running**，并且两者显示相同的端口。仅打开应用并不会启动其
服务器。在同一台手机上，用浏览器打开 `http://127.0.0.1:8790/api/hello`
（如果端口被修改过，请替换端口）。包含 `"server":"uai-relay"`
和 `"protocol":2` 的 JSON 回复可确认本地监听器已响应。该公开端点
不包含配对令牌或提供方凭据，也不计入已配对的 Roblox 连接。

如果浏览器访问成功但 Roblox 探测失败，请重新加载当前的 Project UAI 客户端并使用
**Scan now**。中继详情会报告执行器连接情况、HTTP 或协议失败。浏览器成功并不能
证明执行器能够访问回环：某些执行器会远程路由请求，或阻止本地明文 HTTP。
重置配对并不能修复无法访问的 `/api/hello` 端点。如果浏览器也无法连接，请检查
伴生端的端口和诊断信息，并使用 Stop/Start 重启其监听器。

客户端在探测期间还会检查执行器请求的兼容性。如果某个 Delta 构建在本地 `request`
上失败但允许 `HttpGet`，伴生端 3.5.7 支持经过认证的 `HttpPost` 传输。请同时更新
APK 和客户端。它使用 POST 请求体来承载凭据、提交、轮询和取消；不会把任何提供方
内容或令牌添加到 URL。手机上的 HttpPost 支持也必须可用。

在原生请求探测期间，如果已完成的原生调用抛出异常，公开的 hello 探测可以尝试
最小请求选项和不同的请求别名。只有经过认证的伴生端才会为后续本地调用选定一个
可用配置。配对和提供方工作不会被重放来测试这些备选方案。诊断信息会列出尝试过的
别名和选项形式。这有助于把选项被拒绝与监听器不可达区分开来；但它本身并不能
确立某台手机上的 Delta 或 OpenCode 支持。稍后的一份 Delta 报告
（2026 年 10 月 18 日）确认了通过 UAI Relay 应用进行 OpenCode 推理；移动端
OpenCode 需要来自 Discord 的 UAI Relay 应用。
[标准请求 API](https://docs.sunc.io/Miscellaneous/request/) 记录了可选的 Headers，
但未记录 Timeout。

版本 3.6.0 把连接状态和 Start/Stop 放在最前面。设置步骤说明了在 Roblox 中要
做什么。**Your messages** 显示活动工作和已收到的回复；展开最近的消息可查看详情。
连接设置和诊断信息初始处于折叠状态。应用更新进度、安装和恢复操作在需要时保持
可见。

如果配对成功但某条消息返回 `invalid executor request`，说明外层
HttpPost 消息无法解码；这发生在提供方调度和令牌校验之前。3.6.0 接受 gzip 请求体，
包括分块上传和省略 Content-Encoding 的包装器。更早的应用会把这些压缩字节当作
JSON 解析并拒绝它们。请更新应用并重新加载脚本；重置配对不能修复请求编码问题。
压缩和展开的请求都限制在 8 MiB。所报告的 Delta 设备的确切传输字节仍未被观察到。

版本 3.6.5 还把发送给执行器的完整 UTF-8 回复上限设为 8 MiB，
包括 JSON 转义和额外的 `/api/executor` 信封。它会在分配该展开回复之前计算
保留请求体的编码大小。过大的回复会返回 HTTP 413，或在执行器信封内返回状态 413，
并带有固定的 `response_limit` 类别。客户端会停止轮询该任务，而不会重新提交推理；
重置配对不能修复回复大小被拒绝的问题。

更新后的客户端会在仅触摸宿主上串行化普通的原生 HTTP 交换，在 Lua 超时、Stop 或
客户端重载之后仍保留某个仍在运行的原生调用的所有权。取消操作有单独的有界通道。
仅触摸宿主上的展开思考在 Markdown 格式化和原生测量之前使用 8 KiB 的展示摘录；
过大的 RichText 会回退为纯文本。原始提供方推理仍保留在模型上下文和持久化中。
这些改动减少了可避免的原生工作；它们并不归因于或确立对已报告的 Roblox 原生崩溃
的修复。参见 [该调查](../docs/INVESTIGATION_MOBILE_CRASHES.md)。

Roblox 状态报告的是当前服务运行中的实际配对或已认证客户端联系。仅保存了令牌会被
显示为已保存配对，而不是实时连接。Requests 显示已接受的任务、活动工作、已收到的
回复、失败和取消。如果 Accepted 一直为零，说明推理尚未到达应用。最近任务只显示
提供方主机名、耗时、接收字节数和一个安全的结果类别；提供方密钥和消息内容永不
出现。

更新后的客户端会协商 `capabilities.inference = {schema:1, unlimited:true}`，
并对没有显式有限预算的请求发送 `timeout:0`。伴生端不会因为模型沉默或推理耗时超过
十秒而停止这些请求。Stop、显式的请求截止时间、上游失败或现有的回复大小限制仍会
结束工作。较旧的客户端保留其正超时值，被省略的超时仍为 180 秒。连接建立有
15 秒限制；已建立的请求读写没有隐藏超时。中继在连接失败或重定向之后不会自动
重放 POST。

每个正在运行的任务还需要其等待中的 Roblox 客户端保持联系。一次匹配的提交重试或
对该任务的已认证轮询会续订一个两分钟的所有权租约。该服务每五秒检查一次租约，
取消被废弃的提供方连接，并在没有任务剩余时释放唤醒锁。这与总推理时间无关：
定期轮询可以让任务无限期存活。Hello、status 和其他任务不能续订它。客户端丢失会
产生终态的 `client_disconnected`；重新连接永远不会自动重复该推理。

## 存活说明

- 该服务使用 `foregroundServiceType="specialUse"`；Android 15 把 `dataSync`
  服务上限设为每天六小时，这会终止长会话。
- 一个精确闹钟看门狗和 `BOOT_COMPLETED` 会重启该服务，除非用户按下了 Stop。
  **Force stop** 在未重新打开应用的情况下无法恢复。
- 请授予电池优化豁免，并在小米/三星/Oppo/vivo 的厂商设置中允许自启动。
  Diagnostics 屏幕会记录每次重启。

## 安全

- 仅绑定回环（`127.0.0.1`），从不绑定 `allowLan`。
- 64 位十六进制令牌、常量时间比较、仅生成一次并存储在
  `EncryptedSharedPreferences` 中；`allowBackup=false`。
- `/api/pair` 会校验 Host 并拒绝浏览器 Origin；该 API 从不输出 CORS 头，
  也从不提供文件服务。
- 提供方密钥只以内存方式在任务中传输，永远不会被记录或持久化。
  原始网络异常消息会被排除在诊断信息和客户端错误之外。

## 验证

如需在真实手机上做选择性测量，请使用
[控制台诊断工具](tools/README.md)。它们会在不需要任何提供方 API 密钥的情况下
检查配对、通过短执行器轮询获得受控的 45 秒回复、幂等性和取消。
其结果并不能确立 OpenCode 访问权限。

`app/src/test` 在 JVM 上运行，使用真实的 CIO 服务器和一个 `MockWebServer`
上游：头部过滤、URL 安全性、指纹幂等性、实例偏差、容量 503、取消、墓碑、
协商的无限制请求、显式截止时间、超过十秒的延迟回复、无自动重放、实时活动，
以及 pair/auth/hello 约定。Android 清单、包安装器和服务行为需要真实设备或
模拟器。实际执行器支持需要一台运行目标 Roblox 执行器和伴生端的手机；JVM 测试
和没有该执行器的模拟器无法确立这一点。

在某个执行器上信任伴生端之前，请运行 `docs/MOBILE_COMPANION.md` 第 9.4 节中的
Phase 0 测量：确认回环可达性并找到确切的阻碍点。不会切断长调用的执行器不需要
这个应用。
