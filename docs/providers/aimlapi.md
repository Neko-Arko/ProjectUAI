# AI/ML API

使用 **Providers > Add a provider > AI/ML API**。保留 `https://api.aimlapi.com/v1`、Chat Completions 与 Bearer 认证。

1. 创建一个 AI/ML API 密钥，并选择付费计费方案。
2. 将密钥粘贴到 UAI 并获取模型。
3. 在目录中搜索文档说明使用 Chat Completions 的模型，选择其确切 ID，然后保存。为智能体任务检查工具支持。
4. 发送一条简短请求，并在提供商仪表盘中确认用量。

该提供商的免费层文档目前说明免费层已暂停。因此本预设归入付费组。拥有 API 密钥或可访问公开模型列表，本身并不授予免费推理。

完整目录包括 chat、Messages、Responses、embeddings、audio、image、video 与 batch API。在此精确的 Chat Completions 预设上，UAI 只接受声明 `type` 为 `openai/chat-completions` 的行，并隐藏明确标注的其他类型。为 `anthropic/messages` 或 `openai/responses/submit` 设计的 ID，无法通过从列表中选择而变得 chat 兼容。手动输入 ID 在提供商变更时仍然可用，但其 API 兼容性由你自行负责。

公开目录访问成功并不确认认证或资金正常。若请求失败，请检查你的密钥、套餐、剩余余额以及模型的 API 类型。搜索使用普通词语，并且即使在无模型匹配时也保留刷新与手动输入操作。

官方来源：

- [文本模型 API](https://docs.aimlapi.com/api-references/text-models-llm)
- [完整模型列表](https://docs.aimlapi.com/api-references/service-endpoints/complete-model-list)
- [免费层状态](https://docs.aimlapi.com/faq/free-tier)
