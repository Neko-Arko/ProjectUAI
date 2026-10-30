-- Model-sized option sets retain stable rows, actions, empty states and ownership.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Searchable menus")
local case, check = suite.case, suite.check

case("search uses all words, preserves row identity and keeps setup actions", function()
	local f = F.ui(900, 650); local P = f.env.require("ui/primitives")
	local anchor = P.button(f.host, { name = "MenuAnchor", text = "Models" })
	local options = {}
	for index = 1, 150 do options[#options + 1] = { label = "vendor/model-" .. index, value = index,
		detail = index % 2 == 0 and "Free" or "Paid" } end
	options[#options + 1] = { divider = true }
	options[#options + 1] = { label = "Refresh catalog", value = "fetch", searchable = false }
	options[#options + 1] = { label = "Type model ID", value = "add", searchable = false }
	f.h.settle(0.1)
	local selected
	local menu = f.env.require("ui/overlay").menu({ target = anchor.instance, options = options, searchable = true,
		onSelect = function(value) selected = value end })
	f.h.settle(0.2)
	local box = f.h.byName("MenuSearch"):FindFirstChildOfClass("TextBox")
	local first = f.h.byName("Option_12"); box:CaptureFocus()
	f.h.type(box, "model-12 FREE"); f.h.settle(0.1)
	check("multiple words inspect ID and detail", first.Visible and not f.h.byName("Option_13").Visible and not f.h.byName("Option_121").Visible)
	check("search keeps row and field identity", f.h.byName("Option_12") == first and box:IsFocused())
	check("refresh and manual entry remain available", f.h.byName("Option_fetch").Visible and f.h.byName("Option_add").Visible)
	check("search sits outside option scrolling", box.Parent.Parent.Parent == menu.card and first.Parent ~= box.Parent.Parent)
	f.h.type(box, "no-such-model"); f.h.settle(0.1)
	check("empty state appears without hiding recovery", f.h.byName("NoMenuMatches").Visible and f.h.byName("Option_fetch").Visible)
	f.h.type(box, ""); f.h.settle(0.1)
	check("clear restores choices", first.Visible and f.h.byName("Option_13").Visible and not f.h.byName("NoMenuMatches").Visible)
	f.h.click(first)
	check("selection closes exactly this menu", selected == 12 and menu.closed)
	f.healthy(); f.close()
end)

case("anchor destruction releases a searchable menu", function()
	local f = F.ui(390, 720); local P = f.env.require("ui/primitives")
	local anchor = P.button(f.host, { text = "Models" }); f.h.settle(0.1)
	local overlay = f.env.require("ui/overlay")
	local before = f.env.require("ui/responsive").changed:count()
	local menu = overlay.menu({ target = anchor.instance, searchable = true, options = { { label = "One", value = "one" } } })
	f.h.settle(0.2); anchor.instance:Destroy(); f.h.settle(0.1)
	check("destroyed owner closes", menu.closed and menu.scrim.Parent == nil)
	check("responsive listener released", f.env.require("ui/responsive").changed:count() == before)
	f.healthy(); f.close()
end)

suite.finish()
