# 提供商设置指南

打开 **Providers > Add a provider**，选择对应的预设，输入你的密钥，获取模型，
选定准确的 ID 并保存。预设会填充 URL、协议与认证方式。它不会购买额度，
也不会确认账户访问权。

| 预设 | 访问与设置 |
| --- | --- |
| [Vercel AI Gateway](vercel.md) | 符合条件的免费层模型每月额度；付费目录覆盖更广 |
| [Perplexity Orchestrator](perplexity.md) | 已充值的 API 账户，独立于其他 Perplexity API |
| [FriendliAI Model APIs](friendli.md) | 个人 API 密钥与团队余额；共享的无服务器端点 |
| [Venice](venice.md) | Inference Only 密钥、已充值额度以及按密钥的支出上限 |
| [Nscale](nscale.md) | 用于无服务器推断的 API 密钥与额度 |
| [Arcee AI](arcee.md) | 平台密钥、当前托管的 ID 与公布的令牌费率 |
| [AI/ML API](aimlapi.md) | 付费 API 访问；文档所述的免费层已暂停 |

其他连接方式请参见 [AgentRouter](../AGENTROUTER.md)、
[Kilo 配额恢复](../KILO_TUNNEL.md)、[Cline 桌面端设置](../CLINE_TUNNEL.md)
以及 [提供商兼容性约定](../PROVIDER_COMPATIBILITY.md)。

这些指南所用的公开文档与免认证模型目录已于 2026 年 10 月 25 日核对。
未实际执行付费推断。模型发现成功仅证明该目录可被读取；并不证明密钥有效、
已充值、对每个模型都已获授权或未超出其上限。

模型菜单支持多词搜索。当搜索没有匹配结果时，获取与手动输入操作仍然可用。
在这些提供商文档化的路由上，UAI 会隐藏明确不兼容的目录类型；手动输入的 ID
仍然可用。为智能体工作选择支持工具调用的模型。某个条目即便兼容聊天，
也可能缺少工具、图像输入或特定的推理设置。
