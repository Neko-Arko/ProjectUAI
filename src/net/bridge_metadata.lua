-- Presentation metadata from the same limits and effort rules the native client
-- uses. Reading it performs no discovery, inference or configuration changes.
return function(env)
	local util = env.require("runtime/util")
	local config = env.require("runtime/config")
	local traits = env.require("provider/traits")
	local sampling = env.require("provider/sampling")
	local M = {}

	function M.model(record, id)
		id = util.trim(id or (record and record.model) or "")
		local row = traits.of(id, record)
		local levels, style = traits.effortLevels(id), traits.thinkingStyle(id)
		local source = levels and "documented" or "none"
		if not levels and style then
			levels = { "low", "medium", "high", "xhigh", "max" }
			source = (config.get("agent.forceReasoning", {}) or {})[id:lower()] == true and "manual" or "global"
		end
		local choices, effective
		if levels then
			choices = util.copy(levels)
			choices[#choices + 1] = "off"
			local wanted = config.get("agent.effort", "low")
			effective = wanted == "off" and "off" or traits.nearestEffort(id, wanted)
		end
		local reasoning = row.reasoning
		if style or levels then reasoning = true end
		local temperature = sampling.state(record, id)
		return { contextWindow = traits.contextWindow(id, record), maxOutputTokens = traits.maxOutput(id, record),
			temperatureAllowed = temperature.allowed, temperatureSource = temperature.source,
			temperatureOverride = temperature.override, temperatureSupported = temperature.supported,
			reasoning = reasoning, efforts = choices, effortSource = source, effectiveEffort = effective }
	end

	function M.context(session, record)
		if not session or not session.ctx then return nil end
		local effective = record
		local live = session.liveRequest
		if record and live and live.providerId == record.id and util.trim(live.model) ~= "" then
			effective = util.copy(record)
			effective.model = live.model
		end
		local model = effective and effective.model
		local values = session.ctx.breakdown(effective)
		return { sessionId = session.id, providerId = effective and effective.id, model = model,
			usedTokens = values.used, windowTokens = traits.contextWindow(model, effective),
			compactionTokens = session.ctx.limitFor(model, effective), systemTokens = values.system,
			messageTokens = values.messages, summaryTokens = values.summary, estimated = true,
			partial = not values.calibrated and not values.estimatedPrompt,
			calibrated = values.calibrated == true, estimatedPrompt = values.estimatedPrompt == true }
	end

	return M
end
