package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Usage accounting")
local check = suite.check
suite.case("malformed provider counters cannot poison usage totals", function()
	local f = F.new(); local usage = f.env.require("agent/usage")
	local result = usage.record({ prompt_tokens = -10, completion_tokens = math.huge }, "fixture",
		{ prompt = 120, completion = 30 }, { baseUrl = "https://unknown.invalid/v1" })
	check("invalid counters use the measured fallback", result.prompt == 120 and result.completion == 30 and result.estimated)
	local partial = usage.record({ prompt_tokens = 5 }, "fixture", { completion = 7 }, nil)
	check("partial usage preserves the reported side", partial.prompt == 5 and partial.completion == 7 and partial.estimated)
	local empty = usage.record({}, "fixture", { prompt = 0/0, completion = -1 }, nil)
	check("invalid fallback stays finite and nonnegative", empty.prompt == 0 and empty.completion == 0)
	local event; usage.recorded:connect(function(value) event = value end)
	usage.record({ prompt_tokens = 10, completion_tokens = 2, prompt_tokens_details = { cached_tokens = 8, cache_creation_tokens = 50 },
		completion_tokens_details = { reasoning_tokens = 900 } }, "fixture", nil, nil)
	check("cache partitions cannot exceed input", event.cached == 8 and event.cacheCreated == 2)
	check("reasoning cannot exceed output", event.reasoning == 2)
	check("cache writes remain available to history", usage.session.cacheCreated == 2)
	check("unknown is distinct from a free invoice", usage.session.unpriced == 4 and event.costKnown == false)
	local aliases = usage.record({ prompt_tokens = -5, input_tokens = 30, completion_tokens = "invalid", output_tokens = 5,
		prompt_tokens_details = { cached_tokens = math.huge, cache_creation_tokens = -2 },
		completion_tokens_details = { reasoning_tokens = 0/0 } }, "gpt-6.1-sol", nil, { baseUrl = "https://api.openai.com/v1" })
	check("valid alternate aliases survive malformed primary counters", aliases.prompt == 30 and aliases.completion == 5 and not aliases.estimated)
	check("invalid cache and reasoning counts stay finite", event.cached == 0 and event.cacheCreated == 0 and event.reasoning == 0 and aliases.costKnown)
	f.healthy(); f.close()
end)
suite.finish()
