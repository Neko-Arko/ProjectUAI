-- Native Gemini wire contracts. All network responses and credentials are synthetic.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Native Gemini provider")
local case, check = suite.case, suite.check
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end
local function fixture()
	local f = F.new(); f.tools({})
	f.registry = f.env.require("provider/registry")
	f.record = f.registry.blank("google")
	f.record.id, f.record.apiKey, f.record.model = "gemini-fixture", "fixture-google-key", "gemini-3.8-flash"
	f.adapter = f.env.require("provider/gemini")
	f.config = f.env.require("runtime/config")
	f.config.set("agent.retries", 1)
	function f.reply(parts, finish)
		return { candidates = { { content = { role = "model", parts = parts or { { text = "Gemini answer" } } }, finishReason = finish or "STOP" } },
			modelVersion = f.record.model, responseId = "fixture-response",
			usageMetadata = { promptTokenCount = 100, candidatesTokenCount = 20, thoughtsTokenCount = 5, cachedContentTokenCount = 40, totalTokenCount = 125 } }
	end
	function f.complete(request)
		return f.run(function() return f.env.require("provider/chat").complete(f.record, request or { messages = { { role = "user", content = "Hello" } }, stream = false }) end, 1)
	end
	function f.done() f.healthy(); f.close() end
	return f
end

case("native Google and Go route model endpoints with their own auth", function()
	local f = fixture(); local chat = f.env.require("provider/chat")
	check("new Google preset uses native Gemini", f.record.api == "gemini" and f.record.authStyle == "x-goog-api-key" and chat.styleOf(f.record) == "gemini")
	check("Google key uses its native header", chat.headers(f.record)["x-goog-api-key"] == "fixture-google-key" and chat.headers(f.record).Authorization == nil)
	f.record.baseUrl = "https://generativelanguage.googleapis.com/v1beta/models/old-model:streamGenerateContent?tenant=fixture&alt=sse"
	f.record.query = { tenant = "new" }
	check("full native endpoints normalize while preserving query overrides", f.adapter.endpoint(f.record, false)
		== "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?alt=json&tenant=new")
	check("native full URL remains recognizable", f.registry.isFullEndpoint(f.record.baseUrl))
	f.record.baseUrl, f.record.api, f.record.authStyle = "https://opencode.ai/inference/go/v1", "openai", "bearer"
	f.record.query = {}
	check("Go selects native Gemini without rewriting the saved API", chat.styleOf(f.record) == "gemini" and f.record.api == "openai")
	check("Go keeps bearer and identifiable session headers", chat.headers(f.record).Authorization == "Bearer fixture-google-key" and chat.headers(f.record)["User-Agent"] == "ProjectUAI/" .. f.env.info.version)
	check("Go completion stays on the Go route", chat.endpointOf(f.record) == "https://opencode.ai/inference/go/v1/models/gemini-3.8-flash:generateContent?alt=json")
	f.record.baseUrl = "https://generativelanguage.googleapis.com/v1beta/openai"
	check("existing OpenAI-compatible Google records remain OpenAI", chat.styleOf(f.record) == "openai")
	f.done()
end)

case("native bodies preserve schemas, system instructions, tools and image references", function()
	local f = fixture()
	local tools = { { type = "function", ["function"] = { name = "inspect_object", description = "Inspect", parameters = {
		type = "object", additionalProperties = false, properties = { path = { type = "string" }, count = { type = "integer", minimum = 1 } }, required = { "path" } } } } }
	local picture = { url = "uai-image://pic_fixture/" .. string.rep("b", 64), mediaType = "image/png" }
	local request = { messages = { { role = "system", content = "System one" }, { role = "system", content = "System two" },
		{ role = "user", content = "Inspect", images = { picture } } }, tools = tools,
		toolChoice = { type = "function", ["function"] = { name = "inspect_object" } }, outputCeiling = 256, maxTokens = 1000 }
	local body = f.adapter.buildBody(f.record, request)
	check("system instructions are outside conversation roles", #body.systemInstruction.parts == 2 and #body.contents == 1 and body.contents[1].role == "user")
	check("schema stays JSON Schema without lossy field conversion", body.tools[1].functionDeclarations[1].parametersJsonSchema.additionalProperties == false
		and body.tools[1].functionDeclarations[1].parametersJsonSchema.properties.count.minimum == 1)
	check("named tool choice uses native ANY and allowedFunctionNames", body.toolConfig.functionCallingConfig.mode == "ANY" and body.toolConfig.functionCallingConfig.allowedFunctionNames[1] == "inspect_object")
	check("image bytes remain bridge-owned", body.contents[1].parts[2].fileData.fileUri == picture.url and body.contents[1].parts[2].fileData.mimeType == "image/png")
	check("output ceiling remains enforced", body.generationConfig.maxOutputTokens == 256 and body.model == nil and body.stream == nil)
	check("caller-owned messages and schemas remain unchanged", request.messages[3].images[1] == picture and tools[1]["function"].parameters.additionalProperties == false)
	f.done()
end)

case("thought signatures and parallel function identities survive persistence and replay", function()
	local f = fixture(); local bodies = {}
	local parts = { { text = "Brief reasoning", thought = true, thoughtSignature = "signed-thought" },
		{ functionCall = { name = "read_a", args = { path = "a" }, id = "native-a" }, thoughtSignature = "signed-call" },
		{ functionCall = { name = "read_b", args = {} } } }
	f.h.http.handler = function(entry)
		bodies[#bodies + 1] = f.h.json.decode(entry.body)
		return { StatusCode = 200, Body = f.h.json.encode(f.reply(#bodies == 1 and parts or nil)) }
	end
	local first = assert(f.complete())
	check("native calls preserve explicit IDs and synthesize missing local IDs", #first.toolCalls == 2 and first.toolCalls[1].id == "native-a" and first.toolCalls[2].id ~= "native-a")
	check("reasoning is separate from visible text", first.reasoning == "Brief reasoning" and first.content == "")
	check("usage includes thought and cached token categories", first.usage.prompt_tokens == 100 and first.usage.completion_tokens == 25 and first.usage.prompt_tokens_details.cached_tokens == 40)
	local ctx = f.env.require("agent/context").new(); ctx.pushUser("Read both"); ctx.pushAssistant(first)
	ctx.pushToolResult(first.toolCalls[1].id, "read_a", "a result"); ctx.pushToolResult(first.toolCalls[2].id, "read_b", "b result")
	local saved = f.h.json.decode(f.env.require("runtime/util").encode(ctx.serialise()))
	local restored = f.env.require("agent/context").new(); restored.restore(saved)
	assert(f.complete({ messages = restored.wire("System"), stream = false }))
	local model, results = bodies[2].contents[2], bodies[2].contents[3]
	check("both signatures and part boundaries survive reload", #model.parts == 3 and model.parts[1].thoughtSignature == "signed-thought" and model.parts[2].thoughtSignature == "signed-call")
	check("parallel tool results retain order and native ID semantics", #results.parts == 2 and results.parts[1].functionResponse.id == "native-a"
		and results.parts[2].functionResponse.id == nil and results.parts[2].functionResponse.name == "read_b")
	local other = f.env.require("runtime/util").copy(f.record); other.model = "gemini-2.5-flash"
	local migrated = f.adapter.buildBody(other, { messages = restored.wire("System") })
	check("a different model cannot reuse foreign signed parts", not has(f.env.require("runtime/util").encode(migrated), "signed-thought") and not has(f.env.require("runtime/util").encode(migrated), "signed-call"))
	f.done()
end)

case("SSE keeps signed boundaries, reasoning, usage and completion requirements", function()
	local f = fixture(); local chunks, frames = {}, {}
	local function chunk(value) chunks[#chunks + 1] = "data: " .. f.h.json.encode(value) .. "\r\n\r\n" end
	chunk({ candidates = { { content = { parts = { { text = "Thought", thought = true, thoughtSignature = "thought-signature" } } } } }, modelVersion = "gemini-3.8-flash" })
	chunk({ candidates = { { content = { parts = { { text = "Hello " } } } } } })
	chunk({ candidates = { { content = { parts = { { text = "world", thoughtSignature = "answer-signature" } } }, finishReason = "STOP" } } })
	chunk({ usageMetadata = { promptTokenCount = 40, candidatesTokenCount = 5, thoughtsTokenCount = 3, totalTokenCount = 48 } })
	local body = ": heartbeat\r\n\r\n" .. table.concat(chunks)
	local parsed = assert(f.adapter.parseStream(body, function(frame) frames[#frames + 1] = frame end))
	check("SSE separates thoughts and answer text", parsed.content == "Hello world" and parsed.reasoning == "Thought" and parsed.finish == "stop" and parsed.frames == 4)
	check("signed text parts cannot merge into adjacent text", #parsed.geminiParts == 3 and parsed.geminiParts[3].thoughtSignature == "answer-signature")
	check("SSE usage includes thinking once", parsed.usage.completion_tokens == 8 and parsed.usage.total_tokens == 48)
	check("stream previews use normalized deltas", #frames == 3 and frames[1].choices[1].delta.reasoning_content == "Thought" and frames[3].choices[1].delta.content == "world")
	local truncated = assert(chunks[1]) .. chunks[2]
	check("missing terminal reason rejects partial output", f.adapter.parseStream(truncated) == nil)
	check("in-stream provider failure rejects earlier text", f.adapter.parseStream(chunks[1] .. 'event: error\ndata: {"error":{"message":"fixture refusal"}}\n\n') == nil)
	check("text after a terminal result is rejected", f.adapter.parseStream(body .. chunks[2]) == nil)
	local media = { candidates = { { content = { parts = { { text = "mixed", inlineData = { mimeType = "image/png", data = "fixture" } } } }, finishReason = "STOP" } } }
	check("mixed media cannot disappear into adjacent text", f.adapter.parseStream(chunks[2] .. "data: " .. f.h.json.encode(media) .. "\n\n") == nil)
	for _, malformed in ipairs({ { usageMetadata = 4 }, { candidates = { { content = 4 } } },
		{ candidates = { { content = { parts = "bad" } } } } }) do
		local ok, value = pcall(f.adapter.parseStream, "data: " .. f.h.json.encode(malformed) .. "\n\n")
		check("malformed stream fields return a failure without throwing", ok and value == nil)
	end
	f.done()
end)

case("native discovery follows pages and respects declared generation methods", function()
	local f, reads = fixture(), 0
	f.h.http.handler = function(entry)
		reads = reads + 1
		check("native catalog uses its key header", entry.headers["x-goog-api-key"] == "fixture-google-key")
		if reads == 1 then
			return { StatusCode = 200, Body = f.h.json.encode({ models = {
				{ name = "models/gemini-3.8-flash", supportedGenerationMethods = { "generateContent", "countTokens" } },
				{ name = "models/gemini-embedding-001", supportedGenerationMethods = { "embedContent" } },
			}, nextPageToken = "next page/+" }) }
		end
		check("page token is URL encoded on the same native endpoint", entry.url == "https://generativelanguage.googleapis.com/v1beta/models?pageToken=next%20page%2F%2B")
		return { StatusCode = 200, Body = f.h.json.encode({ models = { { name = "models/gemini-2.5-pro", supportedGenerationMethods = { "generateContent" } } } }) }
	end
	local models = f.env.require("provider/models")
	local found = f.run(function() return models.discover(f.record) end, 1)
	check("native model IDs are normalized and embedding-only entries excluded", table.concat(found, ",") == "gemini-2.5-pro,gemini-3.8-flash" and reads == 2)
	check("completed native catalog is cached", models.cached(f.record) == found)
	f.done()
end)

case("documented thinking scales and model-default temperature apply to native requests", function()
	local f = fixture(); local request = { messages = { { role = "user", content = "Hi" } } }
	f.record.model = "gemini-3-pro-preview"; f.config.set("agent.effort", "medium")
	local body = f.adapter.buildBody(f.record, request)
	check("Gemini3 Pro clamps unsupported medium down to low", body.generationConfig.thinkingConfig.thinkingLevel == "LOW")
	check("Gemini3 preserves provider-default temperature", body.generationConfig.temperature == nil)
	f.record.model = "gemini-3.8-flash"; f.config.set("agent.effort", "max")
	body = f.adapter.buildBody(f.record, request)
	check("Gemini3.8 uses supported HIGH rather than invented max", body.generationConfig.thinkingConfig.thinkingLevel == "HIGH")
	f.config.set("agent.effort", "off")
	check("provider-default effort omits level without losing summaries", f.adapter.buildBody(f.record, request).generationConfig.thinkingConfig.thinkingLevel == nil)
	f.record.model = "gemini-2.5-pro"; f.config.set("agent.effort", "medium")
	body = f.adapter.buildBody(f.record, request)
	check("Gemini2.5 uses budget syntax only", body.generationConfig.thinkingConfig.thinkingBudget == 8192 and body.generationConfig.thinkingConfig.thinkingLevel == nil)
	f.record.model = "gemini-3.1-flash-lite"; f.config.set("agent.effort", "minimal")
	check("documented minimal level is supported", f.adapter.buildBody(f.record, request).generationConfig.thinkingConfig.thinkingLevel == "MINIMAL")
	f.record.model = "gemini-4-argon"; f.config.set("agent.effort", "medium")
	check("Gemini4 Argon uses its documented scale and omits sampling", f.adapter.buildBody(f.record, request).generationConfig.thinkingConfig.thinkingLevel == "MEDIUM"
		and f.adapter.buildBody(f.record, request).generationConfig.temperature == nil)
	f.done()
end)

case("unsupported temperature gets one scoped refusal repair without replaying ambiguous errors", function()
	local f, bodies = fixture(), {}
	f.record.model = "fixture-temperature-model"
	f.h.http.handler = function(entry)
		bodies[#bodies + 1] = f.h.json.decode(entry.body)
		if #bodies == 1 then return { StatusCode = 400, Body = '{"error":{"message":"Unsupported parameter: temperature"}}' } end
		return { StatusCode = 200, Body = f.h.json.encode(f.reply()) }
	end
	check("explicit parameter refusal recovers", f.complete() ~= nil and #bodies == 2 and bodies[1].generationConfig.temperature ~= nil and bodies[2].generationConfig.temperature == nil)
	check("later request reuses the scoped omission", f.complete() ~= nil and bodies[3].generationConfig.temperature == nil)
	f.record.model = "other-model"
	assert(f.complete())
	check("another model keeps its own sampling policy", bodies[4].generationConfig.temperature ~= nil)
	local before = #bodies
	f.h.http.handler = function(entry) bodies[#bodies + 1] = f.h.json.decode(entry.body); return { StatusCode = 400, Body = '{"error":{"message":"temperature sensor tool failed"}}' } end
	check("unrelated temperature wording is not a repair", f.complete() == nil and #bodies == before + 1)
	f.done()
end)

case("quota rotation and cancellation use the existing bounded request lifetime", function()
	local f, keys = fixture(), {}
	f.record.apiKey = "fixture-key-one\nfixture-key-two"
	f.h.http.handler = function(entry)
		keys[#keys + 1] = entry.headers["x-goog-api-key"]
		if #keys == 1 then return { StatusCode = 429, Body = '{"error":{"status":"RESOURCE_EXHAUSTED","message":"Quota exhausted"}}' } end
		return { StatusCode = 200, Body = f.h.json.encode(f.reply()) }
	end
	check("quota refusal tries the next configured key", f.complete() ~= nil and #keys == 2 and keys[1] ~= keys[2])
	local stopped, requests = false, 0
	f.h.http.handler = function() requests = requests + 1; stopped = true; return { StatusCode = 400, Body = '{"error":{"message":"Unsupported temperature"}}' } end
	local result, why = f.complete({ messages = { { role = "user", content = "Cancel" } }, stream = false, temperature = 0.5,
		aborted = function() return stopped end })
	check("cancellation prevents learning or retry", result == nil and has(why, "aborted") and requests == 1)
	f.done()
end)

case("malformed and blocked responses cannot dispatch partial tool calls", function()
	local f = fixture()
	for _, value in ipairs({ { candidates = { 4 } }, { candidates = { { content = 4, finishReason = "STOP" } } },
		{ promptFeedback = { blockReason = "SAFETY" } },
		f.reply({ { functionCall = { name = "fixture", args = { "not-an-object" } } } }),
		f.reply({ { functionCall = { name = "fixture", args = {} } } }, "SAFETY"),
		f.reply({ { functionCall = { name = "fixture", args = {} } } }, "MALFORMED_FUNCTION_CALL") }) do
		check("invalid native response is an actionable failure", f.adapter.fromResponse(value) == nil)
	end
	f.record.model = "../../untrusted:model"
	check("model path cannot alter the native route", f.complete() == nil and f.h.http.requestCount == 0)
	f.done()
end)

suite.finish()
