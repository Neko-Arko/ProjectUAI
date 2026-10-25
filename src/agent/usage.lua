-- Token and cost accounting.
--
-- Providers report usage inconsistently -- some only in a streamed final chunk,
-- some not at all -- so counts are taken from the response when present and
-- estimated when not, and an estimated figure is always labelled as one. Prices
-- are a convenience, not an invoice: the reviewed catalog uses per-million
-- text-token rates; provider-specific surcharges and discounts may differ.
return function(env)
	local util = env.require("runtime/util")
	local signal = env.require("runtime/signal")
	local pricing = env.require("agent/pricing")
	local function count(value)
		local number = tonumber(value)
		if not number or number ~= number or number < 0 or number > 9007199254740991 then return nil end
		return math.floor(number)
	end

	local M = {
		session = { prompt = 0, completion = 0, total = 0, cost = 0, requests = 0, estimated = false },
		turn = { prompt = 0, completion = 0, total = 0, cost = 0 },
		changed = signal.new("usage"),
		-- One request, as it was measured, rather than the running totals `changed`
		-- carries. This is the only place in the client where a model id and the tokens
		-- it actually spent are in scope together, so anything keeping a per-model
		-- history has to hear about it here.
		recorded = signal.new("usage:recorded"),
	}

	function M.priceFor(model, record, promptTokens)
		return pricing.priceFor(model, record, promptTokens)
	end

	-- A byte-based heuristic, not a tokenizer. Code and Unicode vary by model;
	-- dispatch-time usage calibration corrects the observed request estimate.
	function M.estimateText(text)
		if type(text) ~= "string" then return 0 end
		return math.ceil(#text / 4)
	end

	function M.estimateMessages(messages)
		local total = 0
		for _, message in ipairs(messages or {}) do
			-- Per-message framing overhead, plus the role name.
			total = total + 4 + M.estimateText(message.content)
			-- Image costs depend on the model. Reserve a conservative estimate until
			-- provider usage calibrates the request; never count base64 as prose.
			total = total + #(message.images or {}) * 1600
			if type(message.content) == "table" then
				for _, block in ipairs(message.content) do
					if block.type == "text" then total = total + M.estimateText(block.text)
					elseif block.type == "image_url" or block.type == "image" then total = total + 1600 end
				end
			end
			local reasoning = message.reasoning_content or message.reasoning
			if reasoning then total = total + M.estimateText(reasoning) end
			-- Internal messages carry toolCalls; wire messages carry tool_calls, and
			-- the loop estimates over the wire form.
			for _, call in ipairs(message.toolCalls or message.tool_calls or {}) do
				local fn = call["function"] or {}
				local args = type(fn.arguments) == "table" and util.encode(fn.arguments) or fn.arguments
				total = total + 8 + M.estimateText(fn.name) + M.estimateText(args)
			end
		end
		return total
	end

	function M.startTurn()
		M.turn = { prompt = 0, completion = 0, total = 0, cost = 0 }
	end

	-- `usage` is the provider block when it exists. `fallback` supplies estimates
	-- so a provider that reports nothing still moves the counters.
	function M.record(usage, model, fallback, record)
		usage = type(usage) == "table" and usage or {}
		local prompt = count(usage.prompt_tokens) or count(usage.input_tokens)
		local completion = count(usage.completion_tokens) or count(usage.output_tokens)
		local estimated = prompt == nil or completion == nil
		prompt = prompt or count(fallback and fallback.prompt) or 0
		completion = completion or count(fallback and fallback.completion) or 0

		local cached = count(util.get(usage or {}, "prompt_tokens_details.cached_tokens",
			util.get(usage or {}, "input_tokens_details.cached_tokens", 0))) or 0
		local created = count(util.get(usage or {}, "cache_creation_input_tokens",
			util.get(usage or {}, "prompt_tokens_details.cache_creation_tokens", 0))) or 0
		local reasoning = count(util.get(usage or {}, "completion_tokens_details.reasoning_tokens",
			util.get(usage or {}, "output_tokens_details.reasoning_tokens", 0))) or 0
		cached = math.min(cached, prompt)
		created = math.min(created, prompt - cached)
		reasoning = math.min(reasoning, completion)
		local pricedCost = pricing.costFor(model, record, prompt, completion, cached, created)
		local cost = pricedCost or 0

		if not (fallback and fallback.background) then
			M.turn.prompt = M.turn.prompt + prompt
			M.turn.completion = M.turn.completion + completion
			M.turn.total = M.turn.prompt + M.turn.completion
			M.turn.cost = M.turn.cost + cost
		end

		M.session.prompt = M.session.prompt + prompt
		M.session.completion = M.session.completion + completion
		M.session.total = M.session.prompt + M.session.completion
		M.session.cost = M.session.cost + cost
		M.session.requests = M.session.requests + 1
		if pricedCost == nil then M.session.unpriced = (M.session.unpriced or 0) + 1 end
		if estimated then M.session.estimated = true end

		M.session.cached = (M.session.cached or 0) + cached
		M.session.cacheCreated = (M.session.cacheCreated or 0) + created
		M.session.reasoning = (M.session.reasoning or 0) + reasoning

		local delta = {
			model = model,
			prompt = prompt,
			completion = completion,
			cost = cost,
			costKnown = pricedCost ~= nil,
			estimated = estimated,
			cached = tonumber(cached) or 0,
			cacheCreated = created,
			reasoning = tonumber(reasoning) or 0,
		}
		env.require("runtime/request_accounting").report(fallback and fallback.accounting, usage, { prompt = prompt, completion = completion })
		M.recorded:fire(delta)
		M.changed:fire(M.session, M.turn)
		return { prompt = prompt, completion = completion, cost = cost, costKnown = pricedCost ~= nil, estimated = estimated }
	end

	function M.reset()
		M.session = { prompt = 0, completion = 0, total = 0, cost = 0, requests = 0, estimated = false }
		M.turn = { prompt = 0, completion = 0, total = 0, cost = 0 }
		M.changed:fire(M.session, M.turn)
	end

	function M.formatCost(value)
		if value <= 0 then return "" end
		if value < 0.01 then return string.format("$%.4f", value) end
		return string.format("$%.3f", value)
	end

	function M.line()
		local parts = {
			util.formatNumber(M.session.total) .. " tokens",
			util.formatNumber(M.session.prompt) .. " in",
			util.formatNumber(M.session.completion) .. " out",
		}
		local cost = M.formatCost(M.session.cost)
		if cost ~= "" then parts[#parts + 1] = cost .. " est." end
		if (M.session.unpriced or 0) > 0 then parts[#parts + 1] = "some costs unknown" end
		return table.concat(parts, "  ")
	end

	return M
end
