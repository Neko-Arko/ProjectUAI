# 脚本项目

UAI 的代码工作区工具分组包含十个工具，用于从已保存的文件构建脚本。它们在执行器中运行，无需桌面服务。用户与智能体仍可使用现有的编辑器、文件工具与单文件执行。

这些工具提供词法源码映射、协同补丁、编译器反馈、受管理的行为测试与确定性打包。它们 **不** 包含 LSP、Luau 类型推断、Roblox API 类型定义或隔离的测试进程。

## 启动项目

使用提供给智能体的规范 Current 游戏文件路径。
文件工具、搜索、`check_luau`、`run_luau` 与项目工具都接受一次相同的 `files/...` 前缀。请原样保留返回的旧路径，即使其中包含真实的嵌套 `files/` 文件夹。新的自动游戏文件夹使用 ASCII 名称加 PlaceId；项目清单仍使用相对于其项目的路径。

以新的 `directory` 调用 `project_scaffold`，例如 `files/My Game (123)/Helper`。
它会暂存这些文件并返回 `patchId` 与清单路径：

```text
Helper/
  uai.project.json
  main.lua
  settings.lua
  tests/settings.lua
```

用 `project_patch_read` 读取拟议文件，然后把该 ID 作为 `patch_id` 传给 `project_patch_apply`。脚手架与读取不会写入或执行源码。此模板包含配置与一个通过的行为测试；它不会创建界面。新的脚本界面必须使用 Project UAI UI LIB 及其生命周期。

清单格式为：

```json
{
  "version": 1,
  "entry": "main",
  "modules": {
    "main": "main.lua",
    "settings": "settings.lua",
    "tests/settings": "tests/settings.lua"
  },
  "tests": ["tests/settings"]
}
```

模块 ID 使用字母、数字、下划线、连字符以及以斜杠分隔的段。路径是清单目录下确切的相对 `.lua` 或 `.luau` 路径。绝对路径、路径穿越、重复路径与大小写别名会被拒绝。没有隐式目录扫描、包安装或网络导入。

编写的模块返回一个值，并对另一个已声明的 ID 使用 `require("settings")`。每个模块都会收到本地的 `require` 与 `fixtures`。内置加载器会记忆化结果、保留 `false`、把 nil 返回值转为 `true`、检测活动的 require 循环，且不会回退到 Roblox 的全局 require。若已声明，动态字符串 ID 可在运行时解析；其依赖无法静态证明。依赖 ModuleScript 的 `script` 身份的源码必须显式适配。项目入口不会通过映射、分析或构建被执行。

## 工具

| 工具 | 参数与行为 |
| --- | --- |
| `project_scaffold` | `directory`：暂存四个起始文件；已存在的目标会被拒绝。 |
| `project_map` | `manifest`：读取已保存源码的哈希、函数/局部变量轮廓、字面量导入以及测试 ID。大型结果使用 `workspace_result_read`。 |
| `project_patch` | `operations`：暂存 1–20 个创建、替换或精确编辑。每个都指定 `path` 以及 `content` 或 `edits`。新文件需要 `create=true`；已有文件需要 `expected_hash`。 |
| `project_patch_read` | `patch_id`；可选 `path`、`section`（`before`、`after`、`diff`）、`offset`、`limit`。不给 path 时读取元数据。源码偏移是从 1 开始的字节；diff 偏移按行计数。 |
| `project_patch_apply` | `patch_id`：写入前复查每个文件，然后校验每次写入。拒绝绑定到目标且未保存的代码草稿。 |
| `project_patch_restore` | `patch_id`：有条件地恢复原始文件，并移除检查点创建的文件。因恢复可能删除文件，属高影响权限。 |
| `project_patch_discard` | `patch_id`：释放提案/检查点；文件保持不变。 |
| `script_analyze` | `path` 或 `manifest` 中恰好一个：宿主编译器诊断与源码哈希；项目还会检查字面量导入与循环。不执行。 |
| `script_test` | `manifest`；可选 `modules`（已声明的测试 ID）、`filter`（用例名称的大小写敏感字面子串）、JSON `fixtures` 与 `timeout`（1–60 秒，默认 10）。仅通过受管理引擎执行所选测试。 |
| `project_build` | `manifest`、以 `.lua` 结尾的 `output`；已有输出还需 `expected_hash`。检查并导出确定性 bundle、源码行位置、哈希与恢复检查点。 |

精确编辑包含 `old_text` 与 `new_text`。匹配必须唯一，且每次编辑都能看到前一次编辑的拟议结果。空的替换文本会删除匹配区间。整文件删除与重命名仍是独立的既有文件操作。哈希用于标识内容以检测冲突；它们不是安全摘要。提案一旦暂存，应用时会校验完整的原始字节。

路径可显式以 `files/` 或 `UAI/files/` 开头。项目写入限于文件区域；它们无法访问粘贴板或应用状态。映射/构建读取已保存的文件，而非未保存的编辑器草稿。干净的已打开编辑器视图不会被文件写入静默替换；其既有的保存冲突保护仍然有效。编辑活动的共享文档时请使用 `code_*` 工具。

## 审查、构建与测试

先审查编写的改动。用 `script_analyze` 查找语法错误与未解析的字面量导入。对于多文件代码，使用 `project_build`，检查其生成的源码，然后运行相关的 `script_test` 用例。重建与重测之前先审查任何修复。构建永远不会启动脚本。

用 `modules` 与 `filter` 检查某项改动所影响的行为。例如，
`{"manifest":"files/Helper/uai.project.json","modules":["tests/settings"],"filter":"defaults"}`
会运行 settings 测试模块中匹配的用例。未知或重复的测试 ID 会被拒绝。结果列出选中的模块与跳过的用例数；过滤器未匹配任何用例会显式失败。通过所选用例仅能确立该选择的覆盖范围。需要整个已声明套件时，请同时省略两个选择器。

例如，测试模块可以返回：

```lua
local settings = require("settings")
return {
	defaults = function(t, fixtures)
		t.equal(settings.name, "My script")
		t.truthy(settings.enabled)
		t.equal(fixtures.expectedName, settings.name)
	end,
}
```

对于此示例，向 `script_test` 传入 `fixtures = { "expectedName": "My script" }`。测试使用点调用：`t.equal(actual, expected, message?)`、
`t.truthy(value, message?)` 与 `t.raises(callback, literalErrorSubstring?)`。
相等性使用 Lua 的相等判断；它不是深度表比较。

测试模块会被加载以进行发现，并在每个排序后的用例前重新加载，伴随全新的项目模块缓存与复制后的 fixtures。请保持发现与模块初始化无副作用。测试执行共用原生客户端，可能产生真实的游戏效果。它使用与 `run_luau` 相同的高影响权限、协作式取消、截止时间与任务归属；它 **不是安全沙箱**。原生调用与动态加载的代码仍带有该引擎的限制。失败/超时的运行不得盲目重试。

结果报告通过/失败的用例、错误以及可用的堆栈跟踪。Bundle 的行位置会把生成的行映射回原始文件。执行期间的源码改动会使「当前已保存项目已通过」的结论失效。模拟 fixtures 无法确立原生 Roblox 输入、渲染或服务端行为。

分析使用当前宿主编译器。若没有可用编译器，结果会显式说明 `compilerAvailable=false`；构建与测试需要编译。轮廓会跳过注释与字符串，但只是词法提示，没有作用域推断。插值字符串表达式是不透明的，被遮蔽的 `require` 可能导致错误的依赖报告，字面量依赖循环会被保守拒绝。轮廓的列与偏移按字节计数。不声称具备类型/API 校验。

版本 3 对相同源码字节复用词法轮廓，并对未变的路径/源码/编译器组合复用成功或失败的语法结果。每次项目操作仍会读取已保存的文件，依赖检查针对当前清单运行。更换编译器会使其语法缓存失效。结果报告 `compiledModules` 与 `reusedModules`；被取消的分析会设置 `complete=false`。缓存的轮廓在使用前会复制，因此一个请求无法改变另一个请求的证据。不保留也不执行任何编译后的闭包。

轮廓保留允许 128 个条目，计入源码与轮廓字段的 4 MiB 预算。项目语法保留允许 128 个条目与 2 MiB 源码。最近最少使用的条目会被逐出，卸载会释放两个缓存。

## 边界与恢复

项目允许 64 个模块、16 个测试模块、每份源码 256,000 个 UTF-8 字节以及总计 1 MiB 源码。清单与 fixture JSON 各上限 32,000 字节。生成的可编辑 bundle 上限 256,000 字节。检视上限为 50,000 token，每个文件各 256 个符号/导入；被省略的轮廓会被报告。符号名上限 160 字节，并带截断标志。分析保留 512 条诊断并报告省略计数，同时保留错误/警告总数。测试每次运行允许 100 个用例。测试代码既不能控制权限，也不能控制执行截止时间。

内存中最多保留八个提案/检查点，每个提案 2 MiB 的修改前后源码，总计 8 MiB。它们属于原始对话，并在十分钟后或卸载时过期。若需依赖更长期的备份，请显式保存重要的原始源码；这些检查点不会在重新加载后存续。

每个目标在首次写入前检查一次，并在其自身写入前立即再次检查。写入会被回读。执行器文件 API 不提供可移植的原子多文件提交：取消或宿主调用失败可能留下部分结果。继续之前请检查返回状态与原始/拟议源码。恢复会检查每个当前文件，并拒绝外部修改或未知的部分字节。它绝不猜测那些字节是否属于另一个写入者，也绝不声称能撤销游戏效果。项目操作会针对其他项目操作锁定其目标；无关的宿主/文件写入者通过字节检查被检测到，而不是被执行器文件系统锁定排除。
