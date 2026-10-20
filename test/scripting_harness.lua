-- Deterministic model-response fixtures exercise the actual prompt/tool loop.
-- These establish harness behavior, not a live model quality benchmark.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Scripting harness")
local case, check = suite.case, suite.check
local function has(text, part) return tostring(text):find(part, 1, true) ~= nil end

local function provider(f, preset)
	local providers = f.env.require("provider/registry")
	local record = providers.blank(preset or "custom")
	record.model, record.models, record.apiKey = "scripting-fixture", { "scripting-fixture" }, "fixture-key"
	if preset ~= "zen" then record.baseUrl = "https://scripting.test/v1" end
	assert(providers.save(record))
	return record
end

local function reply(record, name, args, step, finish)
	return { model = record.model, content = name and "" or "Done", reasoning = "",
		toolCalls = name and { { id = "step_" .. step, ["function"] = { name = name, arguments = args } } } or {},
		finish = finish or (name and "tool_calls" or "stop") }
end

case("output-limited batches cannot prevent the first complete script from running", function()
	local f = F.new(); f.tools({ "fs", "script" })
	local record, steps, outcomes = provider(f), 0, {}
	local source = 'local text = "True False None ,} ,]"\nreturn 6 * 7, text'
	local write = f.h.json.encode({ path = "files/fixture.lua", content = source })
	local path = f.h.json.encode({ path = "files/fixture.lua" })
	f.loaded["provider/chat"] = { contextOverflow = function() return false end, complete = function(_, request)
		steps = steps + 1
		if steps > 1 then outcomes[#outcomes + 1] = request.messages[#request.messages].content end
		if steps <= 3 then return reply(record, "file_write", write, steps, steps < 3 and "length" or "tool_calls") end
		if steps == 4 then return reply(record, "check_luau", path, steps) end
		if steps == 5 then return reply(record, "run_luau", path, steps) end
		return reply(record)
	end }
	local session = assert(f.env.require("agent/session").create({ ephemeral = true, maxTurns = 6,
		toolFilter = { file_write = true, check_luau = true, run_luau = true } }))
	local result = f.run(function() return f.env.require("agent/loop").run(session, "Write and run the small script") end, 1)
	check("both truncated batches explicitly remain unexecuted", has(outcomes[1], "No calls in this batch ran")
		and has(outcomes[2], "No calls in this batch ran"))
	check("the first complete write reaches the actual file tool", has(outcomes[3], "Wrote")
		and f.env.require("runtime/fsx").readUser("files/fixture.lua") == source)
	check("the saved path compiles and runs through the managed engine", has(outcomes[4], "compiled successfully")
		and has(outcomes[5], "Returned: 42") and has(outcomes[5], "True False None ,} ,]"))
	check("the loop completes within the focused six-response workflow", result == "Done" and steps == 6)
	f.healthy(); f.close()
end)

case("OpenCode declarations recover through the actual scoped file tool", function()
	local f = F.new(); f.tools({})
	for index = 1, 14 do
		f.registry.register({ name = "fixture_" .. index, group = "misc", risk = "read", run = function() return "unused" end })
	end
	f.tools({ "fs" })
	assert(f.env.require("runtime/fsx").write("fixture.lua", "return 42", { scope = "files" }))
	local record, steps = provider(f, "zen"), 0
	f.loaded["provider/chat"] = { contextOverflow = function() return false end, complete = function(_, request)
		steps = steps + 1
		check("the OpenCode prompt explains its compatibility-only declarations", has(request.messages[1].content, "OpenCode compatibility:")
			and has(request.messages[1].content, "no local implementation"))
		if steps == 1 then return reply(record, "read", '{"path":"files/fixture.lua"}', steps) end
		if steps == 2 then
			local message = request.messages[#request.messages].content
			check("the failed declaration directs the model to an executable scoped tool", has(message, "Available tools include: file_read.")
				and not has(message, "file_write") and not has(message, "fixture_"))
			return reply(record, "file_read", '{"path":"files/fixture.lua"}', steps)
		end
		check("the corrected call returns the saved script", has(request.messages[#request.messages].content, "return 42"))
		return reply(record)
	end }
	local session = assert(f.env.require("agent/session").create({ ephemeral = true, maxTurns = 3, toolFilter = { file_read = true } }))
	check("a compatibility misfire can recover in the same turn", f.run(function()
		return f.env.require("agent/loop").run(session, "Read the script")
	end, 1) == "Done")
	local prompt = f.env.require("agent/prompt")
	check("unrelated providers do not get OpenCode instructions", not has(prompt.build({ tools = {} }), "OpenCode compatibility:"))
	local registered = prompt.build({ opencodeCompatibility = true,
		tools = { { name = "bash" }, { name = "read" }, { name = "edit" }, { name = "glob" }, { name = "grep" }, { name = "list" }, { name = "shell" } } })
	check("real host-provided handlers retain their names", not has(registered, "OpenCode compatibility:"))
	f.healthy(); f.close()
end)

case("unknown-tool recovery excludes denied disabled and unavailable tools", function()
	local f = F.new(); f.tools({ "fs", "script" })
	f.registry.register({ name = "fixture_missing", group = "fs", risk = "read", needs = { "fixture_missing_capability" },
		run = function() error("unavailable tool must never run") end })
	f.registry.setGroupEnabled("script", false)
	f.env.require("agent/permissions").setMode("readonly")
	local result = f.dispatch("edit", {}, { session = { toolExclude = { file_read = true } } })
	check("suggestions honor current permission group and session policy", not result.ok
		and has(result.text, "file_list") and not has(result.text, "file_write")
		and not has(result.text, "file_read,") and not has(result.text, "check_luau") and not has(result.text, "fixture_missing"))
	local empty = f.dispatch("bash", {}, { session = { toolFilter = {} } })
	check("an empty scope reports the actual limit", not empty.ok and has(empty.text, "No tools are available"))
	f.healthy(); f.close()
end)

case("native desktop refusals cannot execute registered host-name collisions", function()
	local f = F.new(); f.tools({})
	local reserved, ran = "opencode_host_action", 0
	local function run() ran = ran + 1; return "Custom tool result" end
	check("the tunnel receipt name cannot be registered", not f.registry.register({ name = reserved, run = run })
		and f.registry.get(reserved) == nil)
	check("an explicitly provided custom tool may retain a native-looking name", f.registry.register({ name = "execute", risk = "read", run = run }))
	-- A host can access the registry escape hatch; even that cannot make a
	-- refused desktop action call either the receipt handler or a namesake tool.
	f.registry.tools[reserved] = { name = reserved, group = "misc", risk = "read", run = run }
	local outcome = f.dispatch(reserved, { name = "execute", arguments = { code = "return 42" } },
		{ session = { toolFilter = {} } })
	check("the refusal is recorded without calling either colliding handler", not outcome.ok and ran == 0
		and outcome.id == "fixture-call" and outcome.name == reserved and outcome.error == "OpenCode host action"
		and has(outcome.text, "desktop tool 'execute' was blocked before execution")
		and has(outcome.text, "No tools are available") and not has(outcome.text, "return 42"))
	for _, raw in ipairs({ "not JSON", '{"name":42}', '{"name":""}', ("x"):rep(4097) }) do
		local malformed = f.registry.dispatch({ id = "malformed", ["function"] = { name = reserved, arguments = raw } },
			{ session = { toolFilter = {} } })
		check("malformed receipts remain non-executable refusals", not malformed.ok and malformed.error == "OpenCode host action"
			and has(malformed.text, "desktop tool 'unknown'") and ran == 0)
	end
	local bounded = f.dispatch(reserved, { name = ("x"):rep(101) .. "\nunsafe'" }, { session = { toolFilter = {} } })
	check("native names cannot inject or expand feedback", has(bounded.text, "desktop tool '" .. ("x"):rep(100) .. "'")
		and not has(bounded.text, "unsafe") and not has(bounded.text, ("x"):rep(101)))
	f.registry.tools[reserved] = nil
	check("a real separately requested custom tool still executes", f.dispatch("execute", {}).ok and ran == 1)
	f.healthy(); f.close()
end)

case("native desktop corrections preserve the current Roblox tool scope", function()
	local f = F.new(); f.tools({ "fs", "script" })
	f.registry.register({ name = "fixture_missing", group = "fs", risk = "read", needs = { "fixture_missing_capability" },
		run = function() error("unavailable tool must never run") end })
	f.registry.setGroupEnabled("script", false)
	f.env.require("agent/permissions").setMode("readonly")
	local outcome = f.dispatch("opencode_host_action", { name = "filesystem" }, { session = {
		toolFilter = { file_read = true, file_read_many = true, file_list = true, file_search = true,
			file_write = true, run_luau = true, fixture_missing = true },
		toolExclude = { file_read = true },
	} })
	check("native suggestions exclude denied disabled unavailable and excluded tools", not outcome.ok
		and has(outcome.text, "Available tools include: file_read_many, file_list, file_search.")
		and not has(outcome.text, "file_write") and not has(outcome.text, "file_read,")
		and not has(outcome.text, "run_luau") and not has(outcome.text, "fixture_missing"))
	local empty = f.dispatch("opencode_host_action", { name = "search" }, { session = {
		toolFilter = { file_read = true }, toolGroups = { fs = true }, toolExclude = { file_read = true },
	} })
	check("native corrections cannot widen an empty effective conversation scope", not empty.ok
		and has(empty.text, "No tools are available") and not has(empty.text, "Available tools include"))
	f.healthy(); f.close()
end)

case("a blocked native action recovers through the actual Roblox script loop", function()
	local f = F.new(); f.tools({ "script" })
	local record, steps = provider(f, "zen"), 0
	f.loaded["provider/chat"] = { contextOverflow = function() return false end, complete = function(_, request)
		steps = steps + 1
		if steps == 1 then return reply(record, "opencode_host_action", '{"name":"execute"}', steps) end
		if steps == 2 then
			local receipt = request.messages[#request.messages]
			check("the next ordinary provider step receives the paired refusal", receipt.role == "tool"
				and receipt.tool_call_id == "step_1" and receipt.name == "opencode_host_action"
				and has(receipt.content, "blocked before execution") and has(receipt.content, "Available tools include: run_luau.")
				and has(receipt.content, "Desktop commands and host code are not Luau source"))
			return reply(record, "run_luau", '{"code":"return 6 * 7"}', steps)
		end
		check("the corrected action returns a real managed Roblox script result", has(request.messages[#request.messages].content, "Returned: 42"))
		return reply(record)
	end }
	local session = assert(f.env.require("agent/session").create({ ephemeral = true, maxTurns = 3, toolFilter = { run_luau = true } }))
	check("the original turn finishes after a refusal and corrected tool call", f.run(function()
		return f.env.require("agent/loop").run(session, "Calculate six times seven in Roblox")
	end, 1) == "Done" and steps == 3)
	f.healthy(); f.close()
end)

case("delegated workers receive the same OpenCode compatibility guidance", function()
	local f = F.new(); f.tools({ "fs" })
	local brief
	f.loaded["agent/loop"] = { run = function(session)
		brief = session.systemPrompt({ tools = { { name = "file_read" } }, opencodeCompatibility = true })
		return "Read complete"
	end }
	f.run(function() return f.env.require("agent/subagent").dispatch({ task = "Read the script", preset = "read" }) end)
	check("the child brief forwards provider-specific compatibility context", has(brief, "OpenCode compatibility:")
		and has(brief, "no local implementation"))
	f.healthy(); f.close()
end)

suite.finish()
