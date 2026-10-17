-- Focused Explorer navigation/search/selection checks using synthetic objects.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Explorer navigation")
local case, check = suite.case, suite.check
local function make(f, class, name, parent)
	local object = f.h.Instance.new(class, parent or f.h.workspace); object.Name = name; return object
end
local function click(f, pane, name) f.h.click(assert(f.h.byName(name, pane.root), name)) end
local function activate(pane, id)
	for index, row in ipairs(pane.list.items) do if row.instanceId == id then pane.list.selected = index; pane.list.activate(); return end end
	error("Object is missing from the displayed tree")
end

case("search stays flat and survives destination changes and view rebuild", function()
	local f = F.ui(900, 650); local explorer, refs = f.env.require("runtime/explorer"), f.env.require("runtime/instance_refs")
	local parent = make(f, "Folder", "Needle parent"); local child = make(f, "Part", "Needle child", parent)
	make(f, "Part", "Unrelated child", parent)
	explorer.expanded[refs.id(parent)] = true
	local pane = f.env.require("ui/code/explorer").new(f.host, function() end)
	pane.search("Needle"); f.h.sched.advance(0.5)
	check("expanded descendants do not duplicate search results", #pane.list.items == 2 and pane.list.items[1].depth == 0 and pane.list.items[2].depth == 0)
	activate(pane, refs.id(child)); pane.setVisible(false); pane.setVisible(true); f.h.sched.advance(0.5)
	check("returning to Explorer retains query and selection", #pane.list.items == 2 and explorer.primaryId == refs.id(child) and f.env.require("runtime/code_store").workspace.explorerQuery == "Needle")
	pane.destroy(); pane = f.env.require("ui/code/explorer").new(f.host, function() end); f.h.sched.advance(0.5)
	check("rebuild resumes the same search", #pane.list.items == 2 and explorer.view.query ~= nil)
	click(f, pane, "ExplorerClearSearch")
	check("clear returns to the hierarchy with literal matching restored", explorer.view.query == nil and explorer.view.pattern == false and f.env.require("runtime/code_store").workspace.explorerQuery == "")
	pane.destroy(); f.healthy(); f.close()
end)

case("subtree and parent navigation show the actual root and retain selection", function()
	local f = F.ui(900, 650); local explorer, refs = f.env.require("runtime/explorer"), f.env.require("runtime/instance_refs")
	local folder = make(f, "Folder", "Chosen root"); local child = make(f, "Part", "Inside", folder)
	assert(explorer.select({ refs.id(folder) }))
	local pane = f.env.require("ui/code/explorer").new(f.host, function() end)
	click(f, pane, "ExplorerFocusSubtree")
	check("custom root is named and contains only its children", explorer.view.root == refs.id(folder) and f.h.textOf(f.h.byName("ExplorerRoot", pane.root)) == "Chosen root" and #pane.list.items == 1 and pane.list.items[1].instanceId == refs.id(child))
	pane.setVisible(false); pane.setVisible(true)
	check("navigation remains at the chosen subtree", explorer.view.root == refs.id(folder))
	click(f, pane, "ExplorerParent")
	check("Up moves to the actual parent without changing selected targets", explorer.view.root == refs.id(f.h.workspace) and explorer.primaryId == refs.id(folder))
	pane.destroy(); f.healthy(); f.close()
end)

case("visible multiple-selection controls work without modifier keys", function()
	local f = F.ui(900, 650); local explorer, refs = f.env.require("runtime/explorer"), f.env.require("runtime/instance_refs")
	local first, second = make(f, "Part", "Select first"), make(f, "Part", "Select second")
	explorer.view.root = refs.id(f.h.workspace)
	local pane = f.env.require("ui/code/explorer").new(f.host, function() end)
	click(f, pane, "ExplorerSelectMultiple"); activate(pane, refs.id(first)); activate(pane, refs.id(second))
	check("touch-style row activation accumulates exact objects", #explorer.selectedIds == 2 and explorer.selectionMode == "multiple")
	activate(pane, refs.id(first)); check("selected rows toggle out independently", #explorer.selectedIds == 1 and explorer.primaryId == refs.id(second))
	click(f, pane, "ExplorerClearSelection"); check("clear releases all selected identities", #explorer.selectedIds == 0 and explorer.primaryId == nil)
	pane.destroy(); f.healthy(); f.close()
end)

case("property values can be found and copied without editing", function()
	local f = F.ui(900, 650); local explorer, refs = f.env.require("runtime/explorer"), f.env.require("runtime/instance_refs")
	local object = make(f, "Part", "DistinctiveValue")
	assert(explorer.select({ refs.id(object) }))
	local pane = f.env.require("ui/code/explorer").new(f.host, function() end)
	f.h.byName("PropertySearch", pane.root):FindFirstChildOfClass("TextBox").Text = "DistinctiveValue"
	local list = f.h.byName("InstanceProperties", pane.root)
	local row
	for _, candidate in ipairs(list:GetChildren()) do if candidate.Name == "VirtualRow" and candidate.Visible and candidate:FindFirstChild("Label").Text == "Name" then row = candidate end end
	check("filtering by value finds the matching field", row ~= nil)
	local choose
	f.env.require("ui/code/common").menu = function(_, _, _, callback) choose = callback end
	row.Activated:Fire(); choose("copy")
	check("copy returns the displayed value without modifying the object", f.h.sandbox.__clipboard:find("DistinctiveValue", 1, true) and object.Name == "DistinctiveValue")
	choose("copyName"); check("field names have a direct copy action", f.h.sandbox.__clipboard == "Name")
	pane.destroy(); f.healthy(); f.close()
end)

suite.finish()
