-- Edit individual credentials through the real provider controls; all keys are synthetic.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("coding_fixture")
local suite = F.suite("Provider key entries")
local case, check = suite.case, suite.check

local function click(f, name)
	f.h.click(assert(f.h.byName(name), "missing " .. name)); f.h.settle(0.2)
end

local function fixture(raw, saved)
	local f = F.ui(390, 700)
	f.registry = f.env.require("provider/registry")
	f.record = f.registry.blank("custom")
	f.record.label, f.record.baseUrl = "Key entry fixture", "https://keys.fixture/v1"
	f.record.apiKey, f.record.model, f.record.models = raw, "fixture-model", { "fixture-model" }
	if saved then assert(f.registry.save(f.record)) end
	f.env.require("ui/panels/providers").editor(f.record, function(id) f.saved = f.registry.get(id) end)
	f.h.settle(0.3)
	return f
end

local function submitKey(f, control, text)
	click(f, control)
	local field = assert(f.h.byName("PromptField")):FindFirstChildOfClass("TextBox")
	check("credential prompts never prefill a saved secret", field.Text == "")
	field.Text = text
	f.h.settle(0.1)
	local surfaces = f.env.require("ui/overlay").open
	for _, node in ipairs(surfaces[#surfaces].footer:GetDescendants()) do
		if node.ClassName == "TextLabel" and node.Text == "Save key" then
			local button = node.Parent
			while button and button.ClassName ~= "TextButton" do button = button.Parent end
			assert(button, "missing key confirmation")
			f.h.click(button); f.h.settle(0.3)
			return
		end
	end
	error("missing Save key button")
end

case("replacing the middle of a legacy key pool preserves every other credential", function()
	local raw = "fixture-first-1111, fixture-second-2222\nfixture-third-3333\nfixture-first-1111"
	local f = fixture(raw, true)
	for index = 1, 3 do
		check("legacy key " .. index .. " gets an individual entry", f.h.byName("APIKeyLabel_" .. index).Text == "API key " .. index)
	end
	check("duplicate legacy credentials do not create extra entries", f.h.byName("APIKey_4") == nil)
	check("opening the editor masks every stored credential", not f.h.textOf():find("fixture-first", 1, true)
		and not f.h.textOf():find("fixture-second", 1, true) and not f.h.textOf():find("fixture-third", 1, true))
	submitKey(f, "ReplaceKey_2", "fixture-replacement-4444")
	check("only the second entry's mask changes", f.h.byName("APIKeyMask_1").Text:find("1111", 1, true)
		and f.h.byName("APIKeyMask_2").Text:find("4444", 1, true) and f.h.byName("APIKeyMask_3").Text:find("3333", 1, true))
	check("a draft replacement cannot change saved credentials", f.registry.get(f.record.id).apiKey == raw)
	click(f, "SaveProvider")
	check("saving retains ordered untouched keys", f.saved and f.saved.apiKey == "fixture-first-1111\nfixture-replacement-4444\nfixture-third-3333")
	check("existing rotation uses the edited pool", f.registry.nextKey(f.saved) == "fixture-first-1111"
		and f.registry.nextKey(f.saved) == "fixture-replacement-4444" and f.registry.nextKey(f.saved) == "fixture-third-3333"
		and f.registry.nextKey(f.saved) == "fixture-first-1111")
	check("editing and saving send no provider requests", f.h.http.requestCount == 0)
	f.healthy(); f.close()
end)

case("bulk additions append and removing a row only removes that key", function()
	local f = fixture("fixture-first-1111\nfixture-second-2222\nfixture-third-3333")
	submitKey(f, "SetKey", "fixture-fourth-4444, fixture-fifth-5555\nfixture-first-1111")
	check("bulk paste appends unique keys", f.h.byName("APIKey_5") ~= nil and f.h.byName("APIKey_6") == nil)
	click(f, "RemoveKey_2")
	check("remaining rows are numbered in order", f.h.byName("APIKeyLabel_4").Text == "API key 4" and f.h.byName("APIKey_5") == nil
		and f.h.byName("APIKeyMask_2").Text:find("3333", 1, true))
	submitKey(f, "SetKey", "fixture-sixth-6666")
	click(f, "SaveProvider")
	check("add and remove preserve unrelated keys", f.saved and f.saved.apiKey == "fixture-first-1111\nfixture-third-3333\nfixture-fourth-4444\nfixture-fifth-5555\nfixture-sixth-6666")
	f.healthy(); f.close()
end)

case("short credentials stay masked in both numbered entries and the pool summary", function()
	local f = fixture("k11\nk222")
	local visible = f.h.textOf()
	check("the pool summary never reveals a complete short credential", not visible:find("k11", 1, true) and not visible:find("k222", 1, true))
	check("numbered entries only acknowledge that short credentials are set", f.h.byName("APIKeyMask_1").Text == "set"
		and f.h.byName("APIKeyMask_2").Text == "set")
	click(f, "ReplaceKey_1")
	-- The existing harness submits Enter here, exercising the single-line prompt's
	-- keyboard confirmation independently of the Save key button used above.
	f.h.type(f.h.byName("PromptField"):FindFirstChildOfClass("TextBox"), "k333")
	f.h.settle(0.2)
	check("Enter confirms exactly one replacement and closes its prompt", f.h.byName("PromptField") == nil
		and not f.h.textOf():find("k333", 1, true))
	click(f, "SaveProvider")
	check("masking and keyboard replacement preserve the other key", f.saved and f.saved.apiKey == "k333\nk222")
	f.healthy(); f.close()
end)

case("empty, duplicate and multiple replacement values leave the pool intact", function()
	local original = "fixture-first-1111\nfixture-second-2222"
	local f = fixture(original)
	submitKey(f, "ReplaceKey_1", "   ")
	submitKey(f, "ReplaceKey_1", "fixture-second-2222")
	submitKey(f, "ReplaceKey_1", "fixture-other-3333,fixture-another-4444")
	submitKey(f, "SetKey", "fixture-first-1111\nfixture-second-2222")
	click(f, "SaveProvider")
	check("invalid replacements cannot silently delete an entry", f.saved and f.saved.apiKey == original)
	f.healthy(); f.close()
end)

case("cancelled prompts and dismissed saved-provider edits preserve stored keys", function()
	local original = "fixture-first-1111\nfixture-second-2222"
	local f = fixture(original, true)
	click(f, "ReplaceKey_1")
	f.h.byName("PromptField"):FindFirstChildOfClass("TextBox").Text = "fixture-cancelled-3333"
	f.h.press("Escape"); f.h.settle(0.3)
	check("cancelling replacement keeps the original entry", f.h.byName("APIKeyMask_1").Text:find("1111", 1, true))
	submitKey(f, "ReplaceKey_2", "fixture-unsaved-4444")
	click(f, "RemoveKey_1")
	f.h.press("Escape"); f.h.settle(0.3)
	check("closing connection edits keeps the saved pool", f.registry.get(f.record.id).apiKey == original)
	check("cancelled edits never saved a new record", f.saved == nil and f.registry.count() == 1)
	f.healthy(); f.close()
end)

case("new-provider drafts retain all keys and allow further additions after reopening", function()
	local f = fixture("fixture-first-1111")
	local additions = {}
	for index = 2, 40 do additions[#additions + 1] = "fixture-key-" .. index end
	submitKey(f, "SetKey", table.concat(additions, "\n"))
	check("key additions have no small fixed row limit", f.h.byName("APIKeyLabel_40").Text == "API key 40")
	f.h.press("Escape"); f.h.settle(0.3)
	f.env.require("ui/panels/providers").add(function(id) f.saved = f.registry.get(id) end)
	f.h.settle(0.3)
	check("reopening a new connection keeps the complete draft", f.h.byName("APIKey_40") ~= nil and f.registry.count() == 0)
	submitKey(f, "SetKey", "fixture-key-41")
	click(f, "SaveProvider")
	check("saving includes every retained and newly appended key", f.saved and #f.registry.keysOf(f.saved) == 41
		and f.registry.keysOf(f.saved)[1] == "fixture-first-1111" and f.registry.keysOf(f.saved)[41] == "fixture-key-41")
	f.healthy(); f.close()
end)

case("removing the last required key stays a draft until access is restored", function()
	local f = fixture("fixture-first-1111", true)
	click(f, "RemoveKey_1")
	click(f, "SaveProvider")
	check("a required empty pool cannot replace a saved credential", f.saved == nil and f.h.byName("Problem").Visible
		and f.registry.get(f.record.id).apiKey == "fixture-first-1111")
	submitKey(f, "SetKey", "fixture-restored-2222")
	click(f, "SaveProvider")
	check("the emptied draft can be repaired and saved", f.saved and f.saved.apiKey == "fixture-restored-2222")
	f.healthy(); f.close()
end)

suite.finish()
