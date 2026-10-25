-- Selection never hands visible source to a full-document native renderer.
-- These checks exercise raw input/state and bounded presentation, not Roblox
-- glyph rasterization, host clipboard handling or native pointer hit testing.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Code selection visibility")
local case, check = suite.case, suite.check
local function visibleRows(root, name)
	local count, bytes = 0, 0
	for _, node in ipairs(root:GetDescendants()) do
		if node.Name == name and node.Visible then count = count + 1; bytes = bytes + #(node.Text or "") end
	end
	return count, bytes
end
local function rangeVisible(root, name)
	for _, node in ipairs(root:GetDescendants()) do if node.Name == name and node.Visible and node.Size.X.Offset > 0 then return true end end
	return false
end

case("Select all keeps long UTF-8 documents visible in both directions and across tabs", function()
	local f = F.ui(680, 420)
	local store, text = f.env.require("runtime/code_store"), f.env.require("runtime/code_text")
	local source = string.rep("local value = '你好'\n\n", 3400) .. "return value"
	local doc = store.active(); assert(store.update(doc.id, source))
	local before = f.env.run.Heartbeat:Count()
	local editor = f.env.require("ui/code/editor").new(f.host)
	local box, revision = editor.box, doc.revision
	box:CaptureFocus()
	for _, backwards in ipairs({ false, true }) do
		box.SelectionStart, box.CursorPosition = backwards and #source + 1 or 1, backwards and 1 or #source + 1
		for _, top in ipairs({ 0, 2400, 14000 }) do
			editor.scroll.CanvasPosition = f.h.sandbox.Vector2.new(0, top)
			local rows, bytes = visibleRows(editor.root, "SyntaxLine")
			check("full selection has bounded readable rows", rows > 0 and rows <= 160 and bytes > 0)
			check("full selection paints the visible range", rangeVisible(editor.root, "SourceSelection"))
		end
		check("selection never mutates source or wraps rich markup into native text", box.Text == source and doc.source == source and doc.revision == revision and not box.RichText and not box.TextWrapped)
		check("native byte endpoints still select the exact full source", text.slice(box.Text, box.SelectionStart, box.CursorPosition) == source)
	end
	local presentation = assert(f.h.byName("SourcePresentation", box))
	check("the stable presentation covers native glyph repainting without capturing input", presentation.Visible and presentation.BackgroundTransparency == 0 and not presentation.Active and not presentation.Selectable and box.TextTransparency == 1)
	local cursor, anchor = box.CursorPosition, box.SelectionStart
	assert(store.create("Second.lua", "return 2", { select = true })); assert(store.select(doc.id))
	check("returning to the tab keeps native source and reverse selection", editor.box == box and box.Text == source and box.CursorPosition == cursor and box.SelectionStart == anchor)
	check("restored selection still has readable code", visibleRows(editor.root, "SyntaxLine") > 0 and rangeVisible(editor.root, "SourceSelection"))
	box.Text = "local replacement = '✓'\nreturn replacement"
	box.CursorPosition, box.SelectionStart = #box.Text + 1, -1; f.h.sched.advance(0.1)
	check("native replacement edits reach the store exactly once", doc.source == box.Text and doc.revision == revision + 1 and f.h.byName("SyntaxLine", editor.root).Text:find("replacement", 1, true) ~= nil)
	check("collapsing selection restores the caret and clears every range fill", f.h.byName("SourceCaret", editor.root).Visible and not rangeVisible(editor.root, "SourceSelection"))
	box.Text = ""; box.CursorPosition = 1; f.h.sched.advance(0.1)
	check("clearing source leaves the native empty-field placeholder visible", box.Text == "" and box.TextTransparency == 0 and not presentation.Visible)
	editor.destroy(); f.h.sched.advance(0.6)
	check("selection rendering releases its heartbeat on destruction", f.env.run.Heartbeat:Count() == before)
	f.healthy(); f.close()
end)

case("a full long-line selection stays readable while scrolling horizontally", function()
	local f = F.ui(440, 280)
	local store = f.env.require("runtime/code_store")
	local source = "local text = '" .. string.rep("x你好", 18000) .. "'"
	assert(store.update(store.activeId(), source))
	local editor = f.env.require("ui/code/editor").new(f.host); local box = editor.box
	box:CaptureFocus(); box.SelectionStart, box.CursorPosition = 1, #source + 1
	for _, left in ipairs({ 0, 16000, 48000 }) do
		editor.scroll.CanvasPosition = f.h.sandbox.Vector2.new(left, 0)
		local rows, bytes = visibleRows(editor.root, "SyntaxLine")
		check("horizontal selection keeps a bounded source window", rows == 1 and bytes > 0 and bytes < 20000 and rangeVisible(editor.root, "SourceSelection"))
	end
	check("horizontal scrolling retains exact source and selection", box.Text == source and box.SelectionStart == 1 and box.CursorPosition == #source + 1)
	f.healthy(); editor.destroy(); f.close()
end)

case("read-only Code previews share selection-safe rendering and native line advance", function()
	local f = F.ui(540, 340)
	local source = string.rep("local text = '你好'\n", 2400)
	local before = f.env.run.Heartbeat:Count()
	local preview = f.env.require("ui/code/preview").new(f.host, source)
	local box = preview.box
	box:CaptureFocus(); box.SelectionStart, box.CursorPosition = 1, #source + 1; f.h.sched.advance(0.1)
	local single, multiple = f.h.byName("PreviewSingleLineMetrics", box), f.h.byName("PreviewLineMetrics", box)
	single.TextBounds = f.h.sandbox.Vector2.new(16, 17)
	multiple.TextBounds = f.h.sandbox.Vector2.new(16, 17 + 32 * 18.25)
	f.h.sched.advance(0.1)
	local rows, bytes = visibleRows(box, "SyntaxPreviewLine")
	check("read-only source uses bounded visible rows during Select all", rows > 0 and rows <= 160 and bytes > 0 and rangeVisible(box, "PreviewSelection"))
	check("read-only source and native copy endpoints stay intact", not box.TextEditable and box.Text == source and not box.RichText and box.CursorPosition == #source + 1 and box.SelectionStart == 1)
	check("selection has no duplicate caret and uses fractional native line advance", not f.h.byName("PreviewCaret", box).Visible and f.h.byName("SyntaxPreviewLine", box).Size.Y.Offset == 18.25)
	check("preview scroll bounds use that same native line advance", preview.root.CanvasSize.Y.Offset >= 2401 * 18.25)
	box.CursorPosition, box.SelectionStart = 1, #source + 1; f.h.sched.advance(0.1)
	check("reverse preview selection keeps both source and range readable", visibleRows(box, "SyntaxPreviewLine") > 0 and rangeVisible(box, "PreviewSelection") and box.TextTransparency == 1)
	box:ReleaseFocus(); preview.destroy(); f.h.sched.advance(0.1)
	check("preview destruction releases metrics and rendering listeners", f.env.run.Heartbeat:Count() == before)
	f.healthy(); f.close()
end)

suite.finish()
