# Venice

使用 **Providers > Add a provider > Venice**。保留 `https://api.venice.ai/api/v1`、Chat Completions 与 Bearer 认证。

1. 在 Venice 设置中创建一个 **Inference Only** API 密钥。UAI 需要推理访问权限，而非账户管理权限。
2. 确认该账户有可用的 DIEM、捆绑额度或美元余额。
3. 将密钥粘贴到 UAI，获取模型，选择一个确切 ID 并保存。
4. 检查模型在工具调用以及（如有需要）图像输入方面的能力。

Venice 默认从其公开模型目录返回文本模型。UAI 保留文档记载为 `type: text` 的条目，并省略明确标注的非文本类型。目录的能力字段与 offline 字段提供更多与模型相关的信息；列出某个 ID 并不保证它当前正在提供服务。

公开目录获取成功并不认证密钥。即使账户仍有余额，当单个密钥的支出限额用尽时，推理也可能返回 402。请同时检查账户资金与密钥自身的限额。若返回模型不可用的响应，请刷新列表并检查其当前状态。

Venice 特有的生成选项可能因模型而异。请从预设的默认参数开始，仅当所选模型的文档要求时才添加高级选项。

官方来源：

- [快速开始](https://docs.venice.ai/getting-started/quick-start)
- [创建 API 密钥](https://docs.venice.ai/guides/getting-started/generating-api-key)
- [模型目录](https://docs.venice.ai/api-reference/endpoint/models/list)
