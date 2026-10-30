# FriendliAI Model APIs

使用 **Providers > Add a provider > FriendliAI Model APIs**。该预设使用 `https://api.friendli.ai/serverless/v1`、Chat Completions 与 Bearer 认证。

1. 打开 Friendli Suite，并选择将承担用量的团队。
2. 创建一个 Personal API 密钥，并检查该团队的预付余额。
3. 将密钥粘贴到 UAI，获取模型并选择确切的服务 ID。
4. 保存，并使用在其文档化能力中启用了工具调用的模型发送一条简短请求。

这里使用的是共享的 Model APIs 服务。Dedicated Endpoint 有其自身的部署与计费配置；未按 Dedicated Endpoint 文档操作时，不应将其部署 ID 与 URL 复制到共享预设中。

目录用 `mode: chat` 标记 chat 条目。在此精确路由上，UAI 会排除明确标注为不同 mode 的条目。该提供商还公布输入/输出模态与 `functionality.tool_call`；仅具备 chat 兼容性并不保证支持图像或工具调用。并行工具调用取决于模型。

目录可能是公开的，因此成功获取并不验证你的密钥或余额。若推理请求失败，请检查密钥所属团队、余额与所选模型。若某项所需功能被拒绝，请选择声明支持该功能的模型，而不是为整个提供商更改协议。

官方来源：

- [Model APIs 快速开始](https://friendli.ai/docs/guides/model-apis/quickstart)
- [OpenAI 兼容性](https://friendli.ai/docs/guides/openai-compatibility)
- [工具调用](https://friendli.ai/docs/guides/tool-calling)
