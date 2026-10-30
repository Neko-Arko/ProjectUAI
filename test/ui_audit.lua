-- Focused regressions for readable failures, approvals and optional highlighting.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local Layout = require("chat_layout")
local suite = F.suite("UI audit")
local case, check = suite.case, suite.check
local function has(value, needle) return tostring(value):find(needle, 1, true) ~= nil end

case("lexer failure preserves editable source, preview text and recovery", function()
	local f = F.ui()
	local lexer = f.env.require("runtime/code_lexer")
	local scan, richWindow = lexer.scan, lexer.richWindow
	lexer.scan = function() error("fixture lexer failure") end
	lexer.richWindow = function() error("fixture formatter failure") end
	local store = f.env.require("runtime/code_store")
	local doc = store.active()
	assert(store.update(doc.id, 'local x = "<tag>"\nreturn x'))
	local editor = f.env.require("ui/code/editor").new(f.host)
	editor.select(doc); f.h.settle(0.2)
	check("editor retains exact source", editor.box.Text == doc.source)
	check("plain editor text remains escaped", has(f.h.textOf(editor.root), "&lt;tag&gt;"))
	editor.box.Text = 'local x = "<changed>"\nreturn x'
	f.h.settle(0.2)
	check("typing still publishes the source", doc.source == editor.box.Text and has(f.h.textOf(editor.root), "&lt;changed&gt;"))
	local field = f.env.require("ui/primitives").field(f.host, { text = 'return "<preview>"', multiline = true, syntax = false })
	local preview = f.env.require("ui/code/syntax").attach(field.instance, "lua")
	f.h.settle(0.2)
	check("preview remains readable and escaped", has(f.h.textOf(field.shell), "&lt;preview&gt;"))
	lexer.scan, lexer.richWindow = scan, richWindow
	editor.box.Text = "local restored = 1\nreturn restored"; f.h.settle(0.2)
	check("highlighting recovers on the next edit", has(f.h.textOf(editor.root), "<font"))
	f.healthy(); preview.destroy(); editor.destroy(); f.close()
end)

case("permission arguments remain complete and every dismissal settles once", function()
	local f = F.ui()
	local sessions = f.env.require("agent/session")
	local session = sessions.newThread()
	local permissions = f.env.require("ui/panels/permission"); permissions.watch()
	local overlay = f.env.require("ui/overlay")
	local code = string.rep("print('review this line')\n", 100) .. "error('final_review_marker')"
	local answers = {}
	local function ask(id, args)
		sessions.anyEvent:fire(session, { kind = "permission:ask", id = id, name = "run_luau", risk = "danger", args = args,
			resolve = function(allowed) answers[#answers + 1] = { id = id, allowed = allowed } end })
	end
	ask("allow", { code = code, timeout = 10 }); ask("deny", {})
	f.h.click(f.h.byName("ReviewPermissionArguments", f.env.root))
	check("full argument viewer includes content after the former cap", has(f.h.textOf(overlay.open[#overlay.open].card), "final_review_marker"))
	check("reviewing does not decide", #answers == 0)
	overlay.open[#overlay.open].close(); f.h.settle(0.2)
	f.h.click(f.h.byName("PermissionAllow", f.env.root)); f.h.settle(0.2)
	check("Allow settles only the first request", #answers == 1 and answers[1].id == "allow" and answers[1].allowed)
	check("queued empty argument prompt is explicit", f.h.byName("NoArguments", f.env.root) ~= nil)
	f.h.click(f.h.byName("PermissionDeny", f.env.root)); f.h.settle(0.2)
	check("Deny settles the queued request once", #answers == 2 and answers[2].id == "deny" and not answers[2].allowed)
	check("decisions release all registered overlays", #overlay.open == 0 and not permissions.showing)
	ask("dismiss", {}); overlay.open[#overlay.open].close(); f.h.settle(0.2)
	check("close settles one refusal", #answers == 3 and answers[3].id == "dismiss" and not answers[3].allowed and not permissions.showing)
	f.healthy(); f.close()
end)

case("failures flag Latest and reveal complete orphan results on demand", function()
	local f = F.ui()
	local session = f.env.require("agent/session").newThread()
	local view = f.env.require("ui/chat/view").new(f.host)
	view.attach(session); Layout.settle(f.h, view, 0.3)
	session.emit("user", { text = "Inspect this failure" }); Layout.settle(f.h, view, 0.2)
	view.pinned = false
	local detail = string.rep("traceback line\n", 30) .. "final_failure_marker"
	session.emit("tool:result", { id = "orphan", name = "run_luau", ok = false, text = detail, ms = 10 })
	f.h.settle(0.05)
	local event = session.log[#session.log]
	local row, run = view.rows[event.transcriptId], view.run
	check("orphan outcome retains a tracked tool row", row and row.finish and run.failures == 1)
	check("failure preserves disclosure choice", not run.rows.Visible)
	check("failure increments Latest", has(f.h.textOf(f.h.byName("Latest", f.host)), "1 failure"))
	f.h.click(f.h.byName("ShowFailures", run.root)); f.h.settle(0.1)
	check("one action opens the failure chain", run.rows.Visible and row.isOpen())
	check("failure body is not folded at twelve lines", has(f.h.byName("Source", row.root).Text, "final_failure_marker"))
	f.h.click(f.h.byName("Copy", row.root))
	check("failure decoration retains the entire original result", event.text:sub(1, #detail) == detail)
	check("Copy retains the complete displayed result", f.h.sandbox.__clipboard == event.text)
	view.setVisible(false); view.setVisible(true); Layout.settle(f.h, view, 0.2)
	check("return preserves the result row and disclosure", view.rows[event.transcriptId] == row and row.isOpen())
	f.healthy(); view.destroy(); f.close()
end)

case("output logs render literally even when the lexer fails", function()
	local f = F.ui()
	f.env.require("runtime/code_lexer").highlight = function() error("fixture lexer failure") end
	local runner = f.env.require("tools/code_runner")
	runner.runs[1] = { id = "fixture-run", name = "Fixture", revision = 1, status = "runtime_error", output = {}, result = { text = "<error>\ncomplete output" } }
	local output = f.env.require("ui/code/output").new(f.host)
	local label = f.h.byName("OutputText", output.root)
	check("output text is literal", not label.RichText and has(label.Text, "<error>\ncomplete output"))
	f.healthy(); output.destroy(); f.close()
end)

suite.finish()
