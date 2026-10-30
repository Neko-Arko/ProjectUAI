# Project UAI UI LIB

一个独立的 Roblox 界面库，用于脚本自有的工具。它的工作台使用石墨或瓷白表面、
内嵌式工作区、醒目的标签页标题、Dark 模式下的奶油色主操作按钮、克制的圆角，
以及 Project UAI 的暖珊瑚强调色。每个窗口都自动包含一个 Appearance 标签页，
用于个人配色、圆角、文字大小和动效偏好。
它不会替换或重新设计智能体客户端界面。

源代码位于 [ui-lib/](../ui-lib/)，公开产物是
[dist/uai-ui.lua](../dist/uai-ui.lua)，仓库是
[Project-Ptolemy/ProjectUAI](https://github.com/Project-Ptolemy/ProjectUAI)。
每个窗口、最小化启动器和对话框都包含固定的底部署名
`Project UAI | UI LIB.`。没有选项可以移除或替换它。
库使用文字呈现窗口标题、导航以及每一个操作。它自行绘制基于 Frame 的 Project UAI
标志和窗口控制字形（最小化、关闭、调整大小）；脚本不得添加图标或装饰性标记。
桌面端侧边栏会把本地
玩家的 Roblox 头像固定显示在其显示名、用户名和当前游戏旁边。
无需任何上传素材或下载 logo。

这是 **UI LIB 1.4.0** 的权威 API 与应用指南。关于 UAI
会话、自定义智能体工具、提供方、钩子以及完整宿主生命周期，请使用
[嵌入 Project UAI](EMBEDDING.md)。一个完整的
[助手工作台](../examples/embedding/README.md)把两个包连接在一起。

- [快速开始](#quickstart) 与 [嵌入](#embedding)
- [控件](#controls) 与 [布局](#layout)
- [生命周期](#lifecycle) 与 [配置](#configuration)
- [应用模式](#application-patterns) 与 [运行时集成](#runtime-integration)
- [常用配方](#recipes)、[性能](#performance) 与 [故障排查](#troubleshooting)
- [扩展](#extending) 与 [开发](#development)

## 快速开始

在每个独立脚本中加载一次库。返回的 API 独立
于 Project UAI 客户端。库不会下载字体、图标或第三方脚本。Roblox
服务会异步解析本地头像和体验名称；在这些查询完成之前，
可读的首字母和 "Current experience" 会一直显示。

```lua
local UI = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua"
))()

local window = UI:CreateWindow({
	Id = "my-session-tools",
	Title = "Session tools",
	Subtitle = "Everything you need for this session",
})
local main = window:Tab({ Title = "Main" })
local actions = main:Section({ Title = "Actions" })
local amount = actions:Slider({
	Id = "amount", Text = "Amount", Min = 1, Max = 20, Step = 1, Default = 5,
})
actions:Button({
	Text = "Process selection", ActionText = "Run", Style = "Primary",
	Callback = function()
		-- Your application logic belongs here.
		print("Process", amount:Get())
		window:Notify({ Title = "Finished", Content = "Selection processed.", Kind = "Success" })
	end,
})
return window
```

为窗口使用稳定且专属于该脚本的 `Id`。用相同 Id 重新运行脚本
会销毁它之前的窗口，并调用其已注册的清理函数，即使
它加载的是库的一份全新副本也是如此。不同的 Id 可以共存。不会删除任何
无关的 ScreenGui。

Appearance 会自动提供；脚本无需声明设置
控件。脚本添加的第一个标签页默认打开，Appearance 在导航中
始终位于最后。在移动端，拖动右下角的握柄即可调整窗口大小。

智能体：在编写脚本界面之前，请阅读 `ui_library_docs` 中的 `quickstart`、`controls` 和 `lifecycle`
小节。使用声明式标签页、分区和控件，再加上
领域逻辑。不要在脚本中创建 GUI 实例、样式、布局计算、拖动
处理器、第三方 UI 加载器或替换署名。当缺少某个可复用的组件时，
应扩展共享库。要尊重用户明确要求
在既有自定义界面上工作的指示。

`main` URL 会跟随 v1 API 的兼容更新。若需要可复现的发布，
请把 `main` 替换为 raw URL 中经审查的 Git 提交 SHA。HTTP 和 loadstring
必须在宿主中可用；要暴露它们的错误，而不是静默抓取
另一个 UI 库。在 Studio 中，可以把打包产物放入一个 ModuleScript，
并由 LocalScript 通过 `require` 加载。

## 嵌入

### 选择合适的包

| 需求 | 入口 |
| --- | --- |
| 无需 AI 客户端的脚本自有控件 | `dist/uai-ui.lua` |
| UAI 现有的助手应用 | `dist/uai.lua` |
| 由 UAI 会话/工具支撑的自有控件 | 加载两者，然后把运行中的客户端和 UI API 传入视图工厂 |
| 本地 Studio 界面 | 把 UI 包放入 ModuleScript，并由 LocalScript 通过 require 加载 |
| 浏览器界面 | 使用 Web 桥接；这个 Roblox 库不是 JavaScript 包 |

加载 UI LIB 会返回 API，但不会挂载窗口。`CreateWindow` 会挂载
一个。它不依赖 `getgenv().UAI`，不配置提供方，不更改工具
权限，也不创建智能体会话。完整客户端首次运行时会提供密码
设置，或显式的"不使用加密继续"选项。保险库在每次执行时都需要解锁；
已保存的不受保护存储选择会跳过后续提示。
传入 `{ ui = false, reuse = true }`，以便在授予访问权限后保持常规应用处于隐藏状态，
然后使用 `uai.sdk` 进行自有集成和请求句柄。`uai.show(...)`
会在任何必要的设置或解锁完成后按需显示标准应用。没有
备用的客户端 `Parent` 选项。参见[嵌入 SDK 指南](EMBEDDING.md)。

### 把下载保持在入口点

在入口脚本中加载一份 UI API，并把它传给你的应用模块。
模块应当声明控件和回调，而不是下载第二份库。
当你需要可复现性时，把所有生产 URL 固定在一个经审查的提交 SHA 上。

```lua
local revision = "main" -- Replace with a reviewed commit SHA for a pinned release.
local url = "https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/"
	.. revision .. "/dist/uai-ui.lua"
local ok, source = pcall(function() return game:HttpGet(url) end)
assert(ok and type(source) == "string", "UI library download failed: " .. tostring(source))
local chunk, why = loadstring(source, "@uai-ui")
assert(chunk, "UI library compilation failed: " .. tostring(why))
local UI = chunk()
```

库的元数据（`UI.Version`、`UI.URL`、`UI.Repository`）标识其
发布版本和规范位置。`UI.URL` 是规范元数据；它不会
自动成为你固定到提交的下载 URL。要把选定的修订版
保存在宿主自身的发布元数据中。

### 本地 ModuleScript 设置

把 `dist/uai-ui.lua` 的**内容**放入
`ReplicatedStorage/UAIUI` 作为一个 ModuleScript，然后使用一个 LocalScript：

```lua
local UI = require(game:GetService("ReplicatedStorage"):WaitForChild("UAIUI"))
local playerGui = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
local window = UI:CreateWindow({
	Id = "my-game-workbench", Title = "Workbench", Parent = playerGui,
	ToggleKey = false,
})
local main = window:Tab({ Id = "main", Title = "Main" })
main:Section({ Title = "Actions" }):Button({
	Id = "inspect", Text = "Inspect selection", ActionText = "Inspect",
	Callback = function() print("Call your validated application operation here") end,
})
```

这条 UI 路径不需要运行时 HTTP 或 `loadstring`。基于文件的 `SaveConfig` 和
`LoadConfig` 仍需要执行器的文件系统能力。Studio 游戏可以
使用 JSON 导入/导出，并配合自己的存储流程。服务端拥有的效果
依然应当放在游戏自身经过校验的服务端 API 之后。

### Parent 指 ScreenGui 的父级

`Parent` 选择库在何处创建其 ScreenGui。请提供一个
兼容 PlayerGui/CoreGui 的父级。它不会把控件挂载到既有的
Frame 中，不会继承那个 Frame 的布局矩形，也不会创建可停靠的组件。
库仍然拥有其屏幕、安全区布局、浮层和恢复胶囊。

`window.ScreenGui`、`window.Frame` 和 `control.Frame` 对外暴露，供检查
和测试使用。不要在消费端脚本中重新设置它们的父级、更改样式、替换它们，或把它们当作自定义内容的插槽。
没有公开的任意内容或停靠 API。

### 身份与替换

为每个逻辑应用使用一个稳定的窗口 Id，例如 `myhost-workbench`。
控件需要在该窗口内具有唯一且稳定的 Id，即使跨不同
标签页也是如此。两个标签页不能为不同控件都使用 `Id = "enabled"`。在组合模块时，
按功能为控件 ID 加前缀（`scan-enabled`、`export-enabled`）。

用既有 Id 创建新窗口会释放前一个窗口及其
已注册资源。不同的窗口 ID 可以共存。`UI:GetWindow(id)` 查找一个
处于活动状态的已注册窗口。请使用提供的句柄，而不要按标题枚举
ScreenGui，或按宽泛的名称匹配删除 GUI 对象。

对于提供的完整客户端句柄，请使用 `uai.show(...)` 和 `session.send(...)`，
以点号调用。UI LIB 使用 `window:Show()` 和 `control:Set(...)`，
以冒号调用。两者之间的连接参见
[运行时集成](#runtime-integration)。

## 控件

使用 `section:ControlName({ ... })` 创建控件。通用选项：

| 选项 | 含义 |
| --- | --- |
| `Id` | 窗口内唯一的字符串；配置持久化和 `window:Get(id)` 需要它。 |
| `Text` | 可见标签。使用简短、具体的措辞。 |
| `Description` | 辅助文字，按可用宽度自动换行。 |
| `Default` | 初始值。构造过程从不调用回调。 |
| `Callback` | 在值变化或按钮按下时调用。错误会产生通知，且不会影响其他控件。 |
| `Disabled` / `Visible` | 初始的启用/可见状态。 |
| `Persist = false` | 从导出的配置中排除该值；用于临时或敏感输入。 |

所有控件都有 `Get()`、`Set(value, silent?)`、`Reset(silent?)`、
`SetText(text)`、`SetDescription(text)`、`SetDisabled(boolean)`、
`SetVisible(boolean)`、`OnChanged(callback)` 和 `Destroy()`。
`OnChanged` 返回一个取消订阅函数。各 setter 返回控件本身。
`Set` 仅在值发生变化时调用值回调；`silent = true`
会抑制它们。返回的数组是副本。被禁用的控件仍可通过
编程方式更新。`Get/Set/Reset/OnChanged` 在值控件上很有用；按钮使用
`Press`，仅用于展示的文字使用 `SetText/SetDescription`。

| 构造函数 | 选项与行为 |
| --- | --- |
| `Button` | `ActionText = "Run"`，`Style = "Primary" / "Danger"`（否则为次级样式），`LoadingText`。`Callback()` 在自有的 task 中运行；运行期间的重复按下会被忽略。`Press()` 返回是否已启动；`SetLoading(bool)` 控制加载指示器。 |
| `Toggle` | 布尔型 `Default`；`Callback(enabled)`。紧凑开关周围有全尺寸触摸目标。 |
| `Checkbox` | 相同的布尔 API，带显式的 On/Off 文字。 |
| `Slider` | `Min = 0`、`Max = 100`、`Step = 1`、`Default`、`Suffix`。变化时触发 `Callback(number)`，手势结束时触发一次 `OnCommit(number)`。值会被钳制并相对于 Min 取整；即使步长不能整除范围，Max 也可到达。方向键/D-pad 左右每次改变一个步长；Home/End 到达端点。 |
| `Input` | 字符串 `Default`、`Placeholder`、`MaxLength = 4096` 个 UTF-8 字节、`MultiLine`、`Lines = 3`、`Live = false`。失焦时提交；Live 会在保留草稿/光标位置的前提下发布有效编辑，直到失焦。`Numeric = true` 使用有限数字，并可选的 `Min/Max`。无效草稿会显示错误，同时保留最后一个有效值。`OnCommit(value)` 和 `Focus()` 可用。 |
| `Dropdown` | `Options`、`Default`、`Multi = false`、`Searchable = true`、`Placeholder`。选项记录可接受 `Image`，在行首显示为圆形头像图片，并在关闭状态字段中为当前选中项显示。`SetOptions(array, silent?)` 替换选项，并保留仍然有效的选中项。`Open()` 打开选择器。选项为空时显示空状态。 |
| `Segmented` | 在 1–8 个 `Options` 中进行单选。选择与 `SetOptions` API 与 Dropdown 相同；在窄宽度下会换行成多行。 |
| `Keybind` | `Default = Enum.KeyCode.K`（或 `"K"`）、`Mode = "Press" / "Hold" / "Toggle"`、`ActiveWhenHidden = false`。`Callback(active, key)` 处理激活；`OnChanged(key)` 处理重新绑定。Hold 在按下时调用 true，在释放/取消时调用 false；Toggle 交替切换直到被取消。点击以捕获，Escape 取消，Backspace/Delete 清除。`Set(nil)` 解除绑定。窗口的切换键是保留的。 |
| `ColorPicker` | `Default = Color3.fromRGB(...)`，可选的 `Alpha = 1` 或 `ShowAlpha = true`。HSV 方块、色相条、十六进制和 RGB 输入、预览、Apply/Cancel。颜色分量必须在 0–1 之间；alpha 会被钳制到该范围。`Callback(color, alpha)` 在 Apply 或 Set 更改值时触发。`Get()` 返回颜色、alpha；`GetAlpha()` 和 `SetAlpha(alpha, silent?)` 可用。 |
| `Label` | 自动换行的 `Text` 和可选的 `Description`。 |
| `Paragraph` | `Text` 是标题；`Content`（或 Description）是自动换行的正文。 |
| `Divider` | 一个小分区标签和分隔线。使用 `Text = ""` 得到纯分隔线。 |
| `Badge` | `Default` 或 `Value` 是状态字符串。`Kind = "Success" / "Warning" / "Danger" / "Secondary"`。使用 `Set` 更改字符串。 |
| `Progress` | `Min = 0`、`Max = 100`、`Default` 或 `Value`。`Set(number)` 更新有界轨道和百分比。 |

Dropdown/Segmented 选项是原始字符串、有限数字或布尔值，
也可以是形如 `{ Label = "Balanced", Value = "balanced", Disabled = false }` 的记录。
记录还可以携带 `Image`，即一个 URL，在
下拉行首和关闭状态字段中为当前选中项渲染为圆形头像。玩家
头像可使用内置的
`rbxthumb://type=AvatarHeadShot&id=<UserId>&w=150&h=150` 方案，客户端会
在无需上传或 HTTP 请求的情况下解析它；图片加载完成前，可读的首字母会一直
显示在图片后面。值必须唯一。Dropdown 支持最多
500 个选项，使用字面搜索。
单选 `Default` 和 `Get` 使用单个值（无选中时为 nil）；
多选使用数组。多选变化是即时的；Done 关闭
选择器。被禁用的选项会显示，但无法通过交互选中。

窗口打开时，按键绑定跨标签页生效。它们会忽略已处理的输入、
文本编辑和已打开的对话框。隐藏或销毁窗口会释放活动的
Hold/Toggle 动作。初始化或配置导入都不会模拟按键
按下。按键绑定的 `Set` 更新的是绑定，而不是其激活状态。

## 布局

`UI:CreateWindow(options)` 接受 `Id`、`Title`、`Subtitle`、可选的
`Width = 780` / `Height = 580`、`Search = true`、`Theme = "Dark" / "Light"`、`ThemeToggle = true`、
`Accent = Color3`、`Colors = { token = Color3 }`、`CornerRadius = 10`（0–16）、
`TextScale = 1`（0.85–1.5）、`ToggleKey = Enum.KeyCode.RightShift`
（false 表示禁用它）、`DisplayOrder = 80`、`Parent`、`OnDestroy`、可选的
`GameName`，以及可选的 `ReducedMotion`。
仅在嵌入时提供兼容 PlayerGui/CoreGui 的父级。
默认父级依次为 gethui、CoreGui、PlayerGui，并带能力检测。
在 gethui 或 CoreGui 下运行时，库会捕获加载线程的
安全身份，并在控件更新和计划回调之前重新应用它，
以便 Heartbeat 之类的引擎事件能在不丢失 Plugin 能力的情况下更新值。
省略 Width 或 Height 时，触摸窗口优先使用至多屏幕
宽度 90% 和高度 76%，受默认首选尺寸限制，
且最小为 280 × 240 像素。安全视口始终优先。显式指定的
Width 或 Height 会在该视口内保持所请求的大小。

库会处理安全内边距、视口/摄像机更换、设备旋转、
键盘遮挡、至少 44 像素的触摸目标、鼠标拖动、
鼠标和触摸调整大小、自动换行的描述、独立滚动的标签页，以及聚焦字段的
滚动可见。它在紧凑宽度下重排布局，而不是用 UIScale 缩小
界面。导航会变成横向滚动的标签条。
在桌面端，控件使用 40 像素的目标，并随文字缩放增大。
空间紧张时，行会把值堆叠到标签下方。

视觉刷新保持 v1 的构造函数、方法、回调和配置
格式兼容。既有脚本无需更改声明即可获得新外观。
每个标签页都有一个标题和实时的控件/分区计数；它们
随内容滚动，因此不会占用矮键盘布局的空间。
搜索会更新计数并保持空状态清晰。分区使用柔和圆角的
表面，字段使用内嵌背景，选中项带有强调色边缘。
聚焦和校验状态在主题变化后依然保留。文字在过渡全程保持其
最终大小的原生渲染；打开视图从不会缩放其内容。

`window:Tab({ Id?, Title })` 创建一个纯文字标签页。旧的 `Icon` 选项
会被忽略，消费端脚本不得提供新图标。`tab:Select()`、`tab:SetVisible(bool)`
和 `tab:Destroy()` 用于管理它。
自动的 Appearance 标签页使用保留 Id `__uai_appearance_tab`。
以 `__uai_appearance_` 开头的标签页和控件 Id 属于库；
消费端脚本必须使用自己的 Id。

`tab:Section({ Title, Description?, Collapsible?, Collapsed? })` 创建一个
分组。分区支持 `SetCollapsed(bool)`、`SetVisible(bool)` 和 `Destroy()`。
搜索会过滤活动标签页的标签、描述和分区标题，
展开匹配的已折叠分区，并显示清晰的空状态。

窗口方法：`Show()`、`Hide()`、`Minimize()`、`Toggle()`、`Destroy()`、
`SelectTab(idOrTab)`、`SetTitle(title, subtitle?)`、
`SetTheme("Dark"|"Light", accent?)`、`GetTheme()`、`ToggleTheme()`、`SetTextScale(number)`、
`SetReducedMotion(boolean)`、`Get(controlId)`、
`SetSize(width, height)`、`GetSize()`、`ResetSize()`、
`SetAppearance(options)`、`GetAppearance()`、`ResetAppearance()`。
`GetSize()` 返回可见的宽度和高度（像素）。`SetSize` 接受
有限的像素尺寸，钳制到宽 280–1600、高 240–1200，然后再把它们
适配到安全视口。拖动握柄使用相同的边界，并保持
左上角固定。选定的尺寸在文字变化、旋转和
键盘遮挡后依然保留。`ResetSize()` 恢复构造函数中的偏好并
使窗口居中，包括对省略尺寸的自动移动端适配。
最小化会在屏幕上保留一个带品牌的恢复胶囊：它显示标志、标题、
副标题和
署名，可在安全视口内任意拖动，并在非拖动的点击时恢复。
隐藏也会移除该胶囊，最小化期间到达的通知会更新其状态。
右上角的关闭按钮销毁窗口。
最小化和关闭字形没有静态填充；
悬停会使它们变亮，手柄选择会增加聚焦描边。模式图标
位于它们旁边、最小化的左侧。
在鼠标和触摸设备上，调整大小的握柄保持在右下角；其
触摸目标至少为 44 像素。每个窗口都有独立的主题和状态。页脚
固定在滚动内容之外。侧边栏资料保持在
滚动标签页下方；紧凑和矮布局使用横向标签页并省略
资料，以保留控件空间。资料会把游戏名放在
单独的全宽行。当脚本已知道显示名时，
`GameName` 会覆盖自动的游戏
查询。

### 亮色与暗色模式

两种模式使用相同的语义令牌和实时绑定。内置的模式
操作是位于最小化左侧的标题图标，携带它所提供的模式：
Dark 下为太阳，Light 下为月亮。它保持与其他窗口控件相同的鼠标、触摸和手柄
行为。当你的应用提供自己的控件时，
设置 `ThemeToggle = false` 可以省略它。

`window:GetTheme()` 返回活动名称和可选的自定义强调色。
`window:ToggleTheme()` 在切换模式时保留该强调色。
`window:SetTheme("Light", accent)` 同时设置两者；省略强调色会恢复该
模式的默认强调色。自定义强调色必须包含 0–1 之间的有限 RGB 分量；
库会按 sRGB 对比度选择黑色或白色前景色。

主题变化会重绘既有控件、选中/禁用状态、聚焦和
无效字段、打开的选择器、对话框、通知以及最小化启动器。
它们会在不改变值、草稿、选中项或
滚动位置的情况下结束活动过渡。新组件继承活动调色板。每个窗口保持
独立；不会向其他脚本或 UAI 客户端应用共享的全局主题。
使用下文既有的配置方法来保留选定的模式。

### 自动 Appearance 设置

每个窗口都包含 Appearance，无需任何脚本声明。通用设置
涵盖 Dark/Light 模式、强调色选择器、圆角、文字大小和减弱
动效。可折叠分组暴露表面、文字、操作/状态、交互、
边框和浮层颜色。更改会立即重绘当前窗口；
打开的选择器、对话框和最小化启动器共享这些偏好。
重置颜色恢复当前模式的调色板。全部重置恢复创建时
提供的初始外观。固定署名保持可见。

`GetAppearance()` 返回一个全新表，包含 `Theme`、可选的 `Accent`、
`Colors`（自定义令牌覆盖）、`CornerRadius`、`TextScale` 和 `ReducedMotion`。
`SetAppearance(options)` 接受这些字段的任意子集，并在应用前
校验完整变更。`Accent = false` 恢复默认强调色。
提供 `Colors` 会替换整个覆盖映射；`Colors = {}` 会清空它。
省略的字段保留当前值。`SetTheme` 和 `ToggleTheme` 保留
自定义令牌覆盖，公开的 setter 会静默反映到设置中。

```lua
window:SetAppearance({
	Theme = "Dark",
	Accent = Color3.fromRGB(122, 205, 191),
	Colors = { Canvas = Color3.fromRGB(19, 28, 34), Surface = Color3.fromRGB(26, 38, 46) },
	CornerRadius = 4,
})
```

支持的 `Colors` 键为 `Canvas`、`Sidebar`、`Chrome`、`Surface`、`Raised`、
`Input`、`Hover`、`Pressed`、`Track`、`Border`、`Subtle`、`Edge`、`Text`、`Secondary`、
`Muted`、`Disabled`、`OnAccent`、`Primary`、`OnPrimary`、`Success`、`Warning`、
`Danger`、`Scrim`、`Selected` 和 `AccentSoft`。通过 `Accent` 设置强调色，
除非覆盖 `OnAccent`，否则它会自动选择可读的前景色。
自定义主操作同样会获得可读的 `OnPrimary`（除非另行提供）。
其他颜色配对遵循用户的选择。所有颜色都要求 0–1 之间的有限 RGB
分量。圆角的窗口、面板、分区和字段表面遵循
圆角偏好；圆形头像、滑块拇指和开关轨道保持
其功能性形状。

窗口、标签页、选择器和通知以固定几何尺寸配合短暂
淡入来呈现内容。标签页切换保留滚动位置，并且只更新
受影响的导航状态；快速连续选择会继续当前的淡入。
悬停、聚焦和切换过渡从其当前值反向进行。隐藏的
控件会立即结束过渡，过渡在完成、
隐藏、失焦、替换和销毁时释放其资源。未显式指定
`ReducedMotion` 选项时，库会在可用时遵循 Roblox 的减弱动效偏好。
`SetReducedMotion(true)` 会立即结束活动过渡。
拖动只移动窗口；它不会重新测量控件列表。

## 生命周期

使用 `window:Give(resource)` 注册逻辑资源：RBXScriptConnection、
Instance、task 线程或清理函数。它返回一个提前释放函数。
`window:OnDestroy(function)` 是注册清理的别名。资源
在窗口关闭、其 ScreenGui 被移除、其 Id 被
替换，或调用 `UI:DestroyAll()` 时释放。清理是幂等的。

```lua
local players = game:GetService("Players")
window:Give(players.PlayerAdded:Connect(function(player)
	window:Notify({ Title = "Player joined", Content = player.DisplayName })
end))
window:OnDestroy(function()
	-- Restore temporary application state and stop any domain-level worker.
end)
```

使用事件驱动的逻辑。不要在回调内启动无主的无限 task。
通过 UAI 托管的 `run_luau` 运行时，工具自有 task 受执行
工具的截止时间约束；对于初始脚本返回后仍需继续的 UI 逻辑，
请使用自有的事件连接。动态加载库不会延长该
截止时间，也不会撤销应用的副作用。回调在让出后
应检查其自身领域对象的生命周期。

`UI:GetWindow(id)` 返回一个活动句柄，`UI:DestroyAll()` 只关闭库
窗口，`UI.Version` / `UI.URL` / `UI.Repository` 标识发布版本。
GUI 实例句柄以 `window.ScreenGui`、`window.Frame` 和
`control.Frame` 暴露，供检查和测试使用。不要在
消费端脚本中为它们设置样式或重新设父级；这样做会破坏布局和所有权契约。

### 为每个资源指定所有者

| 资源 | 注册方式 | 生命周期 |
| --- | --- | --- |
| Roblox 服务连接 | `window:Give(signal:Connect(fn))` | 窗口 |
| 宿主模型或 UAI 的取消订阅函数 | `window:Give(unsubscribe)` | 窗口 |
| 短期计划防抖/重绘 | `window:Give(thread)`；完成时注销 | 窗口或完成时 |
| 临时领域状态 | 一个 `window:OnDestroy(cleanup)` | 窗口 |
| 共享模型或 UAI 客户端 | 视图之外、由宿主拥有的清理 | 宿主/客户端，可存活得比窗口更久 |

隐藏和最小化保留你的订阅和应用状态。销毁
会释放它们。库在隐藏时释放活动的按键按住/切换，但这
不会停止无关的智能体回合或你自己的领域操作。

`Give` 返回的提前释放函数通常处置资源。
`release(false)` 会注销而不处置。当 task 已经
完成时使用后者。释放两次无害。独立资源之间的清理顺序
不保证；把相互依赖的拆除步骤合并到一个函数中。

### 拥有一个延迟更新

这个辅助函数会安排一次待处理的重绘，在运行时使用最新的模型状态，
并从窗口的清理注册表中移除已完成 task：

```lua
local function makeQueuedRefresh(window, refresh)
	local queued = false
	return function()
		if queued or not window.Alive then return end
		queued = true
		local release, finished
		local thread = task.delay(0.06, function()
			finished, queued = true, false
			if release then release(false) end
			if window.Alive then refresh() end
		end)
		if not finished then release = window:Give(thread) end
	end
end
```

`refresh` 是你的同步、有界的视图更新。把模型的变更
信号订阅到返回的函数，并把该订阅注册到窗口。
示例使用 60 ms 延迟；请根据领域选择合适的速率，并在交互需要时
立即显示最终状态。

### 守护异步结果

请求可能在窗口关闭后或更新的请求开始后完成。
在视图中维护一个代次计数器，并在应用结果之前检查它以及 `window.Alive`。
即使可见的发起按钮
已被禁用，这也是必要的：其他模型更新或拆除仍可能使工作过期。

不要强制取消一个挂起在可能稍后恢复它的原生 API 中的协程。
对于这类工作，请使结果失效，并让原生调用
自行结束。库自有的短期 task 与具有自身取消
契约的宿主操作有不同的生命周期。按钮已在自有
task 中运行其回调；避免在其中放入无限轮询循环。

绝不要把关闭视图当作隐式命令，用来销毁共享的 UAI 客户端
或删除已保存的对话。如果你的应用提供这些操作，请
为它们给出明确的名称和回调，并与视图清理分离。

## 配置

为有状态控件提供稳定的 Id。`window:ExportConfig()` 返回带版本的 JSON；
`window:ImportConfig(json, options?)` 返回 `true, count` 或 `false, error`。
导入要求相同的窗口 Id，在更改任何值之前校验每个已知值，
忽略已移除/未知的控件 Id，并拒绝已更改的控件类型。
配置 JSON 限制为 256 KiB。标记为 `Persist = false` 的值
既不导出也不导入。

导出还会在可选的 `appearance` 字段中包含窗口的模式、可选的自定义强调色、颜色覆盖、
圆角、文字缩放和减弱动效。
自动设置控件不会在 `values` 中重复。
导入在更改任一项之前校验外观和所有已知控件值，
并且在静默导入期间也会恢复外观。
没有 `appearance` 的版本 1 配置文件仍然受支持，并保持当前
外观不变。更早的仅主题/强调色记录会保留较新的偏好，
包括在没有显式覆盖时遵循 Roblox 的动效偏好。
返回的计数仍然统计已恢复的应用控件。保存/加载使用
同一格式，因此外观持久化不需要单独的设置文件。

导入默认是静默的：它们更新控件而不启动应用
操作。`{ Silent = false }` 会在所有值恢复后调用值回调。
活动 Hold/Toggle 绑定会在完整状态恢复后收到一次释放（`false`）；
导入从不会发送激活（`true`）。释放
回调可能清理或销毁其窗口。当应用需要初始控件值时，
请显式读取它们。

`window:SaveConfig("profile-name")` 保存在 `ProjectUAI/UI/` 下，并返回
`true, path` 或 `false, error`。`window:LoadConfig("profile-name", options?)`
读取并导入。名称允许 1–48 个字母、数字、下划线和连字符。
文件按窗口命名空间隔离；路径不能穿越目录。
缺少执行器文件系统函数会返回明确错误；JSON 导出/导入
可与 Roblox HttpService 配合使用，且不需要执行器存储。
不会自动读取、保存或应用任何配置。

### 控件值与应用程序状态

配置恢复的是窗口声明的值。它不会调用你的
模型的 API、设置 UAI 提供方选项，或校验游戏层面的关系。
请保留一个显式函数，用于读取完整表单、校验它，并将其应用到你的应用。
在你选择的边界调用该函数：一个 Apply
按钮，或一个刻意的加载并应用操作。

例如，给定既有的 `title`、`enabled` 和 `batch` 控件，以及一个
带有 `update(patch)` 的模型：

```lua
local function applyForm()
	local ok, why = model.update({
		title = title:Get(), enabled = enabled:Get(), batchSize = batch:Get(),
	})
	if not ok then
		window:Notify({ Title = "Settings kept", Content = tostring(why), Kind = "Warning" })
	end
	return ok
end
```

在静默导入之后，请自行调用任何派生视图的刷新函数。例如，
导入的模式可能需要显示详情分区或禁用
无关字段。静默导入不会调用通常处理
该工作的 `OnChanged` 订阅者。

对提示、临时状态和敏感输入使用 `Persist = false`。UI
配置是普通 JSON，不是加密存储。API 密钥字段不应
包含在可共享的窗口配置中。

### 演进已保存的配置

当只有标签或标签页布局变化时，保持控件 Id 和类型稳定。重命名的
标签保留其已保存的值；新的 Id 会创建新的设置。已移除
控件的旧条目会被忽略。把 Id 复用于不同的控件类型会在导入时
被拒绝，因此请为替换设置提供新的 Id，或在把 JSON 传给 `ImportConfig` 之前实现
刻意的迁移。

已知值在变更应用之前会被校验。这保护表单
免于部分无效导入；它不会使后续的应用回调
成为事务，也不会回滚其效果。对于必须一起应用的设置，
优先使用静默导入后接一个
经校验的领域操作。

## 应用模式

### 从模型契约开始

一个小型应用通常需要三个操作：

| 宿主操作 | 含义 |
| --- | --- |
| `model.read()` | 返回当前已应用状态的快照 |
| `model.update(patch)` | 校验并应用领域变更；返回 true/快照或 false/原因 |
| `model.subscribe(callback)` | 通知视图已应用的变更；返回取消订阅函数 |

这些名称是示例契约，不是内置的 UI LIB 方法。完整的
[工作台模型](../examples/embedding/host_tools.lua)提供了一个。不同的
应用可以把既有控制器适配为这种形状。

### 即时设置与静默反映

这个工厂期望上述模型契约带有 `enabled` 和 `batchSize` 字段。
它声明控件，把用户更改送入模型，并反映模型
变化而不触发另一次写入：

```lua
return function(window, model)
	local tab = window:Tab({ Id = "settings", Title = "Settings" })
	local section = tab:Section({ Title = "Processing" })
	local initial = model.read()
	local controls = {}
	local function reflect(value)
		if not window.Alive then return end
		controls.enabled:Set(value.enabled, true)
		controls.batch:Set(value.batchSize, true)
		controls.batch:SetDisabled(not value.enabled)
	end
	local function apply(patch)
		local ok, why = model.update(patch)
		if not ok then
			reflect(model.read())
			window:Notify({ Title = "Change kept", Content = tostring(why), Kind = "Warning" })
		end
	end
	controls.enabled = section:Toggle({
		Id = "processing-enabled", Text = "Enable processing", Default = initial.enabled,
		Callback = function(value) apply({ enabled = value }) end,
	})
	controls.batch = section:Slider({
		Id = "processing-batch", Text = "Batch size", Min = 1, Max = 20, Step = 1,
		Default = initial.batchSize,
		OnCommit = function(value) apply({ batchSize = value }) end,
	})
	window:Give(model.subscribe(reflect))
	reflect(model.read())
	return controls
end
```

滑块的 `OnCommit` 在手势结束时应用。使用 `Callback` 进行开销低廉的
即时预览，使用 `OnCommit` 执行相应的最终操作。编程式
`Set` 使用值回调；不要假设它会模拟滑块
手势并调用 `OnCommit`。

### 可编辑表单与已应用状态

Input 在聚焦时有一个草稿，以及一个最后一个有效值。使用 `Live = false` 时，
普通编辑在失焦时提交。使用 `Live = true` 时，有效编辑会在
字段保留光标和草稿的同时发布。无效的数字输入仍会
作为错误显示；`Get()` 仍返回最后一个有效值。

对于构成一个操作的多个设置，请从快照初始化控件，
并提供一个 Apply 按钮。让外部模型变化刷新一个
**Applied state** 摘要。提供一个单独的 Refresh 操作来替换表单
值。这可以防止智能体或后台事件抹掉用户
未完成的输入。

[助手面板示例](../examples/embedding/assistant_panel.lua)实现了
这种模式。其 Workbench 标签页通过一次模型
调用应用全部三个设置。当覆盖已更改对象不合适时，
你的领域操作应报告冲突或目标修订版过期。

### 依赖控件

派生可见性和启用状态应放在同一个刷新函数中：

```lua
local mode = section:Segmented({
	Id = "export-mode", Text = "Export mode", Options = { "Summary", "Detailed" },
	Default = "Summary",
})
local detail = section:Input({
	Id = "export-note", Text = "Detail note", Default = "", MaxLength = 200,
})
local function refreshMode()
	detail:SetVisible(mode:Get() == "Detailed")
end
window:Give(mode:OnChanged(refreshMode))
refreshMode()
```

隐藏或禁用的控件保留其值，并且仍可通过
`Set` 更新。那些是展示状态，不是授权。在执行操作时，只读取并校验
适用于所选模式的字段。

### 动态选项与稳定值

使用稳定 ID 作为选项 `Value`，使用人类可读的名称作为 `Label`。玩家
可以在不更改 `UserId` 的情况下更改显示名；使用该身份进行
选择。如果选项可能重排，不要使用列表索引作为持久值。
`SetOptions` 保留仍然有效的选项，并规范化已移除的选中项。
把 nil 或空数组当作正常的无选中状态处理。

搜索是字面匹配。把 Dropdown 集合保持在 500 个选项的界限内，
对更大的数据集使用领域搜索/过滤后的集合。被禁用的选项
无法通过交互选中；运行操作时再次检查领域资格，
因为目标在选中后可能发生变化。

### 把增长的界面拆分为模块

一个入口点加载 UI LIB 并创建窗口。功能工厂接收
该窗口（或一个标签页）以及它们的模型/控制器。每个功能都通过
提供的窗口管理其订阅。当入口点需要时，
返回控件或一个显式的刷新方法。

```text
my-host/
  launcher.lua          loads UI once and composes the application
  model.lua             state, validation, and domain operations
  processing_tab.lua    declares processing controls against the model
  history_tab.lua       declares a bounded history view
```

在 Studio 中，这些模块可以是由 LocalScript require 的 ModuleScript。在
执行器宿主中，在入口点加载你审查过的源模块。一个源
模块可以 `return function(window, model) ... end`，如上所示。不要在每个
功能模块中重复窗口创建、样式、字体、内边距、拖动系统或辅助 ScreenGui。

### 用文字传达状态

使用简短的动作动词：Run、Apply、Stop、Refresh、Export。当结果需要解释时，
把操作与
清晰的字段标签和描述配对使用。使用
Badge 或 Progress 表示状态，使用 Paragraph 表示有界说明，使用
通知表示临时结果。颜色应支撑可读的状态文字。

库拥有排版、间距、触摸目标和聚焦呈现。
设置 Title/Subtitle，选择 Dark/Light，通过窗口 API 调整 TextScale，
并在有用时提供减弱动效。不要向导航添加纯图标按钮、Unicode
符号替代图标或装饰性标记。玩家选择中的主体
头像是内容，不是操作图标。

侧边栏资料是自动的。`GameName` 提供已知名称；
无需自行抓取 logo 或玩家头像。紧凑和矮
布局会省略资料，同时保持控件可达。

## 运行时集成

UI LIB 可以作为宿主模型和 UAI 会话的呈现层。完整的
[嵌入指南](EMBEDDING.md)记录了运行时 API；本节
为阅读 `ui_library_docs` 的脚本作者提供必要的视图契约。

### 附加一个伴随面板

给定既有的活动 `uai` 句柄和已加载的 `UI` API：

```lua
local createPanel = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/examples/embedding/assistant_panel.lua"
))()
local window, session = createPanel(uai, UI, {
	Id = "my-assistant-panel",
	Session = uai.sessions.current(),
})
```

该示例返回一个工厂；第一次调用会求值源模块，
第二次调用构造视图。它接受 `Id`、`Session`、可选的 `Parent`，
以及可选的 `Model`（带有上述 read/update/subscribe 契约）。
使用[启动器](../examples/embedding/launcher.lua)进行带校验的下载
以及示例模型/工具的安装。在分发的宿主脚本中，把所有模块固定到
同一个经审查的修订版。

面板会保持附加到所提供的已注册对话。它不会
自动跟随活动线程变化。为专用线程使用 `uai.sessions.newThread(...)`；
`sessions.create(...)` 不受跟踪，不被
此伴随示例接受。

### 发送是一个准入结果

`session.send(text, onDone, files, images)` 返回 `true` 或 `false, reason`。
仅在为 true 后才清空草稿，并且仅当当前草稿仍与
已提交内容一致时。回调在忙碌状态释放后运行，并接收
回复文字，其中可能描述失败。观察 `error` 和 `turn:end.failed`
以了解失败状态。在延迟回调更新控件之前检查 `window.Alive`。

`status = "Ready"` 和 `turn:end` 可能在 `session.busy` 变为 false 之前到达。
订阅 `uai.sessions.listChanged`，或使用 `onDone`，在 worker 释放忙碌状态后刷新准入
控件。同时关注 `session.preparing` 和
`session.removed`。停止操作调用 `session.abort()`；它是协作式的，因此请保持
停止状态，直到会话结束。

### 信号与重放

```lua
window:Give(session.events:connect(function(event)
	if event.kind == "assistant:text" then
		reply:SetDescription(event.text or "")
	elseif event.kind == "error" then
		window:Notify({ Title = "Request failed", Content = event.message, Kind = "Warning" })
	end
end))
```

这里 `reply` 是一个既有的 Paragraph。它的正文 setter 是 `SetDescription`，
而不是 `SetContent`。这个小示例说明了绑定方式；生产面板
应当约束显示的文本，并像完整的
伴随面板那样合并频繁更新。

UAI 信号使用小写 `:connect` 并返回取消订阅函数，这与
Roblox 的 `:Connect` 返回 RBXScriptConnection 不同。`window:Give` 接受两者。
对于初始状态，在订阅后读取 `session.transcript.snapshot()`，
并读取 `session.livePreview` 获取正在进行的响应。`assistant:preview` 包含
累积的当前预览；应当替换它，而不是把它作为增量追加。
在完成、中止、错误和重置时清除预览。完整转录视图
必须协调保留的 ID 和遗漏；最新响应视图可以替换
一个有界的 Paragraph。

### 保持宿主与视图生命周期分离

注册一个客户端生命周期的清理，用于关闭依赖视图：

```lua
local scope = assert(uai.sdk.createScope("my-assistant-view"))
scope.give(function() window:Destroy() end)
window:OnDestroy(function() scope.destroy() end)
```

关闭面板随后会注销该运行时清理。它不会调用
`uai.unload()`、中止回合或删除其对话。如果宿主拥有这些操作，
请把它们放在明确的应用命令之后。

自定义智能体工具应调用稳定的宿主模型，而不是某个控件或捕获的
窗口。`scope.registerTool(definition)` 会拒绝重复名称，并在作用域关闭时取消注册
自有工具。这些工具
和手动 UI 操作都可以调用同一批经校验的领域操作。

保留对标准应用的访问，用于提供方设置和审批：
`uai.show("providers")` 打开设置；`uai.openSession(session.id)` 打开
对话。自定义窗口不会授予新的
能力，也不会绕过既有的权限规则。

## 常用配方

通知：

```lua
window:Notify({
	Title = "Saved", Content = "Your preferences are ready.",
	Kind = "Success", Duration = 5,
	Action = { Text = "Open settings", Callback = function() settingsTab:Select() end },
})
```

`Kind` 是 Info/Success/Warning/Danger。最多保留三个通知；
能容纳的最新通知可见。较早的通知会在空间变得
可用或较新的通知关闭时重新出现。长文本会被约束并截断。
`Duration = 0` 会让一个通知保持可见直到被关闭；否则为 0–60 秒。
返回的句柄具有 `Close()`。

对话框：

```lua
window:Confirm({
	Title = "Reset preferences?", Content = "This restores the defaults for this tool.",
	ConfirmText = "Reset", Danger = true,
	Callback = function() amount:Reset() end,
})
window:Dialog({
	Title = "About this tool", Content = "A focused workspace for your current session.",
	Buttons = { { Text = "Done", Style = "Primary" } },
})
```

`Dialog` 接受 1–4 个按钮，每个按钮带有 `Text`、可选的 `Style` 和 `Callback`。
选择按钮会关闭对话框，然后在窗口的作用域中运行回调。
`Dismissible = false` 禁用背景/Escape 关闭和关闭按钮。
对话框返回一个 `Close()` 句柄，并恢复之前的游戏手柄选择。
每个窗口同时只能打开一个对话框或选择器。选择器会钳制到安全视口，
在需要时移到其锚点上方，并在紧凑布局中使用居中的表单。

动态选项：

```lua
local target = actions:Dropdown({
	Id = "target", Text = "Target", Options = {}, Placeholder = "No players yet",
})
-- Each player is their headshot followed by their display name. The rbxthumb
-- scheme resolves inside the client, so no upload or HTTP request is needed.
local function playerChoice(player)
	return {
		Label = player.DisplayName,
		Value = player.UserId,
		Image = string.format("rbxthumb://type=AvatarHeadShot&id=%.0f&w=150&h=150", player.UserId),
	}
end
local function refreshPlayers()
	local choices = {}
	for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
		choices[#choices + 1] = playerChoice(player)
	end
	target:SetOptions(choices)
end
refreshPlayers()
window:Give(game:GetService("Players").PlayerAdded:Connect(refreshPlayers))
window:Give(game:GetService("Players").PlayerRemoving:Connect(function(leaving)
	local choices = {}
	for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
		if player ~= leaving then choices[#choices + 1] = playerChoice(player) end
	end
	target:SetOptions(choices)
end))
```

完整示例：[starter.lua](../ui-lib/examples/starter.lua) 和
[showcase.lua](../ui-lib/examples/showcase.lua)。它们加载与生产脚本相同的公开包，
并且不包含任何 GUI 实例构造。

关于完整的模型、工具注册和自定义助手面板，请使用
[examples/embedding](../examples/embedding/README.md)。

## 性能

### 让工作量与视图需求成正比

| 工作 | 推荐模式 |
| --- | --- |
| 某个设置发生变化 | 更新受影响的控件，使用静默 setter 进行反映 |
| 大量状态事件到达 | 排队一次有界刷新，读取最新状态 |
| 滑块移动 | 通过 Callback 进行廉价预览；在 OnCommit 执行昂贵操作 |
| 玩家列表变化 | 按稳定身份替换有界选项列表 |
| 助手响应增长 | 替换有界的最新响应预览；打开 UAI 查看完整历史 |
| 窗口被重新运行 | 稳定的 Id 替换和自有清理 |
| 原生操作延迟完成 | 在发布结果之前进行代次/生命周期检查 |

不要为每次设置变化重建窗口，不要每帧轮询已有事件的状态，
也不要为每一行日志构建一个控件。窗口
已经拥有布局和重排。在消费端代码中更改 Frame 位置或尺寸会与该系统竞争。

Dropdown 最多支持 500 个选项。Segmented 控件用于 1–8 个选项。
Paragraph 会自动换行纯文本，不是 Markdown 渲染器、代码编辑器或
虚拟化转录。先约束你的数据；当产品需要时，
在 `ui-lib/src` 下添加共享的分页或虚拟化组件。

### 隐藏视图仍然有状态

Hide/Minimize 会停止窗口的可见呈现并释放活动输入
动作，而你的订阅仍被拥有且处于活动状态。Destroy 是
资源释放边界。最小化期间宿主事件仍可能到达；它
必须在不假设存在可见的已测量矩形的情况下更新状态。

伴随示例保留一个有界响应，并至多安排一次
待处理的重绘。它不实现单独的虚拟转录。对于
更大的可复用视图，把状态与已挂载的行分开保存，保留
阅读锚点，把隐藏期间的零测量视为临时值，并在恢复时
从保留状态刷新。视口分块绝不能删除模型的
对话或丢失用户的草稿。

1.3.0 中没有公开的窗口可见性变更信号。不要发明
`OnShow`/`OnHide` 选项，也不要给窗口的方法打补丁来模拟它们。简单的
有界视图可以保持订阅。需要专门
可见性生命周期支持的可复用视图，应先向库添加该能力。

### 动效与响应式

移动端布局使用更小的内容内边距、自动换行的分区标题，以及为触摸调整尺寸的对话框
操作行。当键盘留有足够空间容纳一整行选项时，
Dropdown 搜索保持在滚动选项上方；在更矮的
视图中，它会加入滚动主体。当空间太短无法固定时，对话框操作同样会加入主体。
打开的选择器在旋转或文字缩放变化后重排其字段和操作，而不替换草稿。

在触摸屏上，横向滑块和颜色条会等待轻点释放或
横向移动后才改变值。垂直滑动仍是滚动手势，
不会调用滑块的 `OnCommit`。活动的横向拖动会临时保持其
滚动祖先；释放、取消、隐藏、旋转、替换和
销毁会恢复滚动。当键盘使整个字段过高而无法显示时，
多行字段会显示正在编辑的行。隐藏窗口、标签页或
控件会释放其文本聚焦。

使用库自有的过渡和 `SetReducedMotion` API。不要向
消费端脚本添加逐帧入场补间、自定义拖动动效或人为的逐字打字循环。
`SetReducedMotion(true)` 会结束活动过渡，
窗口销毁/替换会释放它们的资源。

先选择首选的 Width/Height，然后让库适配安全视口。
长描述会换行，值行会堆叠，空间受限时标签页会切换为横向条。
避免在应用代码中把桌面像素宽度当作不变量。
在更大的 TextScale 值下保留有用的文字，并在颜色之外
提供可读的状态。

## 故障排查

| 问题 | 解决方案 |
| --- | --- |
| 控件创建时回调没有运行 | 构造函数刻意不调用回调；请读取初始值或调用领域初始化函数 |
| 编程式更新反复调用模型 | 在反映模型状态时使用 `Set(value, true)` |
| 导入更改了值但没有更改依赖控件 | 静默导入会抑制回调；随后调用你的派生视图刷新 |
| 导入拒绝了原本有效的设置 | 检查窗口 Id、控件类型和当前值的范围；按需刻意迁移 |
| 文件系统保存失败 | 使用 ExportConfig/ImportConfig，或提供宿主的存储流程；Studio 没有执行器文件 |
| 文本正文不更新 | Paragraph 的正文使用 `SetDescription`，而 `SetText` 更改其标题 |
| 数字输入显示错误但 Get 返回较旧的值 | 无效草稿保留最后一个有效值；不要把该值当作原始草稿 |
| 滑块回调过于昂贵 | 让值变化预览保持廉价，在手势结束时提交昂贵工作 |
| Set 没有触发 OnCommit | setter 不是用户手势；需要时显式调用领域操作 |
| 列表刷新后玩家选择发生变化 | 使用稳定的 UserId 值，而不是列表索引或可变的显示名 |
| 输入时/在对话框中按键绑定不触发 | 输入捕获保护编辑和浮层；请选择其他交互 |
| 按键绑定与窗口切换键冲突 | 窗口切换键是保留的；通过 CreateWindow 选项禁用/更改它 |
| 两个脚本互相替换对方的窗口 | 为不同应用提供不同的稳定窗口 Id |
| 两个控件跨标签页发生冲突 | 控件 Id 在整个窗口内唯一 |
| 紧凑窗口上侧边栏资料消失 | 布局优先保证控件空间；横向标签页仍然可用 |
| Icon 选项没有任何效果 | 导航和操作是纯文字的；旧的 Icon 选项会被忽略 |
| Frame Parent 的行为不像停靠 | Parent 是用于自有的 ScreenGui；不支持任意 Frame 嵌入 |
| 已关闭的视图仍在处理模型事件 | 把返回的取消订阅/连接注册到 window:Give |
| 最小化后工作仍在继续 | 最小化会保留应用；为领域工作使用显式的 Stop 命令 |
| 延迟 task 更新了已被替换的窗口 | 使用 window.Alive 和代次令牌做守护；拥有/注销计划 task |
| 窗口导入后完整 UAI 设置没有变化 | 窗口配置和 UAI 客户端配置是两套独立系统 |
| 自定义发送按钮一直处于禁用状态 | 在 sessions.listChanged/onDone 之后刷新真实的 session.busy |
| 较大的回复使面板变慢 | 约束响应视图并合并更新；为历史使用合适的共享转录组件 |

当需求超出公开 API 时，请阅读实现并添加可复用的能力。
不要通过编辑私有 Frame 或把第二份 UI 库复制进脚本来解决 API 缺口。

## 扩展

本节面向仓库贡献者。消费端脚本使用公开
API；新的可复用控件和生命周期能力属于 `ui-lib/src`。

### 源码地图

| 模块 | 职责 |
| --- | --- |
| `library.lua` | 公开 UI 对象、窗口查找、配置方法组合 |
| `window.lua` | 窗口创建、输入、安全布局、可见性、生命周期 |
| `containers.lua` | 标签页、分区、控件构造函数暴露、搜索/布局 |
| `controls.lua` | 基础控件契约和通用控件实现 |
| `choice.lua` | 基于选择的控件和选择器 |
| `color.lua` | 颜色选择器行为 |
| `config.lua` | 类型化状态序列化、校验、导入/导出、文件配置 |
| `appearance.lua` | 自动设置、静默偏好反映、调色板编辑 |
| `core.lua` | 资源作用域、实例辅助、布局/测量、回调 |
| `theme.lua` | 共享视觉令牌和主题值 |
| `motion.lua` | 自有可逆过渡和减弱动效处理 |
| `overlays.lua` | 对话框、通知和浮层所有权 |
| `profile.lua` | 本地玩家资料和体验信息 |

`ui-lib/loader.lua` 创建独立的工厂环境。每个源
模块返回 `function(env) ... end`，并使用该环境的记忆化
加载器。这些模块不使用客户端 `src/ui` 模块环境。

### 作为共享能力添加控件

1. 定义消费端 API：构造函数、有效值、方法、回调、
   默认值、禁用/隐藏状态以及持久化行为。
2. 使用共享的基础/所有权辅助实现控件。保持稳定
   值独立于可见标签，并在更改状态之前进行校验。
3. 把它接入控件分发和
   `containers.lua` 中的构造函数暴露。没有消费端的 `UI:RegisterControl` 钩子。
4. 如果它有状态，定义配置序列化/校验。无效
   导入不得部分应用，并且导入默认保持静默。
5. 处理指针、触摸、键盘/手柄选择、浮层关闭、隐藏、
   替换和销毁。使用共享的动效/主题原语。
   使用 `core.node(..., colors)` 或 `core.bind` 绑定调色板属性；使用
   令牌名称或当前主题的函数来处理依赖状态的颜色。
   不要在回调中捕获已解析的调色板。字面颜色保留给
   颜色选择器样本和光谱渐变之类的内容。
6. 在 Controls 中记录该 API，并添加一个聚焦的用法示例。为其不同的
   状态/输入/生命周期情形添加有意义的行为覆盖。
7. 在构建或测试之前，完成并人工审查所有源码、文档、示例和测试改动。

对于虚拟化或停靠这类能力，请先定义其生命周期、
测量、无障碍和数据所有权契约。一个恰好
适合某个脚本的控件还不是稳定的共享接口。在设计
中保留永久署名和文字导航。

### 保持智能体参考可被发现

此文件中的每个 H2 小节都会成为生成的
`runtime/ui_library_docs` 模块中小写下划线键。`src/tools/gui.lua` 在
`ui_library_docs` schema 中声明这些键。每当在此处添加小节时，请在那里添加新的键。
不要直接编辑 `src/runtime/ui_library_docs.lua`。

`test/ui_library_agent.lua` 检查工具声明的分节是否与
生成的指南匹配，以及分页是否能精确重建每个小节。该
工具返回有界的 UTF-8 页面；智能体必须跟随 `nextOffset` 直到它
不存在，才能完整读取一个长小节。

## 开发

库源码与 `src/ui` 分离，后者仍然是既有的客户端 UI。
`ui-lib/src` 中的模块是 `return function(env) ... end` 工厂，使用
仓库的 Lua 5.1 兼容 Luau 方言。把视觉令牌放在 `theme.lua` 中。
在此处添加可复用控件；消费端脚本只应声明控件并
实现应用行为。

在自动化测试之前人工审查每一处改动，包括测试代码。
在审查构建输入之后，先生成并检查输出，再运行
测试套件。在重测之前人工审查每一次后续修复。

```bash
node tools/build_ui_lib.js
luajit tools/bundle.lua --native
node tools/build_site.js
# Manually inspect the generated bundles, manifests, guide, and catalog here.
luajit test/ui_library.lua
luajit test/ui_library_theme.lua
luajit test/ui_library_mobile.lua
luajit test/ui_library_appearance.lua
luajit test/ui_library_agent.lua
luajit test/embedding_examples.lua
node tools/build_ui_lib.js --check
luajit tools/bundle.lua --native --check
node tools/build_site.js --check
```

这些是针对指南/库/示例的聚焦检查。对于更广泛的客户端/运行时
变更，请遵循[原生验证流程](CODE_WORKSPACE_TESTING.md)，
并使用 `node tools/test_native.js`。它的 `--skip-images` 标志会在图像验证
超出范围时省略专门的
图像输入套件；验证报告会列出该省略项。桥接场景
运行器接受相同的标志，并抑制截图和图像专用套件。

UI 构建会产出 `dist/uai-ui.lua`、一个 SHA-256 清单，以及
由本指南生成的 `src/runtime/ui_library_docs.lua`。生成的指南
为离线 `ui_library_docs` 工具提供支持，因此智能体可以在无
网络访问的情况下读取确切的 API。绝不要手工编辑生成的产物。在更改指南或智能体指令后，
重新构建主客户端。

行为测试使用仓库的
Roblox mock 执行实际分发的库，涵盖鼠标/触摸所有权、值校验、配置往返、
回调失败、重放和清理。原生 Roblox 渲染、操作系统键盘
行为和实际游戏手柄聚焦仍需要客户端内验证。
