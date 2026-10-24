-- Localized interface strings.
--
-- The interface is authored in English and every user-visible string is looked up
-- here before it reaches an Instance. Lookup is an exact match on the whole string,
-- never a substring rewrite: a table keyed by the rendered sentence cannot damage a
-- config path, an instance name or a code snippet that happens to contain an English
-- word. Dynamic copy keeps its numbers through %{name} placeholders, so a translated
-- sentence controls its own word order instead of being glued together in code.
--
-- A missing entry falls back to the English source and is recorded in misses, which
-- is what tools/zh_audit.py reads to prove the table is complete.
return function(env)
	local config = env.require("runtime/config")
	local zh = env.require("runtime/locale_zh")

	local M = {}

	-- One entry per locale that ships a pack. "en" is the authored source, so it
	-- needs no table; naming it here keeps the switcher honest.
	local PACKS = { zh = zh }
	local NAMES = { zh = "中文", en = "English" }
	M.misses = {}
	M.hits = 0

	local cache = {}

	function M.locale()
		local value = tostring(config.get("ui.locale", "zh") or "zh")
		if value == "en" or PACKS[value] then return value end
		return "zh"
	end

	function M.locales()
		local out = {}
		for _, id in ipairs({ "zh", "en" }) do
			out[#out + 1] = { id = id, label = NAMES[id] }
		end
		return out
	end

	-- Fill %{key} from vars. A value that is itself a translation is the caller's
	-- business; numbers arrive already formatted so a locale can place the unit.
	local function fill(text, vars)
		if not vars then return text end
		return (text:gsub("%%{([%w_]+)}", function(key)
			local value = vars[key]
			if value == nil then return "%{" .. key .. "}" end
			return tostring(value)
		end))
	end

	function M.t(text, vars)
		if type(text) ~= "string" or text == "" then return text end
		local locale = M.locale()
		if locale == "en" then return fill(text, vars) end
		local pack = PACKS[locale]
		if not pack then return fill(text, vars) end

		local translated = cache[text]
		if translated == nil then
			translated = pack[text] or false
			cache[text] = translated
		end
		if translated then
			M.hits = M.hits + 1
			return fill(translated, vars)
		end

		-- Untranslated: keep the source visible rather than blanking a label, and keep
		-- a record so the gap can be closed instead of argued about.
		if #text > 1 and text:find("%a") then
			M.misses[text] = (M.misses[text] or 0) + 1
		end
		return fill(text, vars)
	end

	-- A stable, sorted gap list -- the audit compares this against the rendered UI.
	function M.report()
		local out = {}
		for text, count in pairs(M.misses) do out[#out + 1] = { text = text, count = count } end
		table.sort(out, function(a, b) return a.text < b.text end)
		return out
	end

	-- Changing the locale goes through config so the switch survives a restart; the
	-- app watches the same path and rebuilds, which is how a rebuild-on-open surface
	-- picks up the new language without a second code path.
	function M.set(locale)
		if locale ~= "en" and not PACKS[locale] then return false end
		config.set("ui.locale", locale)
		return true
	end

	function M.installed()
		local count = 0
		for _ in pairs(zh) do count = count + 1 end
		return count
	end

	return M
end
