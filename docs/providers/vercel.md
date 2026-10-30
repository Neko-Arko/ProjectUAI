# Vercel AI Gateway

使用 **Providers > Add a provider > Vercel AI Gateway**。该预设使用 `https://ai-gateway.vercel.sh/v1`、Chat Completions 与 Bearer 认证。

1. 在仪表盘中为你打算计费的 Vercel 团队打开 AI Gateway。
2. 创建一个 AI Gateway API 密钥，并将其粘贴到 UAI 的 API 密钥字段。
3. 获取模型，搜索确切的 provider/model ID，选中并保存。
4. 在发送请求前，确认所选模型包含在你团队当前档位中。为智能体任务使用支持工具的模型。

文档记载的免费层为部分模型提供每月 $5 额度，并带有更低的单模型速率限制。公开目录也包含付费模型。购买额度会使账户转为付费档，并结束每月免费额度授予。目录价格为零并不证明你的账户有访问权限。

UAI 保留文档记载 `type` 为 `language` 的目录条目；embedding、image、speech 及其他明确类型使用不同的 API，因而被省略。流式传输与工具调用使用 OpenAI 兼容的 Chat Completions 路由。模型支持的参数仍然决定可以请求哪些功能。

若发现成功但推理失败，请检查密钥的团队归属、Free Tier 模型列表、剩余额度与模型的速率限制。更改密钥或团队后请刷新模型。UAI 绝不会仅因为你添加了此预设就替你选择付费模型。

官方来源：

- [Chat Completions API](https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions)
- [定价与免费层](https://vercel.com/docs/ai-gateway/pricing)
