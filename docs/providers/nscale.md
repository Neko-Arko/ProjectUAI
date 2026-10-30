# Nscale

使用 **Providers > Add a provider > Nscale**。无服务器推理的基础地址为 `https://inference.api.nscale.com/v1`；保留 Chat Completions 与 Bearer 认证。

1. 创建一个 Nscale 账户，配置计费并添加额度。
2. 在仪表盘中创建一个 API 密钥，并将其粘贴到 UAI。
3. 获取模型并选择一个确切的无服务器模型 ID。若你的账户无法列出模型，请使用仪表盘推理示例中记载的确切 ID。
4. 保存，并在发送更长对话前先验证一条简短请求。

Nscale 可能向符合条件的账户提供促销额度。本预设归入付费组，因为促销资格并不是有保证的免费额度。用量按所选模型的 token 定价与账户限额计算。

文档记载的推理服务器为 `inference.api.nscale.com`；chat 端点为 `/v1/chat/completions`。请保留该推理 URL，而不要使用仪表盘或基础设施管理 API 的 URL。目录请求需要认证。

Chat Completions 约定接受 OpenAI 风格的工具定义，但请选择能力支持你预期工具工作流的模型。列出模型时返回 401，需要检查密钥与认证方式。返回配额或资金相关响应，需要检查账户仪表盘；反复刷新模型不会补充额度。

官方来源：

- [推理快速开始](https://docs.nscale.com/docs/getting-started/quickstart)
- [Chat Completions 参考](https://docs.nscale.com/api-reference/inference/create-chat-completion)
