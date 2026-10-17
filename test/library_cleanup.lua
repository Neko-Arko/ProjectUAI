-- Focused Library selection and atomic removal checks with synthetic source.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Library cleanup")
local case, check = suite.case, suite.check
local function entry(item, kind) return { kind = kind or "document", id = item.id } end

case("one stale entry preserves the entire batch and its history", function()
	local f = F.new(); local store = f.env.require("runtime/code_store"); store.init()
	local first, second = store.active(), assert(store.create("Second.lua", "return 2"))
	local action = assert(store.saveAction(second.id, "Saved action", {}))
	local entries = { entry(first), entry(second), entry(action, "action") }
	local plan = assert(store.prepareDelete(entries))
	assert(store.rename(second.id, "Renamed.lua"))
	check("renames invalidate a pending removal", not store.deletePrepared(plan) and #store.list() == 2 and #store.actions() == 1)
	plan = assert(store.prepareDelete(entries)); assert(store.saveVersion(second.id, "Keep this version"))
	check("new saved history also blocks removal", not store.deletePrepared(plan) and #second.versions == 1)
	plan = assert(store.prepareDelete(entries)); assert(store.propose(second.id, second.revision, "return 3"))
	check("a newly received proposal is retained", not store.deletePrepared(plan) and #store.proposals(second.id) == 1)
	plan = assert(store.prepareDelete(entries)); assert(store.update(first.id, "return 'new draft'"))
	check("edits to any selected source block all removals", not store.deletePrepared(plan) and store.resolve(second.id) == second)
	f.healthy(); f.close()
end)

case("batch removal frees capacity once, retains unselected sources and persists", function()
	local f = F.new(); local store, fs = f.env.require("runtime/code_store"), f.env.require("runtime/fsx"); store.init()
	local keep = store.active(); assert(store.update(keep.id, "return 'keep'"))
	local entries = {}
	for index = 2, 50 do entries[#entries + 1] = entry(assert(store.create("Scratch " .. index, "return " .. index))) end
	check("capacity is bounded before cleanup", not store.create("Overflow", ""))
	assert(fs.write("keep-on-disk.lua", "return 'file'"))
	local removed = store.resolve(entries[1].id); assert(store.select(removed.id)); assert(store.propose(removed.id, removed.revision, "return 100"))
	local keptAction = assert(store.saveAction(removed.id, "Independent action", {}))
	local events = 0; local off = store.changed:connect(function(event)
		if event.kind == "delete" then events = events + 1; check("observers see the complete batch", #store.list() == 1 and #store.proposals() == 0) end
	end)
	local result = assert(store.deletePrepared(assert(store.prepareDelete(entries)))); off()
	check("one operation frees all selected slots", result.count == 49 and events == 1 and store.activeId() == keep.id)
	check("unselected action and workspace file survive", store.action(keptAction.id) and fs.read("keep-on-disk.lua") == "return 'file'")
	assert(store.create("New work", "return 42")); assert(store.saveNow())
	local saved = assert(store.validate(f.h.json.decode(assert(fs.read("code/workspace.json")))))
	check("remaining sources persist exactly", #saved.documents == 2 and saved.documents[1].source == "return 'keep'" and #saved.actions == 1)
	f.healthy(); f.close()
end)

case("selection survives filters and rebuilds and uses one current confirmation", function()
	local f = F.ui(680, 460); local store, overlay = f.env.require("runtime/code_store"), f.env.require("ui/overlay")
	local first = store.active(); assert(store.rename(first.id, "Alpha.lua"))
	local second = assert(store.create("Beta.lua", "return 2")); local keep = assert(store.create("Keep.lua", "return 3"))
	local reviews, review = 0
	overlay.confirm = function(options) reviews, review = reviews + 1, options end
	local library = f.env.require("ui/code/library").new(f.host, function() end)
	local function click(name) f.h.click(assert(f.h.byName(name, library.root))) end
	local function search(text) local shell = assert(f.h.byName("LibrarySearch", library.root)); shell:FindFirstChildWhichIsA("TextBox", true).Text = text end
	click("LibrarySelect"); search("Alpha"); click("LibrarySelectAll"); search("Beta"); click("LibrarySelectAll")
	check("search keeps hidden selections explicit", f.h.byName("LibrarySelectionInfo", library.root).Text:find("1 hidden", 1, true) ~= nil)
	check("selection mode hides individual delete controls", not library.list.rows[1].closeSlot.Visible)
	library.destroy(); library = f.env.require("ui/code/library").new(f.host, function() end)
	check("rebuild preserves both selections and query", store.workspace.librarySelecting and store.workspace.libraryQuery == "Beta" and library.list.items[1].selected)
	click("LibraryDeleteSelected")
	check("one confirmation describes both selected scripts", reviews == 1 and review.description:find("Alpha.lua", 1, true) and review.description:find("Beta.lua", 1, true) and #store.list() == 3)
	assert(store.update(second.id, "return 'late edit'")); review.onConfirm()
	check("stale batch preserves every script and selection", #store.list() == 3 and store.workspace.librarySelection["document:" .. first.id])
	click("LibraryDeleteSelected"); review.onConfirm()
	check("fresh confirmation deletes only the chosen scripts", #store.list() == 1 and store.resolve(keep.id) == keep and reviews == 2)
	library.destroy(); f.healthy(); f.close()
end)

suite.finish()
