-- Focused Code palette, caption geometry and pane-drag ownership checks.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Code UI polish")
local case, check = suite.case, suite.check
local function luminance(color)
	local function channel(value) return value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4 end
	return channel(color.R) * 0.2126 + channel(color.G) * 0.7152 + channel(color.B) * 0.0722
end
local function contrast(first, second)
	local a, b = luminance(first), luminance(second)
	return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05)
end

for _, palette in ipairs({ "dark", "light" }) do
	case("comparison text stays readable at rest, hover and keyboard focus with " .. palette .. " code", function()
		local f = F.ui(1000, 700)
		f.env.require("runtime/config").set("ui.codeTheme", palette)
		local theme = f.env.require("ui/theme"); theme.rebuild()
		local doc = f.env.require("runtime/code_store").active()
		local source, revision, applied = doc.source, doc.revision, false
		local modal = f.env.require("ui/code/compare").open("local value = 1\nreturn value", "local value = 2\nreturn value", "Review", function() applied = true; return true end)
		f.h.sched.advance(0.1)
		for _, name in ipairs({ "UnifiedComparison", "BeforeComparison", "AfterComparison" }) do
			local list = assert(f.h.byName(name, modal.card))
			check("comparison body paints the selected code surface", list.BackgroundTransparency == 0 and list.BackgroundColor3 == theme.color.codeSurface)
			for _, row in ipairs(list:GetChildren()) do
				if row.Name == "VirtualRow" and row.Visible then
					local label = assert(row:FindFirstChild("Label"))
					check("comparison source uses the code font", label.Font == theme.text.mono.font and label.TextSize == theme.text.mono.size)
					check("comparison source is readable at rest", contrast(label.TextColor3, list.BackgroundColor3) >= 4.5)
					row.MouseEnter:Fire()
					check("hover preserves code-palette contrast", row.BackgroundTransparency == 0 and contrast(label.TextColor3, row.BackgroundColor3) >= 4.5)
					row.MouseLeave:Fire(); row.SelectionGained:Fire()
					check("keyboard focus preserves code-palette contrast", row.BackgroundTransparency == 0 and contrast(label.TextColor3, row.BackgroundColor3) >= 4.5)
					row.SelectionLost:Fire()
				end
			end
		end
		for _, kind in ipairs({ "keyword", "string", "number", "comment", "call" }) do
			check("current-line background keeps " .. kind .. " readable", contrast(theme.code[kind], theme.color.codeBar) >= 4.5)
		end
		check("review and navigation cannot apply or mutate source", not applied and doc.source == source and doc.revision == revision)
		modal.close(); f.healthy(); f.close()
	end)
end

case("pane resizing releases missed gestures and owns only its initiating pointer", function()
	local f = F.ui(540, 360)
	local uis, enum = f.env.uis, f.h.sandbox.Enum
	local signals = { uis.InputChanged, uis.InputEnded, uis.WindowFocusReleased }
	local counts = {}; for index, signal in ipairs(signals) do counts[index] = signal:Count() end
	local moves = 0
	local splitter = f.env.require("ui/code/splitter").new(f.host, function() moves = moves + 1 end)
	local mouse = { UserInputType = enum.UserInputType.MouseButton1 }
	local motion = { UserInputType = enum.UserInputType.MouseMovement, Position = f.h.sandbox.Vector2.new(100, 10) }
	splitter.root.InputBegan:Fire(mouse); uis.InputChanged:Fire(motion)
	uis.WindowFocusReleased:Fire(); uis.InputChanged:Fire(motion)
	check("focus loss prevents a missed mouse-up from resuming resize", moves == 1)
	local first = { UserInputType = enum.UserInputType.Touch, Position = f.h.sandbox.Vector2.new(120, 10) }
	local second = { UserInputType = enum.UserInputType.Touch, Position = f.h.sandbox.Vector2.new(150, 10) }
	splitter.root.InputBegan:Fire(first); splitter.root.InputBegan:Fire(second); uis.InputChanged:Fire(second)
	check("a second touch cannot retarget the resize", moves == 1)
	uis.InputChanged:Fire(first); uis.InputEnded:Fire(mouse); uis.InputChanged:Fire(first)
	check("an unrelated mouse release does not cancel the active touch", moves == 3)
	uis.InputEnded:Fire(first); uis.InputChanged:Fire(first)
	check("the initiating touch release ends resizing", moves == 3)
	splitter.root.InputBegan:Fire(mouse); splitter.root.Visible = false; splitter.root.Visible = true; uis.InputChanged:Fire(motion)
	check("hiding the divider releases its pending gesture", moves == 3)
	splitter.root.Destroying:Fire()
	for index, signal in ipairs(signals) do check("native destruction releases global listener " .. index, signal:Count() == counts[index]) end
	splitter.root.InputBegan:Fire(mouse); uis.InputChanged:Fire(motion)
	check("late input cannot revive a destroyed divider", moves == 3)
	splitter.root:Destroy(); splitter.destroy()
	f.healthy(); f.close()
end)

case("compact large-text Files and Game changes retain readable captions and values", function()
	local f = F.ui(390, 600)
	f.env.uis.TouchEnabled, f.env.uis.MouseEnabled = true, false
	local config = f.env.require("runtime/config")
	config.set("ui.fontScale", 1.4); config.set("ui.density", "compact")
	f.env.require("ui/responsive").init(f.env.root)
	local theme = f.env.require("ui/theme"); theme.rebuild()
	local files = f.env.require("ui/code/files").new(f.host, function() end)
	local footer = assert(f.h.byName("WorkspaceFileStatus", files.root))
	check("Files footer reserves its caption line and padding", footer.AbsoluteSize.Y >= theme.text.caption.height + theme.space.xxs * 2)
	check("Files rows end before the enlarged footer", files.list.root.AbsolutePosition.Y + files.list.root.AbsoluteSize.Y <= footer.AbsolutePosition.Y)
	local part = f.h.Instance.new("Part", f.h.workspace); part.Name, part.Transparency = "Review object", 0
	local refs, values = f.env.require("runtime/instance_refs"), f.env.require("runtime/values")
	local result = f.env.require("runtime/instance_edits").apply({ { instanceId = refs.id(part), kind = "property", key = "Transparency", expected = values.node(0), value = values.node(0.5) } }, { origin = "fixture" })
	assert(result.ok, result.text)
	f.host.Size = f.h.sandbox.UDim2.fromOffset(390, 240)
	local history = f.env.require("ui/code/history").new(f.host, true)
	for index, item in ipairs(history.list.items) do if item.id == result.batchId then history.list.selected = index; history.list.activate(); break end end
	f.h.sched.advance(0.1)
	for _, name in ipairs({ "ChangedFieldPath", "BeforeFieldLabel", "AfterFieldLabel" }) do
		check(name .. " reserves the caption's measured height", assert(f.h.byName(name, history.root)).AbsoluteSize.Y >= theme.text.caption.height)
	end
	for _, name in ipairs({ "BeforeValue", "AfterValue" }) do
		check(name .. " keeps at least two full source lines", assert(f.h.byName(name, history.root)).AbsoluteSize.Y >= theme.text.mono.height * 2)
	end
	check("Game changes keeps a complete selectable field row", history.fields.root.AbsoluteSize.Y >= history.fields.rowHeight)
	check("opening Game changes never reapplies an edit", part.Transparency == 0.5)
	history.destroy(); files.destroy(); f.healthy(); f.close()
end)

suite.finish()
