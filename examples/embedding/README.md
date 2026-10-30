# 嵌入示例

一个用 **Project UAI UI LIB** 构建的完整自定义 UI，连接到一个实时的 UAI 会话
以及一个小型、由宿主持有的设置模型。它演示了组合、工具注册、状态绑定、
请求处理和清理，而无需在使用方代码中构建 GUI 对象。独立的
[SDK 示例](sdk.lua) 在存储选择或保险库解锁之后保持常规应用隐藏，并对外暴露
自有的工具、请求和拆除流程。

阅读 [嵌入 Project UAI](../../docs/EMBEDDING.md) 了解运行时参考，
阅读 [UI_LIBRARY.md](../../docs/UI_LIBRARY.md) 了解 UI API。该示例面向
Project UAI 3.7.2、嵌入 SDK 1.0.0 和 UI LIB 1.4.0。

## SDK 示例

```lua
local integration = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/examples/embedding/sdk.lua"
))()
-- After choosing storage or unlocking the vault, and configuring a real provider/model:
local request, why = integration.ask("Call sdk_example_status and summarize the result.")
if not request then warn(why) end
-- In a yieldable task: local result, waitError = request.await(30)
-- integration.destroy() releases this integration's tool/listener and requests Stop.
```

加载该入口不会发送请求。它以 `ui = false` 和 `reuse = true` 启动，遵循已保存的
凭据保护选择，持有只读工具 `sdk_example_status`，并打开一个仅允许该工具的
临时会话。它不改变当前的会话选择。被复用的客户端会保留其启动上下文、UI 挂载
状态、提供方和权限。已启用的保险库每次都会索要密码；显式的
**Continue without encryption** 选择会保存可逆编码、未受保护的密钥，并跳过后续
提示。获得访问权限后，`integration.client.show("providers")` 会打开原生应用以
进行提供方设置。SDK 也可以通过
[提供方 API](../../docs/EMBEDDING.md#provider-api) 保存用户提供的提供方设置。

`ask(text)` 会返回一个请求，或者返回 `nil, reason`。进度和最终结果会输出到宿主
控制台。`request.result` 在请求定局后包含结构化结果；`request.onComplete(fn)`
用于注册另一个观察者，`request.cancel()` 则请求协作式 Stop。`await` 超时只会
停止等待，不会取消该轮次。

再次加载本示例前请先调用 `integration.destroy()`：其稳定的作用域 ID 会拒绝
第二个存活持有者。拆除会释放它的工具和监听器，但不会卸载共享客户端，也不会
删除其会话。后续加载会复用该具名会话，并校验其工具策略。该会话是临时的，但
诊断信息和提供方流量仍然是常规的客户端工作。

## 运行助手工作台

在支持 HTTP 和 `loadstring` 的 Roblox 执行器宿主中：

```lua
local integration = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/examples/embedding/launcher.lua"
))()
```

若要获得可复现的分发版本，请把 `launcher.lua` 复制到你的宿主项目中，并把其中的
`revision = "main"` 替换为一个经过审查的提交 SHA。此后运行时、UI 包和两个模块
都会使用同一个修订版本。如果你把入口加载器作为单独的远程脚本分发，也请固定其
URL。加载器的内部修订版本决定了它的依赖 URL；只固定外层 URL 并不会改变该
变量。

加载器会向客户端包传入 `reuse = true`。同一构建的存活副本会被复用，而不会请求
显示常规应用。已启用的保险库仍需要输入密码；已保存的未加密存储选择则会跳过。
首次启动会以一个简短的宿主提示启动标准应用。它会加载 UI LIB 和示例模块，
为该客户端安装一次模型/工具，并创建工作台窗口。下载和编译会分别校验。

窗口最初挂接到 `uai.sessions.current()`。它不会在每次重新运行时都创建新会话。
既有客户端的提供方配置、权限模式、启动提示和工具仍保持其自身设置。在任何
存储选择或保险库解锁之后，用 **Providers** 配置提供方/模型，然后准备好时使用
**Send**。加载器不会自动提交请求，也不会切换权限模式。

## 文件与返回值

| 文件 | 返回 | 职责 |
| --- | --- | --- |
| `launcher.lua` | `{ client, UI, model, window, session }` | 下载并组合该示例 |
| `host_tools.lua` | 安装器函数 `(uai) -> model` | 持有本地状态并注册两个工具 |
| `assistant_panel.lua` | 工厂函数 `(uai, UI, options) -> window, session` | 声明并绑定自定义视图 |
| `sdk.lua` | `{ client, scope, session, created, ask, destroy }` | 隐藏常规应用、凭据保护选择、一个只读工具和结构化请求 |

`host_tools.lua` 和 `assistant_panel.lua` 返回工厂函数。执行或 require 每个模块
以取得其工厂函数，然后用依赖调用它。`launcher.lua` 和 `sdk.lua` 是可执行入口；
直接对其求值会返回组合好的集成。

```lua
integration.window:Minimize()
integration.window:Show()
print(integration.model.read().batchSize)
```

运行时/模型调用使用点号；UI 对象调用使用冒号。

## 在你自己的宿主中组合

在入口点加载模块工厂函数后，传入显式句柄：

```lua
-- uai and UI are already loaded.
-- installModel and createPanel are the factories returned by the module files.
local model = installModel(uai)
local session = assert(uai.sessions.open("my-host-workbench", { title = "My workbench assistant" }))
local window = createPanel(uai, UI, {
	Id = "my-host-workbench",
	Session = session,
	Model = model,
})
```

如果使用 ModuleScripts，`require(HostTools)` 和 `require(AssistantPanel)` 会返回
同样的工厂函数。require 它们并不会让完整的 UAI 运行时在原生 LocalScript 中可用：
你需要提供一份有意设计的兼容运行时集成。若要在没有智能体的情况下使用 Studio UI，
请改用独立的
[ModuleScript 配置](../../docs/UI_LIBRARY.md#local-modulescript-setup)。

### 面板选项

| 选项 | 默认值 | 含义 |
| --- | --- | --- |
| `Id` | `embedding-workbench` | 稳定的 UI 窗口 ID；重新运行会替换旧视图 |
| `Session` | `uai.sessions.current()` | 来自 `current`、`open` 或 `newThread` 的已注册存活会话 |
| `Model` | 无 | 可选的 read/update/subscribe 模型；会额外添加 Workbench 标签页 |
| `Parent` | 库默认值 | 库自有 ScreenGui 的父级；不是 Frame 停靠 |

工厂函数会拒绝不可用或未受跟踪的会话。用 `sessions.create` 创建的会话不会被
注册，也无法在原生历史记录中打开。当原生应用切换到另一个会话时，面板仍保持
挂接在其被传入的会话上。

### 稳定控件 ID

当你的宿主需要访问已声明的控件时，使用 `window:Get(id)`：

| ID | 用途 |
| --- | --- |
| `prompt`、`send`、`stop`、`status`、`reply` | 请求草稿、操作和最新回复显示 |
| `open-client`、`providers` | 打开完整应用或提供方设置 |
| `workbench-title`、`workbench-enabled`、`workbench-batch` | 可编辑的宿主设置 |
| `workbench-state`、`workbench-apply`、`workbench-refresh` | 已应用的摘要和显式表单操作 |
| `theme`、`reduced-motion` | 此窗口的外观偏好 |

提示、状态、回复和已应用状态摘要通过 `Persist = false` 排除在窗口配置之外。
该示例不会自动保存或加载配置档。如果你的宿主添加了配置档加载，请记住导入是
静默的：需要时请显式刷新/应用派生的外观或域状态。

## 宿主模型与工具

示例模型的初始状态为：

```lua
local state = { title = "My workbench", enabled = true, batchSize = 5 }
```

它只改变本地示例设置。它不会检查背包、执行游戏代码、修改服务器，也不会把
设置写入文件。

| 方法 | 约定 |
| --- | --- |
| `model.read()` | 返回已应用状态的全新快照 |
| `model.update(patch)` | 返回 `true, snapshot` 或 `false, reason`；在应用前进行校验 |
| `model.subscribe(callback)` | 投递已应用的快照；返回一个取消订阅函数 |

标题必须包含 1–80 字节且包含非空白文本。`enabled` 必须是布尔值。`batchSize` 必须是
1 到 20 之间的整数。未知字段会被拒绝。被省略的字段保留其先前的值。校验逻辑位于
模型中，因此手动 UI 操作和工具处理程序使用同一边界。

| 工具 | 分组/风险 | 行为 |
| --- | --- | --- |
| `workbench_status` | `workbench` / read | 返回可读摘要和结构化状态 |
| `workbench_configure` | `workbench` / write | 通过模型应用经过校验的补丁 |

`workbench_configure` 在应用前检查取消。由模型生成的写入会经过 UAI 的常规调度器
和权限系统。在默认的 Ask first 模式下，智能体的写入需要批准。手动 Apply 是用户
操作，会直接调用模型；域校验仍会执行。

安装器把它的模型存储在 `uai.env.context.workbenchExample` 中。这是一个示例自有的
命名空间，不是 UAI 的内建上下文选项。在同一存活客户端上重新安装会返回该模型；
工具名不会被注册两次。如果另一个集成已经拥有这些工具名，安装会报告冲突。
若是派生宿主，请选择你自己的前缀和上下文命名空间。其 SDK 作用域同时负责工具和
模型的清理。`model.destroy()` 会移除它们，并使后续更新失败；之后的安装可以创建
一个全新的模型。在替换模型之前请关闭依赖它的视图，以便它们能够绑定替代者。

## 草稿、事件与渲染

提示框会实时发布有效的编辑内容，并限制在 8,000 字节。Send 会读取草稿，检查会话
是否接受，并且仅在被接受且仍未改动时才清空它。被拒绝的发送会保留草稿。接受之后
出现的提供方失败会在最新回复视图中报告。

面板会在重放保留状态之前订阅其会话。它显示一条最新回复，限制在 6,000 字节以内
并采用 UTF-8 感知的截断，外加临时预览。它会把事件驱动的绘制合并为最多一个待处理
的 60 ms 延迟任务。它不会构建第二份完整聊天记录，也不会为每个令牌追加一行 GUI。
**Open UAI** 会显示保留的原生历史记录。

就绪/轮次结束事件可能会早于忙碌状态释放。面板还会观察 `sessions.listChanged`，
其完成回调会刷新准入状态。Stop 是协作式的，并不会立即释放忙碌会话。

Workbench 字段是草稿。工具/模型更新会刷新 **Applied state**，而不会覆盖用户正在
编辑的内容。**Refresh** 会显式地把当前模型复制到字段中。**Apply** 会校验完整表单
并把它写入模型。即使没有可见的 workbench 窗口，模型本身也是共享的。

## 所有权

重新运行加载器会替换 `embedding-workbench`，释放其监听器和待处理的绘制，并复用
模型和同一构建的客户端，而不会请求显示标准应用。已保存的凭据保护选择仍然生效。
不同构建会遵循客户端的受保护重载策略。

Minimize 和 Hide 会保留视图/模型的订阅。关闭自定义窗口只会销毁该视图。会话仍留在
UAI 中，包括任何已被接受的轮次。卸载所传入的客户端会关闭依赖窗口、清除模型的
订阅，并使模型写入失败。视图使用独立的 SDK 作用域进行客户端卸载清理。它的订阅
和绘制任务保留在 `window:Give` 中，而模型的工具会存活得比该视图更久。

```lua
integration.window:Destroy() -- Close this view.
-- Only when your application intends to unload the entire shared client:
-- integration.client.unload()
```

固定的 `Project UAI | UI LIB.` 署名、文本操作、侧边栏配置档、响应式布局和过渡
效果均由该库提供。

## 试用这些行为

1. 在没有活动客户端的情况下启动。打开 Providers，配置一个受支持的真实模型，
   并通过标准 UI 选择该提供方。
2. 在请求中读取 `workbench_status`。请求修改批次大小，并响应写入操作的常规权限
   提示。
3. 在 Workbench 表单中输入一个不同的标题，然后通过工具更新模型。已应用状态应当
   改变，而表单草稿保持不变。
4. 使用 Refresh，修改多个值，然后 Apply。无效的域值应当报告错误，而不会部分替换
   模型状态。
5. 发送、最小化面板，然后重新打开它。会话应当保持挂接，最新回复视图可用，Stop
   操作正常工作。
6. 重新运行加载器。先前的视图应当关闭，且不会重复注册工具，也不会多出额外会话。
   关闭新面板；UAI 应当继续存活。显式卸载 UAI 以结束完整集成。

这些是可选的、基于真实宿主的场景，与离线验证相互独立。它们不需要图像上传或
浏览器自动化。

## 离线验证

在构建之前完成并人工审查所有改动。按照
[分发与验证](../../docs/EMBEDDING.md#distribution-and-verification) 中记载的顺序
生成 UI 指南、客户端包和站点目录，然后检查生成的输出。运行：

```powershell
luajit test/embedding_examples.lua
luajit test/embedding_sdk.lua
luajit test/embedding_sessions.lua
luajit test/ui_library_agent.lua
```

这些 fixture 会加载真实的示例模块和分发包，使用本地下载和模拟提供方。它们不需要
网络或提供方密钥。更广泛的 UI 库测试套件是 `luajit test/ui_library.lua`。离线检查
不会验证原生 Roblox 渲染、IME、触摸/手柄输入或执行器特有的原生行为。本示例不提供
图像附件 UI 或浏览器控件。
