# 网络与载荷捕获

Project UAI 可以观察脚本发出的 HTTP 调用以及它编译出的代码块，而无需充当代理，也不会改变脚本收到内容。它是用来理解加载器的工具，不是沙箱，也不是替代执行器。

## 工作流程

1. 在运行加载器 **之前** 启动捕获：
   `net_capture { action = "start", mode = "both", duration = 120 }`
2. 在执行器中（或通过 `run_luau`）运行加载器。
3. 用 `net_capture_read` 读取各阶段：
   - `action = "list"` 列出 HTTP 调用、已编译代码块和所需模块。
   - `action = "read"` 读取单条记录的摘要、URL、请求、响应、头部、代码块源码或模块源码。
   - `action = "chain"` 读取 HTTP → 代码块 → 嵌套请求的图。
4. `net_capture { action = "stop" }` 恢复钩子。`clear` 清除记录。

捕获仅在显式调用时启动。它不会在启动时自行安装。

## 观察范围

运行时会安装一组固定的转发包装。智能体无法选择函数，也无法提供包装代码。

| 层 | 目标 |
| --- | --- |
| 执行器 HTTP | `request`、`http_request`、`syn.request`、`http.request`、`fluxus.request`、`krnl.request`、`weare.request` |
| 游戏 HTTP | `game:HttpGet`、`HttpGetAsync`、`HttpPost`、`HttpPostAsync` |
| Roblox HTTP | `HttpService:RequestAsync`、`GetAsync`、`PostAsync` |
| 编译 | `loadstring`、`load`、`getgenv().loadstring`、`getgenv().load`、`debug.loadstring` |
| 模块 | `require`（ModuleScript 与资产 ID） |
| 排队 | `queue_on_teleport` |

包装会调用它所替换的函数，并原样返回其结果。它记录方法、URL、状态、有界请求体与响应体、已脱敏敏感值的头部、耗时、字节数以及内容哈希。错误按原样重新抛出。记录失败会被吞掉；它不会破坏被观察的脚本。

`loadstring` 与 `load` 的记录保留即将编译的源码，包括编译失败的源码。当宿主暴露 `Source` 时，`require` 保留可读的 ModuleScript `Source`；否则记录模块身份以及源码不可用的原因。

## 为什么这比只钩 `loadstring` 的方案捕获更多

- **函数对象，而不只是全局变量。** 若加载器在捕获开始前已缓存 `request` 或 `loadstring`，钩住同一闭包后仍能观察到。
- **两种编译写法。** 除 `loadstring` 外，`load` 以及读取器风格的 `load` 也会被捕获；读取器不会被消耗。
- **模块加载器。** `require` 被转发，而不是替换为空表。
- **不改变行为。** 不做任何伪造或改写：没有白名单响应，没有 `continue` 改写，没有 `{}` 兜底。加载器会走与无捕获时相同的分支。
- **未编译的载荷仍然可见。** 即使没有代码块到达编译器，形似代码的响应体也会被标记为 `suspectedCode`。这正是自定义解释器和提前退出时常见的「它从未拿到载荷」情形。
- **先挂钩再执行。** 先启动捕获；已经运行过的加载器无法被追溯观察。
- **自我排除。** UAI 自身的推理、反编译请求和 `run_luau` 编译会在协程上打标记，永不被记录。标记按线程区分，因此一个挂起的 UAI 请求无法掩盖在别处运行的加载器。

## 关联各阶段

代码块在以下情况下会与 HTTP 记录关联：

1. 代码块源码哈希等于响应体哈希，或
2. 没有哈希匹配，但调用在响应后五秒内于同一协程上运行。

第一种是精确匹配；第二种会明确标注 `link = "thread"`。没有父级的代码块显示为根，或在其父级被逐出时标记为孤立。线程与字节证据不能证明载荷已执行；只有捕获到 `loadstring` 调用才能证明它到达了编译器。

## 限制与脱敏

| 边界 | 值 |
| --- | --- |
| 记录数 | 500 |
| 保留总字节数 | 8 MiB |
| 每条记录的响应体 | 256 KiB |
| 每条记录的请求体 | 64 KiB |
| 代码块源码 | 2 MiB |
| 捕获的代码块数 | 32 |
| 默认捕获时长 | 120 秒（最大 300；`persistent` 需显式指定） |

最旧的记录先被逐出。读取使用字节偏移与续读游标。敏感头部值（`Authorization`、`Cookie`、`x-api-key` 等）会替换为 `<redacted>`；敏感查询值（`token`、`api_key`、`secret`、`signature`、`password` 等）会在存储的 URL 中脱敏。请求体与响应体除有界预览外不会自动脱敏；请将捕获的正文视为敏感内容。

导出使用 `uai-net-capture` JSON 封装以及经验证的工作区写入路径。超过 2 MiB 单文件限制的捕获必须先用 `record_ids` 收窄或先清除。在没有文件系统的情况下导出会失败，但不会停止捕获。

## 已知缺口

- **服务端代码。** 服务端 `Script` 永远不会到达客户端。只有远程调用和客户端侧调用可被观察。
- **从不跨越已挂钩边界的载荷。** 自定义字节码虚拟机若执行自己的指令流而不经过 `loadstring`、`load`、`require` 或可读模块，可能永远不会产生代码块。响应体仍会被存储，并在看起来像代码时被标记，但不会被反虚拟化。
- **WebSocket 流量。** 此版本不捕获。
- **加密或压缩的正文。** 传输包装存储它收到的字节。加载器内部的解密只有在结果到达 `loadstring` 时才可见。
- **钩子检测与隔离。** 若执行器给加载器一份私有的 `request` 副本，或加载器检查函数身份，可能绕过包装。没有反篡改绕过手段。
- **证据不等于执行。** `chain` 依据哈希和线程显示可能的父子关系；它不证明某个分支确实运行过。

## 工具参考

### `net_capture`（`write`）

`action = start | stop | status | clear | export`

- `start`：`mode`（`http`、`chunks`、`both`）、`host`（最多 16 个精确/子域过滤器）、`method`（最多 8 个）、`duration`（1–300，默认 120）、`persistent`。
- `stop` / `status`：生命周期与覆盖范围。无法恢复的钩子报告为 `retained`；它只转发而不记录。
- `clear`：丢弃记录；活动的捕获继续运行。
- `export`：`record_ids`（最多 100）与 `destination`。

### `net_capture_read`（`read`）

`action = list | read | chain`

- `list`：过滤条件 `kind`、`host`、`method`、`url`、`status`、`suspected`、`after_sequence`、`session_id`；页大小 1–20。
- `read`：`record_id` 与 `section`（`summary`、`url`、`request`、`response`、`headers`、`chunk`、`module`），配合 `offset` 和 `bytes`。
- `chain`：保留的父子图，上限 120 个节点、深度 8。

`net_capture_result_read` 用于分页读取保留下来的大型列表结果。

## 验证

`test/net_capture.lua` 覆盖转发、脱敏、自我排除、哈希与线程关联、编译失败、读取器风格 `load`、`HttpService`、`require` 失败、形似代码的响应、过滤器、过期、保留限制、撤销、恢复失败、导出以及降级的宿主。运行：

```bash
luajit test/net_capture.lua
```

原生测试套件还会连同新分组一起加载构建好的 bundle；`node tools/test_native.js` 会与其他聚焦套件一起运行它。
