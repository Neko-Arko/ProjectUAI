# Project UAI 中的 AgentRouter

在 **Providers** 中添加 **AgentRouter**，粘贴你的 AgentRouter 密钥，然后获取模型。
请使用为你的账户返回的准确 ID。模型可用性与配额可能变化；提供商库不会添加
固定的宣传模型列表。

在 AgentRouter 文档化的路由上，UAI 对 GPT 模型使用原生 **Responses**。
已保存的 AgentRouter 连接无需更改其 API 选择器即可继续工作。其他模型保留
所选的协议，包括用于 Claude 的 Anthropic Messages。这遵循 AgentRouter 的
[Codex 指南](https://agentrouter.org/docs/codex.html) 与
[Claude 指南](https://agentrouter.org/docs/claude-code.html)。

受支持的 HTTPS 基址为 `https://agentrouter.org/v1`、
`https://api.agentrouter.org/v1`，以及文档化的备用地址
`https://ps.air-outer.com/v1`。UAI 现有的已授权 AgentRouter 代理路由
同样保留原生 Responses。自定义主机、非标准端口与无关路径各自保留其协议设置。

## 工具使用与速度

GPT 请求直接发往 `/v1/responses`，避免一次被拒绝的 Chat Completions 请求
和一份未被使用的重复载荷。所选的推理强度会被显式发送；**Low** 倾向于更短的
推理工作。**Provider default** 有意省略强度设置。AgentRouter 可能选择更高的
默认值：10 月 25 日的实测探测在省略强度时报告为 `max`。

GPT-6.1 Sol 与 GPT-6 Astra 在模型选择器中提供 Low、Medium、High、Xhigh 与 Max，
与其官方 [模型参考](https://developers.openai.com/api/docs/guides/reasoning) 一致。
GPT-6.1 Sol 不支持 None 或 Minimal；Minimal 请求会使用 Low。模型强度的变更
影响推理工作，而不影响提供商的拥塞状况或配额。

UAI 发送其实际的工具声明，并保持可选参数为可选。大型目录继续使用有界的
工具目录辅助器。模型的工具调用会回到 Roblox 通常的校验、权限与执行流程。

每个原生请求都包含 UAI 完整的当前会话，包括与之匹配的工具调用与结果。
默认值为 `store: false`；UAI 不会跨请求复用不透明的加密推理条目或远程响应 ID。
这样可避免依赖共享网关中与某单个上游资源绑定的状态。显式的原始提供商/请求
参数覆盖仍然可用。

停止、超时与不完整的流仍为终止状态。先返回部分回复、随后出现配额错误的，
不视为成功应答，也不会被重放。只有显式的协议拒绝，或现有的已授权客户端拒绝，
才会触发其有界恢复路径。

## 2026 年 10 月 25 日的验证行为

所提供的测试账户在通过认证后，其目录列出了 `gpt-5.6-sol`、
`gpt-6-astra` 和 `gpt-6.1-sol`。目录中包含某模型，与推断成功或配额可用
是两回事。

- `gpt-6.1-sol` 使用 UAI 真实的 `instance_tree` 与 `instance_get` 声明完成了
  一批包含两个工具的调用，随后消费了模拟的 Roblox 结果并返回了预期的最终回复。
  首次测得的这对调用耗时约 2.69 秒和 2.86 秒。使用 UAI 新默认值（不含原始参数
  覆盖）的第二次检查同样通过，耗时 4.83 秒和 3.70 秒。两个工具都保留了可选参数，
  后续回复返回 `UAI_TOOLS_OK FixtureMap`。未执行任何 Roblox 世界写入。
- `gpt-5.6-sol` 未在探测的 45 秒期限内完成。在结果未知之后未对其进行重放。
- `gpt-6-astra` 返回了明确的区域令牌速率配额错误。该测试确立的是可见的失败行为，
  而非成功支持工具调用。

临时测试凭据被排除在已保存的提供商设置、源代码、发布产物与日志之外。
公开的源码说明与这些测量结果均为特定日期的观察，不构成可用性、速度或
不限量使用的保证。

离线回归测试覆盖路由边界、推理强度、可选模式、工具历史、有界拒绝、取消
与流失败：`test/agentrouter_protocol.lua` 与 `test/agentrouter_responses.lua`。
