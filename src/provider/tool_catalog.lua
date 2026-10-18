-- Preserve tools beyond a provider's declaration limit without granting new scope.
-- Plans are request-local and never serialized into the provider body or history.
return function(env)
	local util = env.require("runtime/util")
	local schema = env.require("agent/schema")
	local M = {}
	local plans = setmetatable({}, { __mode = "k" })
	local function nameOf(tool) return (tool["function"] or tool).name end
	local function functionOf(tool) return tool["function"] or tool end

	function M.limit(body, limit, reservedNames)
		if type(body.tools) ~= "table" then return end
		local previous = plans[body]
		local original = previous and previous.original or body.tools
		reservedNames = previous and previous.reservedNames or reservedNames
		if #original <= limit then return end
		limit = math.max(1, math.floor(limit))
		local names, router = {}, "uai_tool_catalog"
		for _, tool in ipairs(original) do names[nameOf(tool)] = true end
		local suffix = 1
		while names[router] do suffix = suffix + 1; router = "uai_tool_catalog_" .. suffix end
		local selected, count = {}, 0
		local choice = body.tool_choice
		local forced = type(choice) == "table" and (type(choice["function"]) == "table" and choice["function"].name or choice.name)
		forced = previous and previous.forced or forced
		if forced and names[forced] and limit > 1 then selected[forced], count = true, 1 end
		-- One declaration always remains for discovery and dispatch. Compatibility
		-- names retain their wire shape, but never enter the executable overflow.
		for _, tool in ipairs(original) do
			local name = nameOf(tool)
			if reservedNames and reservedNames[name] and not selected[name] and count < limit - 1 then
				selected[name], count = true, count + 1
			end
		end
		for _, tool in ipairs(original) do
			local name = nameOf(tool)
			if not selected[name] and not (reservedNames and reservedNames[name]) and count < limit - 1 then
				selected[name], count = true, count + 1
			end
		end
		local out, omitted, choices, summaries, emitted = {}, {}, {}, {}, {}
		for _, tool in ipairs(original) do
			local fn, name = functionOf(tool), nameOf(tool)
			if selected[name] and not emitted[name] then out[#out + 1] = tool; emitted[name] = true
			elseif not selected[name] and not (reservedNames and reservedNames[name]) and not omitted[name] then
				omitted[name] = tool
				choices[#choices + 1] = name
				summaries[#summaries + 1] = name .. ": " .. util.ellipsis(tostring(fn.description or ""), 100)
			end
		end
		if #choices == 0 then
			for _, tool in ipairs(original) do
				if #out < limit and not emitted[nameOf(tool)] then out[#out + 1] = tool; emitted[nameOf(tool)] = true end
			end
			body.tools, plans[body] = out, nil
			return
		end
		local fn = {
			name = router,
			strict = false,
			description = "Additional available tools (provider declaration limit). Use action=describe with a name to read its exact schema; follow nextOffset with offset until eof. Then action=call with that name and an arguments object matching the schema. Calls use the original tool's permissions and scope.\n" .. table.concat(summaries, "\n"),
			parameters = { type = "object", properties = {
				action = { type = "string", enum = { "describe", "call" } },
				name = { type = "string", enum = choices },
				arguments = { type = "object", description = "Required for action=call; the target tool's exact arguments.", additionalProperties = true },
				offset = { type = "integer", minimum = 1, description = "Schema byte offset for action=describe; default 1." },
			}, required = { "action", "name" }, additionalProperties = false },
		}
		out[#out + 1] = original[1] and original[1]["function"] and { type = "function", ["function"] = fn }
			or { type = "function", name = fn.name, description = fn.description, parameters = fn.parameters, strict = false }
		body.tools = out
		if forced and omitted[forced] then
			body.tool_choice = original[1] and original[1]["function"] and { type = "function", ["function"] = { name = router } }
				or { type = "function", name = router }
		end
		plans[body] = { original = original, name = router, omitted = omitted, parameters = fn.parameters,
			reservedNames = reservedNames, forced = forced }
	end

	function M.bind(result, body)
		result.toolCatalog = plans[body]
		return result
	end

	-- Keep original assistant calls for provider replay; only execution/UI uses
	-- translated calls. Neither a provider override nor a forged router argument
	-- can widen the authoritative catalogue assembled by the agent loop.
	function M.resolve(result, definitions)
		local calls, immediate = {}, {}
		local plan = result.toolCatalog
		local allowed = {}
		for _, tool in ipairs(definitions or {}) do allowed[nameOf(tool)] = true end
		for index, call in ipairs(result.toolCalls or {}) do
			calls[index] = call
			local fn = call["function"] or {}
			if plan and fn.name == plan.name then
				local outcome = { id = call.id, name = plan.name, ok = false, ms = 0 }
				immediate[index] = outcome
				local args, why = schema.repairJson(fn.arguments or "{}", { allowTruncated = false })
				local errors
				if args then args, errors = schema.validate(plan.parameters, args) end
				if args then
					for key in pairs(args) do
						if not plan.parameters.properties[key] then errors[#errors + 1] = "unknown argument " .. tostring(key) end
					end
				end
				if not args or (errors and #errors > 0) then
					outcome.text = "Catalogue call did not run. Correct its JSON arguments: " .. tostring(why or table.concat(errors, "; "))
				elseif not allowed[args.name] or not plan.omitted[args.name] then
					outcome.text = "This tool is outside this request's available catalogue. No call ran."
				elseif plan.forced and args.action == "call" and args.name ~= plan.forced then
					outcome.text = "This request requires " .. plan.forced .. ". No other call ran."
				elseif args.action == "describe" then
					local source = util.encode(functionOf(plan.omitted[args.name]))
					local page = env.require("tools/helpers").readSlice("Tool schema " .. args.name, source, { offset = args.offset }, 6000, 6000)
					outcome.ok, outcome.text, outcome.data = page.ok ~= false, page.text, page.data
					if page.data then outcome.modelText = page.text .. "\n\nResult data:\n" .. util.encode(page.data) end
				elseif type(args.arguments) ~= "table" then
					outcome.text = "Catalogue call did not run. action=call requires an arguments object matching the described tool schema."
				else
					calls[index] = { id = call.id, type = "function", ["function"] = { name = args.name, arguments = util.encode(args.arguments) } }
					immediate[index] = nil
				end
				if not outcome.ok then
					outcome.error = "invalid catalogue arguments"
					if outcome.text then
						local budget = env.require("tools/helpers").resultBudget()
						outcome.text = budget >= 4 and util.ellipsis(outcome.text, math.min(1200, budget)) or ""
					end
				end
			end
		end
		return calls, immediate
	end

	function M.runAll(calls, immediate, ctx, registry, callback)
		local pending, indices, outcomes = {}, {}, {}
		for index, call in ipairs(calls) do
			if immediate[index] then
				outcomes[index] = immediate[index]
				if ctx.aborted and ctx.aborted() then
					outcomes[index] = { id = call.id, name = immediate[index].name, ok = false,
						error = "aborted", text = "Stopped before the catalogue read was delivered.", ms = 0 }
				end
				callback(outcomes[index])
			else pending[#pending + 1] = call; indices[#indices + 1] = index end
		end
		for index, outcome in ipairs(registry.runAll(pending, ctx, callback)) do outcomes[indices[index]] = outcome end
		return outcomes
	end
	return M
end
