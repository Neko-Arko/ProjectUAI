-- Catalog requests belong to the picker and provider that started them.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Model picker discovery")
local case, check = suite.case, suite.check

local function fixture()
	local f = F.ui(900, 650)
	f.registry = f.env.require("provider/registry")
	f.models = f.env.require("provider/models")
	f.overlay = f.env.require("ui/overlay")
	f.records, f.notified = {}, 0
	for index = 1, 2 do
		local record = f.registry.blank("custom")
		record.label, record.baseUrl, record.authStyle = "Catalog " .. index, "https://picker-" .. index .. ".fixture/v1", "none"
		record.model, record.models = "manual-" .. index, { "manual-" .. index }
		assert(f.registry.save(record)); f.records[index] = record
	end
	f.registry.setActive(f.records[1].id)
	f.h.http.handler = function(request)
		return { StatusCode = 200, delay = 0.8,
			Body = f.h.json.encode({ data = { { id = "discovered-" .. request.index } } }) }
	end
	f.picker = f.env.require("ui/panels/modelpicker")
	function f.open()
		local picker = f.picker.open(function() f.notified = f.notified + 1 end)
		f.h.settle(0.1)
		return picker
	end
	function f.fetch()
		f.h.click(assert(f.h.byName("FetchModels"))); f.h.settle(0.1)
	end
	return f
end

case("switching away and back cancels the old catalog without a stale toast", function()
	local f = fixture(); local picker = f.open()
	local listeners = f.registry.changed:count()
	f.fetch()
	check("one catalog request starts", f.h.http.requestCount == 1)
	f.registry.setActive(f.records[2].id)
	f.registry.setActive(f.records[1].id)
	f.h.settle(1)
	check("old response cannot populate either provider", f.models.cached(f.records[1]) == nil and f.models.cached(f.records[2]) == nil)
	check("superseded completion is silent", #f.overlay.toasts == 0 and f.notified == 0)
	check("request listener is released", f.registry.changed:count() == listeners)
	f.fetch(); f.h.settle(1)
	check("Refresh admits a new request after cancellation", f.h.http.requestCount == 2 and f.models.cached(f.records[1])[1] == "discovered-2")
	check("current completion updates the picker normally", f.h.byName("Model_discovered-2") ~= nil and f.notified == 1 and #f.overlay.toasts == 1)
	picker.close(); f.h.settle(0.3); f.healthy(); f.close()
end)

case("closing and reopening the picker does not revive its old discovery", function()
	local f = fixture(); local before = f.registry.changed:count()
	local picker = f.open(); f.fetch(); picker.close(); f.h.settle(1)
	check("closed picker leaves no catalog or notification", f.models.cached(f.records[1]) == nil and #f.overlay.toasts == 0 and f.notified == 0)
	check("closed picker releases provider subscriptions", f.registry.changed:count() == before)
	local replacement = f.open(); f.fetch(); f.h.settle(1)
	check("replacement owns its successful catalog", f.h.http.requestCount == 2 and f.models.cached(f.records[1])[1] == "discovered-2"
		and f.notified == 1)
	replacement.close(); f.h.settle(0.3); f.healthy(); f.close()
end)

suite.finish()
