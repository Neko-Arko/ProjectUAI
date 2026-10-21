-- Persistent tool evidence: durable receipts do not change inline results.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Evidence ledger")
local case, check = suite.case, suite.check

local function setup()
	local f = F.new(); f.tools({ "evidence" })
	f.env.require("runtime/config").set("agent.evidence", "all")
	f.registry.register({ name = "fixture_evidence", group = "fs", risk = "read", description = "Evidence fixture.",
		parameters = { type = "object", properties = {}, required = {} },
		run = function(args)
			return { text = args.text or "short result", data = { answer = 42, marker = args.marker or "none" } }
		end })
	local ctx = { session = { id = "s-evidence" }, aborted = function() return false end }
	return f, ctx
end

case("tool results are retained and readable without changing the receipt", function()
	local f, ctx = setup()
	check("the inline receipt is still the ordinary tool result", #f.dispatch("fixture_evidence", {}, ctx).text > 0)
	local receipt = f.dispatch("fixture_evidence", { text = "retained text", marker = "alpha" }, ctx)
	check("the normal result is unchanged", receipt.ok and receipt.text == "retained text")
	check("a durable evidence id is attached", type(receipt.evidenceId) == "string" and receipt.evidenceId:find("^ev%-") ~= nil)
	local listed = f.dispatch("evidence", { action = "list", query = "fixture_evidence" }, ctx)
	check("the ledger lists the result", listed.ok and listed.data.total >= 1)
	local item
	for _, entry in ipairs(listed.data.items) do if entry.preview:find("retained text", 1, true) then item = entry end end
	check("the exact receipt is listed", item ~= nil and item.tool == "fixture_evidence" and item.bytes > 0)
	local text = f.dispatch("evidence", { action = "read", record_id = item.id, section = "text" }, ctx)
	check("full text is readable", text.ok and text.text:find("retained text", 1, true) ~= nil)
	local data = f.dispatch("evidence", { action = "read", record_id = item.id, section = "data" }, ctx)
	check("structured data is readable", data.ok and data.text:find('"answer":42', 1, true) ~= nil)
	local summary = f.dispatch("evidence", { action = "read", record_id = item.id, section = "summary" }, ctx)
	check("summary identifies the record", summary.ok and summary.text:find("Tool: fixture_evidence", 1, true) ~= nil)
	local searched = f.dispatch("evidence", { action = "search", query = "retained" }, ctx)
	check("search finds a retained result", searched.ok and searched.data.total >= 1)
	local status = f.dispatch("evidence", { action = "status" }, ctx)
	check("status reports the retained ledger", status.ok and status.data.records >= 2)
	f.loaded["runtime/evidence"] = nil
	local reopened = f.env.require("runtime/evidence").list({ id = "s-evidence" }, { query = "retained text" })
	check("the ledger reopens from disk", reopened and reopened.total >= 1)
	f.healthy(); f.close()
end)

case("evidence is bounded and missing or foreign records fail clearly", function()
	local f, ctx = setup()
	local long = f.dispatch("fixture_evidence", { text = string.rep("x", 600000) }, ctx)
	check("oversized text is retained with a truncation marker", long.evidenceId ~= nil)
	local listed = f.dispatch("evidence", { action = "list", limit = 50 }, ctx)
	local item
	for _, entry in ipairs(listed.data.items) do if entry.id == long.evidenceId then item = entry end end
	check("the oversized record is listed", item ~= nil)
	local page = f.dispatch("evidence", { action = "read", record_id = long.evidenceId, section = "text", limit = 200 }, ctx)
	check("oversized text pages and reports truncation", page.ok and page.data.evidence.truncated == true)
	local missing = f.dispatch("evidence", { action = "read", record_id = "ev-missing", section = "text" }, ctx)
	check("missing evidence fails clearly", not missing.ok and missing.text:find("removed", 1, true) ~= nil)
	local other = f.dispatch("evidence", { action = "read", record_id = long.evidenceId, section = "text" },
		{ session = { id = "s-other" }, aborted = function() return false end })
	check("another conversation cannot read this ledger", not other.ok)
	f.healthy(); f.close()
end)

case("the default policy keeps large unique results only and can be cleared", function()
	local f = F.new(); f.tools({ "evidence" })
	f.registry.register({ name = "fixture_policy", group = "fs", risk = "read", description = "Policy fixture.",
		parameters = { type = "object", properties = {}, required = {} },
		run = function(args) return { text = args.text or "small", data = { marker = "same" } } end })
	local ctx = { session = { id = "s-policy" }, aborted = function() return false end }
	check("the default policy is large", f.env.require("runtime/config").get("agent.evidence") == "large")
	local small = f.dispatch("fixture_policy", { text = "too small to retain" }, ctx)
	check("small results are not written", small.evidenceId == nil)
	local largeText = string.rep("y", 9000)
	local large = f.dispatch("fixture_policy", { text = largeText }, ctx)
	check("large results are written", type(large.evidenceId) == "string")
	local again = f.dispatch("fixture_policy", { text = largeText }, ctx)
	local state = f.env.require("runtime/evidence").state(ctx.session)
	check("identical large results are deduplicated", again.evidenceId == large.evidenceId and state.records == 1)
	local direct = f.env.require("runtime/evidence").record(ctx.session, "file_read", string.rep("z", 10000), nil)
	check("already-durable file results are skipped", direct == nil)
	local cleared = f.dispatch("evidence_clear", {}, ctx)
	check("evidence can be cleared for the conversation", cleared.ok and cleared.data.after.records == 0)
	f.healthy(); f.close()
end)

case("a fast burst is bounded in memory instead of writing between every call", function()
	local f = F.new(); f.tools({ "evidence" })
	f.env.require("runtime/config").set("agent.evidence", "all")
	local evidence = f.env.require("runtime/evidence")
	local session = { id = "s-burst" }
	for index = 1, 80 do
		evidence.record(session, "fixture_burst", string.rep(string.char(64 + index % 26), 9000) .. index, nil, { ok = true })
	end
	local state = evidence.state(session)
	check("the queue drops rather than growing without bound", evidence.stats.dropped > 0)
	check("the flushed ledger stays within its record cap", state.records <= evidence.limits.records)
	check("no writes failed during the burst", evidence.stats.failed == 0)
	f.healthy(); f.close()
end)

suite.finish()
