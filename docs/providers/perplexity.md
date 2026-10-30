# Perplexity Orchestrator

使用 **Providers > Add a provider > Perplexity Orchestrator**。保留基础 URL `https://api.perplexity.ai/orchestrator/v1`、Chat Completions 与 Bearer 认证。此目录与 API 需要 `orchestrator` 路径。

1. 创建一个 Perplexity API 密钥，并确认其 API 账户有额度。
2. 将密钥粘贴到预设中，然后获取模型。
3. 从 Orchestrator 目录中选择一个确切 ID 并保存。
4. 先发一条简短请求，然后再启用更长的工具工作流。

该路由通过标准 Chat Completions 接口提供开放权重 chat 模型。Perplexity 的 Agent、Search 与旧版 Sonar API 有各自独立的路由与请求约定。来自上述任一 API 的模型 ID 不能假定在 Orchestrator 上可用。Perplexity 网页应用订阅并不建立 API 额度可用性。

模型目录需要认证。获取时返回 401 通常意味着密钥缺失或被拒绝；请检查 API 仪表盘与 Bearer 认证方式。若已列入列表的模型无法运行，请检查账户余额与当前模型可用性。刷新目录并不能测试推理容量。

在为 UAI 的智能体选择模型时，请使用模型文档记载的工具支持。该预设不会把 Perplexity 独立的托管网页搜索工具添加到 UAI。

官方来源：

- [Orchestrator 快速开始](https://docs.perplexity.ai/docs/router/quickstart)
- [Orchestrator 模型](https://docs.perplexity.ai/docs/router/models)
