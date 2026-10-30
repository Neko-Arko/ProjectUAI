-- The brain behind an AI chat loop.
--
-- A chat loop used to prepare each reply with one bare completion: no tools, no
-- view of the game, and a prompt that had to forbid tool calls because the answer
-- went straight into chat. It is now a real subagent -- a headless session with
-- its own context and the read-only half of the catalogue -- so a question about
-- the place can be answered by looking at it instead of guessed at.
--
-- The loop manager keeps the job. It batches incoming messages, paces replies,
-- clips them to one chat line and owns the only sender; this module turns a batch
-- of player messages into the next line, or into nothing.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local chat = env.require("runtime/gamechat")
	local providers = env.require("provider/registry")
	local M = {}

	-- Groups the worker may read. Deliberately narrow: every schema is paid for on
	-- every turn, and a chat reply is due in seconds rather than minutes. Files,
	-- skills and network capture belong to the user's own work, not to a stranger's
	-- question in a public channel.
	local GROUPS = { instance = true, players = true, world = true, meta = true, chat = true }

	-- Absent from the catalogue rather than denied. chat_send most of all: the loop
	-- manager owns this channel's pacing and duplicate suppression, and a second
	-- sender would bypass both. The rest would either start more background work or
	-- ask a question nobody is there to answer.
	local EXCLUDED = {
		chat_send = true, chat_agent = true, auto_chat = true, quiz_bot = true, auto_reply = true,
		chat_loop_status = true, chat_loop_stop = true, tool_search = true,
		dispatch_agent = true, agent_status = true, agent_followup = true,
		ask_user = true, conversation_rename = true, notify = true,
	}

	-- One batch may take a few steps when the worker inspects the game before
	-- answering. Beyond that it is better to answer with what it has than to keep
	-- a player waiting on a channel.
	local MAX_TURNS = 6
	local BUDGET_SECONDS = 120

	local function key(text)
		return util.trim(tostring(text or ""):lower():gsub("%s+", " "):gsub("[%p]+$", ""))
	end

	local function body(text, prefix)
		text = util.trim(text)
		local tag = util.trim(prefix)
		if tag ~= "" then
			while text:sub(1, #tag):lower() == tag:lower() do text = util.trim(text:sub(#tag + 1)) end
		end
		return text
	end

	-- Cut at a codepoint boundary, reserving exactly one chat message including its tag.
	local function clip(text, limit)
		local count = 0
		for index = 1, #text do
			local byte = text:byte(index)
			if byte < 128 or byte >= 192 then
				count = count + 1
				if count > limit then return util.trim(text:sub(1, index - 1)) end
			end
		end
		return text
	end

	function M.configure(job, args)
		local record = providers.active()
		if not record or record.enabled == false or util.trim(record.model) == "" then
			return nil, "Configure an enabled provider and model before starting chat_agent."
		end
		local instructions = args.instructions or "Be friendly, casual, and helpful. Answer players naturally."
		if type(instructions) ~= "string" or #instructions > 4000 or util.trim(instructions) == ""
			or not util.validUtf8(instructions) then return nil, "Supply 1–4000 bytes of valid chat agent instructions." end
		local prefix = args.prefix == nil and "[AGENT]" or args.prefix
		if type(prefix) ~= "string" or #prefix > 32 or not util.validUtf8(prefix) or prefix:find("[%c]") then
			return nil, "Use a single-line chat agent prefix of at most 32 bytes."
		end
		prefix = util.trim(prefix)
		if prefix ~= "" then prefix = prefix .. " " end
		local players
		if args.user_ids ~= nil then
			if type(args.user_ids) ~= "table" or #args.user_ids < 1 or #args.user_ids > 20 then
				return nil, "Supply 1–20 player user IDs, or omit user_ids to chat with everyone."
			end
			players = {}
			for _, id in ipairs(args.user_ids) do
				if type(id) ~= "number" or id <= 0 or id % 1 ~= 0 or id == math.huge then return nil, "Invalid player user ID." end
				players[id] = true
			end
		end
		job.agent = {
			prefix = prefix, players = players, instructions = instructions,
			speaker = env.plr and tostring(env.plr.Name) or "the local player",
			limit = 200 - #prefix,
			queue = {}, seen = {}, recent = {}, sentKeys = {},
			inputs = 0, turns = 0, skipped = 0, dropped = 0, generating = false,
			maxTurns = MAX_TURNS, budgetSeconds = BUDGET_SECONDS,
		}
		return true
	end

	function M.receive(job, entry)
		local agent = job.agent
		if agent.players and not agent.players[entry.userId] then return end
		local text = chat.validate(entry.text)
		if not text or not text:find("[^%s#]") then return end
		-- Avoid conversations between two tagged bots, including differently filtered echoes.
		local tag = util.trim(agent.prefix)
		if text:match("^%[[Aa][Gg][Ee][Nn][Tt]%]") or (tag ~= "" and text:sub(1, #tag):lower() == tag:lower()) then return end
		local id = entry.id ~= nil and tostring(entry.id) or ""
		if id == "" then id = "local:" .. tostring(entry.sequence or entry) end
		local messageKey = tostring(entry.userId) .. ":" .. id
		local fingerprint = tostring(entry.userId) .. ":" .. key(text)
		local now = clock.ms()
		if agent.seen[messageKey] then
			agent.skipped = agent.skipped + 1
			return
		end
		-- A bounded run retains every accepted ID, even after the chat history rolls over.
		if agent.inputs >= 2000 then return end
		agent.seen[messageKey] = true
		agent.inputs = agent.inputs + 1
		if agent.recent[fingerprint] and now - agent.recent[fingerprint] < 15000 then
			agent.skipped = agent.skipped + 1
			return
		end
		agent.recent[fingerprint] = now
		if #agent.queue >= 20 then table.remove(agent.queue, 1); agent.dropped = agent.dropped + 1 end
		agent.queue[#agent.queue + 1] = { user_id = entry.userId, player = entry.sender, message = text }
		agent.firstQueuedAt = agent.firstQueuedAt or now
		agent.readyAt = math.min(now + 1000, agent.firstQueuedAt + 2000)
	end

	function M.duplicate(job, text)
		local agent = job.agent
		local signature = key(body(text, agent.prefix))
		if agent.sentKeys[signature] then return true end
		-- Include manual sends and replies from a recently stopped agent on this channel.
		for _, entry in ipairs(chat.history) do
			if entry.channel == job.channel and (entry.outgoing or (env.plr and entry.userId == env.plr.UserId))
				and key(body(entry.text, agent.prefix)) == signature then return true end
		end
		return false
	end

	function M.reserve(job, text)
		-- Reserve before SendAsync can yield; a failed/ambiguous send is never retried.
		job.agent.sentKeys[key(body(text, job.agent.prefix))] = true
	end

	-- The worker, created on first use.
	--
	-- Read-only on purpose: the reply is going into a public channel, so a worker
	-- that could change the game would be acting on a stranger's sentence. The
	-- permission layer would still gate a write, but a prompt raised inside a
	-- headless child reaches a parent conversation nobody is watching.
	local function ensure(job)
		local agent = job.agent
		if agent.session then return agent.session end
		local registry = env.require("agent/registry")
		local readTools = {}
		for _, tool in ipairs(registry.list()) do
			if tool.risk == "read" then readTools[tool.name] = true end
		end
		local child, err = env.require("agent/session").create({
			title = "chat agent",
			headless = true,
			depth = 1,
			maxTurns = agent.maxTurns,
			budgetSeconds = agent.budgetSeconds,
			toolGroups = GROUPS,
			toolFilter = readTools,
			toolExclude = EXCLUDED,
		})
		if not child then
			agent.error = "The chat agent could not start: " .. tostring(err)
			return nil
		end
		-- Its tokens are the loop's, not the turn the user is watching. Without this
		-- a background reply moved the conversation's own token counters mid-turn.
		child.backgroundUsage = true
		local prompt = env.require("agent/prompt")
		child.systemPrompt = function(request)
			request = request or {}
			return prompt.chat({
				speaker = agent.speaker, prefix = util.trim(agent.prefix), limit = agent.limit,
				instructions = agent.instructions, channel = job.channel,
				tools = request.tools, model = request.model, provider = request.provider, session = child,
			})
		end
		agent.disconnect = child.events:connect(function(event)
			if event.kind == "request:start" then agent.model = event.model
			elseif event.kind == "turn:end" and event.failed then
				agent.failure = tostring(event.text or "The chat agent turn failed.")
			elseif event.kind == "error" then
				-- A fatal error ends the turn without a reply; a non-fatal one (step
				-- limit, deadline) ends it with an apology, which is not something to
				-- post in chat.
				if event.fatal then agent.failure = tostring(event.message or "The chat agent turn failed.")
				else agent.incomplete = true end
			end
		end)
		agent.session = child
		return child
	end

	local function describe(batch)
		local lines = {}
		for _, item in ipairs(batch) do
			lines[#lines + 1] = "- " .. tostring(item.player) .. ": " .. tostring(item.message)
		end
		return table.concat(lines, "\n")
	end

	-- One batch, one turn of the worker. Returns the reply text or a failure reason.
	local function turn(job, batch)
		local agent = job.agent
		local child = ensure(job)
		if not child then return nil, agent.error end
		agent.failure, agent.incomplete = nil, nil
		agent.turns = agent.turns + 1
		local ok, result = pcall(env.require("agent/loop").run, child,
			"New chat messages. Reply with one line, or <skip>.\n" .. describe(batch))
		if not ok then return nil, tostring(result) end
		if agent.failure then
			local failure = agent.failure
			agent.failure = nil
			return nil, failure
		end
		-- A turn that hit its step limit or deadline still returns prose. Posting
		-- "I reached this session's step limit" in a public channel would be worse
		-- than saying nothing, so it counts as a skip.
		if agent.incomplete then
			agent.incomplete = nil
			return ""
		end
		return tostring(result or "")
	end

	function M.step(job, active, finish, publish)
		local agent = job.agent
		if agent.generating or job.pending or #agent.queue == 0 or clock.ms() < job.nextAt
			or clock.ms() < (agent.readyAt or 0) then return end
		-- Skips and failed steps still cost a turn; without a ceiling a worker that
		-- always answers <skip> would run until the job's duration expired.
		if agent.turns >= math.min(job.count * 3, 300) then
			finish(job, "completed", "Chat agent turn budget reached")
			return
		end
		local batch = agent.queue
		agent.queue, agent.firstQueuedAt = {}, nil
		agent.generating = true
		publish(job)
		task.spawn(function()
			-- Stop, clear or a deadline may have landed between the tick and this
			-- worker; a dead job must not pay for a turn it will discard.
			if not active(job) then agent.generating = false; return end
			local ok, reply, failure = pcall(turn, job, batch)
			agent.generating = false
			-- Stop, a cleared conversation or a deadline may have landed while the
			-- worker was thinking; its answer must not be posted by a dead job.
			if not active(job) then return end
			if not ok then finish(job, "failed", tostring(reply)); return end
			if not reply then finish(job, "failed", tostring(failure)); return end
			local text = body(util.trim(reply), agent.prefix)
			local verdict = text:lower():gsub("[%s%.!]+$", "")
			if text == "" or verdict == "<skip>" or verdict == "skip" then
				agent.skipped = agent.skipped + 1
				job.nextAt = clock.ms() + job.interval * 1000
				publish(job)
				return
			end
			if not util.validUtf8(text) then finish(job, "failed", "The chat agent returned invalid UTF-8."); return end
			local line = agent.prefix .. clip(text:gsub("[%c%s]+", " "), agent.limit)
			local clean, validation = chat.validate(line)
			if not clean then finish(job, "failed", validation); return end
			if M.duplicate(job, clean) then
				agent.skipped = agent.skipped + 1
				job.nextAt = clock.ms() + job.interval * 1000
				publish(job)
				return
			end
			job.pending = clean
			publish(job)
		end)
	end

	-- Released when the job finishes for any reason. Cooperative: the loop unwinds
	-- at its next checkpoint, and the caller's active() check discards the answer.
	function M.close(job)
		local agent = job.agent
		if not agent then return end
		if agent.disconnect then agent.disconnect(); agent.disconnect = nil end
		local child = agent.session
		agent.session = nil
		if not child then return end
		child.removed, child.abortFlag = true, true
		pcall(child.abort)
	end

	return M
end
