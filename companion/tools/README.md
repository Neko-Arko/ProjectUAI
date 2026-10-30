# 在手机上测量伴生端

这些选择性加入的控制台探针用于把执行器/伴生端故障与模型
可用性问题区分开来。它们不使用任何提供方账号或 API 密钥，也不测试 OpenCode。
请在已启动 UAI Relay 的目标 Android 手机上运行它们。桌面或模拟运行
只能证明该执行宿主；请在任何报告中一并记录手机、Android 版本和
执行器版本。

`loopback_probe.lua` 会检查 `uai-relay` 标记、配对响应和
已认证状态。它从不打印配对令牌或原始响应体。此处的 PASS
**并不**表示推理转发可用。

## Delta 传输诊断

如果探测在请求别名上全部以 `executor threw` 耗尽，请在 Delta 的编辑器中单独
运行 `transport_probe.lua` 并读取 Delta 的控制台。
它会打印一个有界的、经过清洗的原生异常，而不是 UAI 的通用类别。
它只使用公开 GET：通过 `request` 和 `HttpGet` 在
`127.0.0.1` 与 `localhost` 上访问伴生端 hello，然后使用 `request` 通过 HTTPS 访问
这份公开 README。配对、推理、已保存设置、响应体和响应头都不会进入
报告。脚本在五秒等待超时后停止；某个原生调用可能
仍在运行，且该次运行不会再派发任何调用。

[Delta 脚本指南](https://docs.deltaexploits.gg/scripts) 指向 SUNC
了解函数行为，并指向 Delta 的控制台以排查问题。链接的
[SUNC 请求参考](https://docs.sunc.su/Miscellaneous/request/) 记录了
此处使用的 `{ Url, Method }` 格式。这两个页面都不能确立
某个特定 Delta 构建上 Android 回环 HTTP 可用。

在同一台手机的浏览器中打开 `http://127.0.0.1:8790/api/hello` 作为独立的
监听器检查。浏览器成功而原生失败可隔离出执行器路径。
仅公开 HTTPS 成功并不能证明本地 HTTP 支持。`HttpGet` hello 成功仅是
诊断证据：中继仍需要经过认证的
POST、GET 和 DELETE 支持，而仅靠 `HttpGet` 无法提供这些。

## 长回复测量

在同一 Wi-Fi 网络上的计算机上，使用该计算机实际的 LAN 地址，
用 Node.js 18+ 启动受控的延迟提供方：

```powershell
node companion/tools/delay_fixture.js --host 192.168.1.10
```

该 fixture 会等待 45 秒后才返回一个 nonce。它只提供 `/probe`
和 `/health`，不转发任何内容，拒绝 Authorization 头，并在内存中存储
有界的诊断计数器。其默认绑定是回环。显式的
LAN 绑定会让这个临时 fixture 可被该网络上的其他设备访问；
测量完成后用 Ctrl+C 停止它。手机必须能够访问该地址，
且计算机的防火墙必须允许所选端口（默认 8791）。

有两种备选方案可以让 fixture 保持在回环上：

- 在手机的 Termux 中运行同一个 Node 脚本，并使用
  `http://127.0.0.1:8791/probe`。
- 对于通过 USB 连接的开发手机，在计算机上以
  默认绑定运行 fixture，并运行 `adb reverse tcp:8791 tcp:8791`；在手机上使用同一个
  回环 URL。之后用
  `adb reverse --remove tcp:8791` 移除该映射。

在移动执行器中，把这段配置前置到
`relay_probe.lua` 的内容之前，然后一起执行它们：

```lua
UAI_RELAY_PROBE = { url = "http://192.168.1.10:8791/probe", port = 8790 }
-- Paste the contents of relay_probe.lua below this line.
```

该脚本使用生产路由 `/api/hello`、`/api/pair`、`/api/status` 和
`/api/inference`。它会提交一个任务，重放一次完全相同的任务 ID 以
检查幂等性，然后每秒轮询该 ID 一次。PASS 要求至少 35 秒后得到匹配的
nonce、恰好一次上游派发、每次执行器
交换最多五秒，以及第二个任务确认取消。
这是有意测试单个任务的重放，而不是第二次推理。

最终 JSON 报告包含通过/失败、总耗时、最慢的执行器
调用、轮询/错误计数、超时协商以及结果/取消检查。
配对令牌、完整 URL、请求体和提供方凭据都被排除。
伴生端的 Requests 卡片在运行期间应显示接受和活动。

执行器请求函数是同步的：探针无法强制
中断一个忽略 `Timeout` 的原生调用。它会在该调用返回时记录其实际
耗时。总观察预算默认为 100
秒，之后探针会取消其自身的待处理任务；对于以 `--seconds`（35–120）启动的
fixture，可覆盖 `waitSeconds`（60–300）。
失败或完成永远不会导致新的任务 ID 替换首次请求。

常见报告类别：

| 类别 | 观察到的内容 |
| --- | --- |
| `companion_not_found` | 没有兼容的回环 hello；请检查 Start、端口和执行器回环支持。 |
| `pairing_not_confirmed` / `authentication_not_confirmed` | 探测有效，但已认证约定未能成立。 |
| `long_job_terminal_before_response` | 应用接受了工作，但它在 fixture 回复之前就结束了；请检查应用的安全错误类别和 fixture 可达性。 |
| `observation_budget_expired` | 原始任务未在测量预算内完成；它已被取消。 |
| `executor_call_exceeded_five_seconds` | 在此执行器上，某个回环调用本身阻塞过久。 |
| `upstream_dispatched_more_than_once` | 复用同一中继 ID 导致 fixture 收到重复请求。 |

首次运行时请让 Roblox 保持在前台。之后在切换应用或
锁屏状态下运行会增加该设备后台行为的证据；一次运行
并不能证明在所有 Android 厂商或执行器上都能存活。原生 OpenCode
可用性必须单独验证。

## 无需手机的测试框架验证

在人工审查任何改动之后，从仓库根目录运行：

```powershell
node --test companion/tools/delay_fixture.test.js
luajit companion/tools/probe_contract_test.lua
```

Node 测试套件会发起真实的本地 HTTP 调用，包括一次 35 秒的延迟回复。
Lua 测试套件使用模拟时间和脚本化的中继来检查诊断
能否正确报告失败、只保留一个任务 ID 且从不打印凭据。
这两个套件都不能作为某个特定移动执行器可以访问该应用的证据。
