-- Persistent tool evidence: durable receipts do not change inline results.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Evidence ledger")
local case, check = suite.case, suite.check

local function setup()
	local f = F.new(); f.tools({ "evidence" })
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

suite.finish()
