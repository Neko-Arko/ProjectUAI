-- Bounded plain-text search shared by diagnostics and tool discovery.
return function(env)
	local M = {}
	local function fold(value, limit)
		return tostring(value or ""):sub(1, limit):lower():gsub("[_%-]+", " "):gsub("%s+", " ")
	end
	function M.compile(query)
		local text = fold(query, 256):gsub("^%s+", ""):gsub("%s+$", "")
		local words, seen = {}, {}
		for word in text:gmatch("%S+") do
			if not seen[word] then words[#words + 1] = word; seen[word] = true end
			if #words >= 16 then break end
		end
		text = table.concat(words, " ")
		return function(...)
			if #words == 0 then return 0 end
			local fields = {}
			for index = 1, select("#", ...) do fields[index] = fold(select(index, ...), 16384) end
			local score = 0
			for _, word in ipairs(words) do
				local found = false
				for index, field in ipairs(fields) do
					local at = field:find(word, 1, true)
					if at then score = score + (index == 1 and 20 or 1); found = true; break end
				end
				if not found then return nil end
			end
			if fields[1] == text then score = score + 1000
			elseif fields[1] and fields[1]:sub(1, #text) == text then score = score + 100 end
			return score
		end
	end
	return M
end
