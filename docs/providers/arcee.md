# Arcee AI

使用 **Providers > Add a provider > Arcee AI**。该预设使用 `https://api.arcee.ai/api/v1`、Chat Completions 与 Bearer 认证。

1. 在 Arcee Platform 中创建一个 API 密钥，并确认你的账单余额。
2. 将该密钥粘贴到 UAI 并获取当前目录。
3. 从该提供商的列表中选择一个确切 ID 并保存。
4. 检查所选模型的工具支持，并在尝试长时间智能体运行之前先发送一条简短请求。

Arcee 公布的定价列出付费的 token 费率。某个名称相似的模型通过其他网关免费提供，并不意味着 Arcee 这条路由免费。除非 Arcee 自身的当前目录包含某个促销后缀，否则不要将来自 Kilo 或 OpenRouter 的该后缀复制到 Arcee 的模型 ID 中。

模型列表需要 API 密钥。若获取返回 401，请确认密钥与 Bearer 认证。若已列入列表的模型在推理时失败，请检查当前容量、你的账户余额以及确切模型 ID。目录中的可用性并不等于预留了推理容量。

托管模型的能力在不同路由之间可能不同。在决定是否发送图像或使用高级推理参数时，请以 Arcee 对所服务模型的描述为准。该预设把模型选择交给当前目录，而不内嵌某个可能在下一个 UAI 版本发布前就消失的模型。

官方来源：

- [平台快速开始](https://docs.arcee.ai/get-started/quick-start)
- [定价](https://docs.arcee.ai/get-started/pricing)
