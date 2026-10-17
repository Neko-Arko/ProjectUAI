-- Built-in provider presets.
--
-- A preset is a base URL and an auth style, nothing more. It deliberately does not
-- carry a model list: the only authority on which models an endpoint serves is the
-- endpoint, so models come from GET /v1/models or from the user typing one in. A
-- hardcoded list goes stale, and offering a model the provider does not have wastes
-- a turn on a 404 that looks like a bug. Project UAI Free is the managed exception:
-- its provider-supported `auto` router was verified with discovery and tool calls.
return function(env)
	local M = {}

	-- authStyle: bearer | x-api-key | x-goog-api-key | api-key | both | none
	--   both sends Authorization and x-api-key together, which is what several
	--   self-hosted relays expect and what the reference client did unconditionally.
	-- Reachability is derived from the configured URL, including custom endpoints.
	-- RequestAsync refuses loopback and private addresses.
	M.presets = {
		{
			id = "hcnsec",
			label = "Project UAI Free",
			baseUrl = "https://api.hcnsec.cn/v1",
			authStyle = "bearer",
			keyHint = "Free access is included; your own HCNSEC key is optional",
			docs = "https://discord.gg/9xYyyYuKap",
			free = true,
			defaultModel = "auto",
			-- Keep included access available after the recommended providers.
			featured = true,
			featuredOrder = 4,
			note = "Free AI for the Project UAI community, powered by HCNSEC. No account, payment or personal API key is needed. Thank you for your continued use and support of Project UAI. Auto measures tool-capable models in the background and prefers a verified route below ten seconds. Real response times vary with your prompt and shared capacity. More free providers may become available soon. Join us for updates and help: https://discord.gg/9xYyyYuKap",
			noteHighlight = "No account, payment or personal API key is needed.",
		},
		{
			id = "agentrouter",
			label = "AgentRouter",
			-- The normaliser adds /v1; the Messages adapter appends /messages.
			baseUrl = "https://agentrouter.org",
			authStyle = "x-api-key",
			keyHint = "AgentRouter API key",
			docs = "https://agentrouter.org/register?aff=4pqF",
			api = "anthropic",
			headers = { ["anthropic-version"] = "2023-06-01" },
			featured = true,
			featuredOrder = 1,
			requiresClaude = true,
			note = "An Anthropic Messages gateway that routes to Claude, DeepSeek and more, and requires the Claude Code identity on every request -- which this client always sends here. Registration needs a GitHub account at least 1 year old. Recommended model: deepseek-v4-flash.",
			noteHighlight = "a GitHub account at least 1 year old",
		},
		{
			id = "openai",
			label = "OpenAI",
			baseUrl = "https://api.openai.com/v1",
			authStyle = "bearer",
			keyHint = "sk-...",
			docs = "https://platform.openai.com/api-keys",
		},
		{
			id = "openrouter",
			label = "OpenRouter",
			baseUrl = "https://openrouter.ai/api/v1",
			authStyle = "bearer",
			keyHint = "sk-or-...",
			docs = "https://openrouter.ai/keys",
			featured = true,
			featuredOrder = 3,
			-- OpenRouter reads both of these for attribution, and sending only one of
			-- them is a shape no real client produces.
			headers = {
				["X-Title"] = "Project UAI",
				["X-OpenRouter-Title"] = "Project UAI",
				["HTTP-Referer"] = "https://github.com/Project-Ptolemy/ProjectUAI",
				["X-OpenRouter-Categories"] = "game,cli-agent",
			},
			claudeUa = false,
			note = "Lists several hundred models. Fetch them and pick, or type the id shown on openrouter.ai.",
		},
		{
			id = "zen",
			label = "OpenCode Zen",
			baseUrl = "https://opencode.ai/zen/v1",
			authStyle = "bearer",
			keyHint = "API key from opencode.ai/zen",
			docs = "https://opencode.ai/zen",
			-- Keep the existing OpenCode request compatibility headers, scoped to the
			-- official host, without mixing in the Claude Code identity.
			claudeUa = false,
			-- Desktop retains direct request compatibility; the installed CLI is an
			-- additional route through the desktop bridge, never a bundled binary.
			featured = true,
			featuredOrder = 2,
			note = "Desktop supports the direct OpenCode workaround without a bridge. Project UAI Bridge also supports a separately installed OpenCode CLI for free models; models fetched from the connected CLI need no personal key. Mobile is unsupported for OpenCode free models, including the Android companion. The retired OpenCode proxy cannot restore mobile access. Direct and paid Zen API access use your own key. Help and updates: https://discord.gg/9xYyyYuKap",
			noteHighlight = "Mobile is unsupported for OpenCode free models",
		},
		{
			id = "opencode-go",
			label = "OpenCode Go",
			baseUrl = "https://opencode.ai/inference/go/v1",
			authStyle = "bearer",
			keyHint = "API key from the workspace with your active OpenCode Go subscription",
			docs = "https://opencode.ai/docs/go/",
			claudeUa = false,
			featured = true,
			featuredOrder = 5,
			note = "Paid OpenCode Go access uses your own subscribed workspace key and the separate Go endpoint. Review the workspace Privacy region setting if Go requires Global regions. Fetch models from Go; DeepSeek uses Chat, GPT/Grok/Muse use Responses, Claude/Minimax/Qwen use Messages, and Gemini uses its native API automatically. Go uses keyed requests; the desktop-only free CLI catalog is separate. A successful model list does not verify your subscription.",
		},
		{
			id = "azure-foundry",
			label = "Azure AI Foundry",
			-- The v1 surface rather than the per-deployment preview path: it speaks
			-- /chat/completions and /models, so this client needs no adapter of its own.
			-- The resource name is part of the URL the user has to edit.
			baseUrl = "https://YOUR-RESOURCE.openai.azure.com/openai/v1",
			authStyle = "api-key",
			docs = "https://learn.microsoft.com/azure/ai-foundry/",
			note = "The v1 endpoint of an Azure AI Foundry resource. Replace YOUR-RESOURCE, then fetch models or type a deployment name.",
		},
		{
			id = "anthropic-messages",
			label = "Anthropic (Messages API)",
			baseUrl = "https://api.anthropic.com/v1",
			authStyle = "x-api-key",
			keyHint = "sk-ant-...",
			docs = "https://console.anthropic.com/settings/keys",
			-- The native API rather than the compatibility shim: thinking blocks and
			-- tool_use content survive the round trip, and nothing is being translated
			-- twice on the way through someone else's adapter.
			api = "anthropic",
			note = "Anthropic's own Messages API. Preferred over the OpenAI-compatible route: reasoning and tool calls arrive in their real shape.",
		},
		{
			id = "anthropic",
			label = "Anthropic (OpenAI-compatible)",
			baseUrl = "https://api.anthropic.com/v1",
			authStyle = "x-api-key",
			keyHint = "sk-ant-...",
			docs = "https://console.anthropic.com/settings/keys",
			-- The compatibility route wants the version header; it is harmless
			-- elsewhere but only defaulted on here.
			headers = { ["anthropic-version"] = "2023-06-01" },
			note = "Anthropic's OpenAI-compatible endpoint. Tool calling works; some sampling fields are ignored.",
		},
		{
			id = "google",
			label = "Google Gemini",
			baseUrl = "https://generativelanguage.googleapis.com/v1beta",
			authStyle = "x-goog-api-key",
			api = "gemini",
			keyHint = "AIza...",
			docs = "https://aistudio.google.com/apikey",
			note = "Gemini's native generateContent API supports text, tool calls, image input through the bridge, reasoning summaries and signed multi-step tool replay. Fetch models with your Google AI Studio key. Existing OpenAI-compatible connections remain supported.",
		},
		{
			id = "groq",
			label = "Groq",
			baseUrl = "https://api.groq.com/openai/v1",
			authStyle = "bearer",
			keyHint = "gsk_...",
			docs = "https://console.groq.com/keys",
		},
		{
			id = "deepseek",
			label = "DeepSeek",
			baseUrl = "https://api.deepseek.com/v1",
			authStyle = "bearer",
			keyHint = "sk-...",
			docs = "https://platform.deepseek.com/api_keys",
			note = "Reasoning models here stream their chain of thought as reasoning_content, which the transcript shows separately.",
		},
		{
			id = "together",
			label = "Together AI",
			baseUrl = "https://api.together.xyz/v1",
			authStyle = "bearer",
			docs = "https://api.together.ai/settings/api-keys",
		},
		{
			id = "mistral",
			label = "Mistral",
			baseUrl = "https://api.mistral.ai/v1",
			authStyle = "bearer",
			docs = "https://console.mistral.ai/api-keys",
		},
		{
			id = "xai",
			label = "xAI",
			baseUrl = "https://api.x.ai/v1",
			authStyle = "bearer",
			keyHint = "xai-...",
			docs = "https://console.x.ai",
		},
		{
			id = "fireworks",
			label = "Fireworks",
			baseUrl = "https://api.fireworks.ai/inference/v1",
			authStyle = "bearer",
			docs = "https://fireworks.ai/api-keys",
		},
		{
			id = "cerebras",
			label = "Cerebras",
			baseUrl = "https://api.cerebras.ai/v1",
			authStyle = "bearer",
			docs = "https://cloud.cerebras.ai",
		},
		{
			id = "azure",
			label = "Azure OpenAI",
			baseUrl = "https://YOUR-RESOURCE.openai.azure.com/openai/deployments/YOUR-DEPLOYMENT",
			authStyle = "api-key",
			docs = "https://learn.microsoft.com/azure/ai-services/openai/",
			query = { ["api-version"] = "2024-10-21" },
			note = "The base URL must include the deployment path. Azure takes the model from the deployment, so the model field is not sent.",
		},
		{
			id = "ollama",
			label = "Ollama (local)",
			baseUrl = "http://127.0.0.1:11434/v1",
			authStyle = "none",
			claudeUa = false,
			docs = "https://docs.ollama.com/api/openai-compatibility",
			note = "Uses Ollama's OpenAI-compatible /v1 API, not its native /api/chat route. Local models need no key. Tools depend on the selected model; local access needs executor HTTP.",
		},
		{
			id = "lmstudio",
			label = "LM Studio (local)",
			baseUrl = "http://127.0.0.1:1234/v1",
			authStyle = "none",
			claudeUa = false,
			docs = "https://lmstudio.ai/docs/developer/openai-compat",
			note = "Start the LM Studio server, then fetch models. If server authentication is enabled, select Bearer and enter its token. Tools depend on the model and chat template.",
		},
		{
			id = "vllm",
			label = "vLLM / self-hosted",
			baseUrl = "http://127.0.0.1:8000/v1",
			authStyle = "none",
			claudeUa = false,
			docs = "https://docs.vllm.ai/en/latest/serving/online_serving/",
			note = "No key by default; select Bearer if the server uses --api-key. Automatic tools need the server's tool-call parser, chat template and enable-auto-tool-choice settings.",
		},
		{
			id = "llamacpp",
			label = "llama.cpp (local)",
			baseUrl = "http://127.0.0.1:8080/v1",
			authStyle = "none",
			claudeUa = false,
			docs = "https://github.com/ggml-org/llama.cpp/tree/master/tools/server",
			note = "Use llama-server's /v1 API. Select Bearer if --api-key is set. Tool calling needs a compatible model and chat template, often with --jinja.",
		},
		{
			id = "sglang",
			label = "SGLang / self-hosted",
			baseUrl = "http://127.0.0.1:30000/v1",
			authStyle = "none",
			claudeUa = false,
			docs = "https://docs.sglang.io/docs/basic_usage/openai_api_completions.md",
			note = "Use the server's OpenAI-compatible API. Select Bearer when authentication is configured. Tool support depends on the model, template and server tool-call parser.",
		},
		{
			id = "custom",
			label = "Custom endpoint",
			baseUrl = "",
			authStyle = "bearer",
			note = "An endpoint implementing Chat Completions or Anthropic Messages. Choose its protocol and auth style; enter a model id if discovery is unavailable.",
		},
	}

	function M.get(id)
		for _, preset in ipairs(M.presets) do
			if preset.id == id then return preset end
		end
		return nil
	end

	function M.ids()
		local out = {}
		for _, preset in ipairs(M.presets) do out[#out + 1] = preset.id end
		return out
	end

	return M
end
