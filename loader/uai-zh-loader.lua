-- UAI 中文版加载器（国内网络可用）
--
-- GitHub 的 raw 域名在国内经常被阻断，所以这里按「本地缓存 → 多个镜像」的顺序取包，
-- 并对内容做校验：镜像返回错误页、被截断、只下了一半，都会被跳过而不是把半截代码执行掉。
--
-- 第一次运行会下载约 3.6 MB 并写入 UAI/uai-zh.lua，之后直接读本地文件，秒开且不联网。
-- 想强制重新下载：getgenv().UAI_FORCE_UPDATE = true 后再运行本脚本。
--
--   用法一（推荐）：把本文件内容整段粘进执行器运行一次
--   用法二：writefile("UAI/uai-loader.lua", 源码) 之后 loadstring(readfile("UAI/uai-loader.lua"))()

local REF = "14330e3" -- 中文版所在提交；更新版本时改这里
local CACHE_DIR = "UAI"
local CACHE_FILE = CACHE_DIR .. "/uai-zh.lua"
local MIN_BYTES = 1000000 -- 完整包约 3.6 MB；小于这个数一定是坏了

-- 顺序即优先级。前两个在你当前的网络下实测可用，后面的留作余额。
local SOURCES = {
	"https://testingcf.jsdelivr.net/gh/Neko-Arko/ProjectUAI@" .. REF .. "/dist/uai.lua",
	"https://ghfast.top/https://raw.githubusercontent.com/Neko-Arko/ProjectUAI/" .. REF .. "/dist/uai.lua",
	"https://fastly.jsdelivr.net/gh/Neko-Arko/ProjectUAI@" .. REF .. "/dist/uai.lua",
	"https://raw.githubusercontent.com/Neko-Arko/ProjectUAI/" .. REF .. "/dist/uai.lua",
}

local function log(message)
	print("[UAI] " .. tostring(message))
end

-- 内容校验：文件头、长度、以及必须像一段 Lua。镜像挂掉时最常见的返回是 HTML 错误页，
-- 它同样以 200 返回，只有校验能拦住。
local function looksValid(body)
	if type(body) ~= "string" or #body < MIN_BYTES then return false end
	if body:sub(1, 2) ~= "--" then return false end
	if not body:find("Project UAI", 1, true) then return false end
	if body:find("<!DOCTYPE", 1, true) or body:find("<html", 1, true) then return false end
	return true
end

local function fileApi()
	return type(readfile) == "function" and type(isfile) == "function" and type(writefile) == "function"
end

local function readCache()
	if not fileApi() then return nil end
	local ok, exists = pcall(isfile, CACHE_FILE)
	if not ok or not exists then return nil end
	local okRead, body = pcall(readfile, CACHE_FILE)
	if okRead and looksValid(body) then return body end
	return nil
end

local function writeCache(body)
	if not fileApi() then return false end
	pcall(function()
		if type(isfolder) == "function" and type(makefolder) == "function" then
			if not isfolder(CACHE_DIR) then makefolder(CACHE_DIR) end
		end
	end)
	local ok = pcall(writefile, CACHE_FILE, body)
	if ok then log("已缓存到 " .. CACHE_FILE) end
	return ok
end

local function run(body)
	local chunk, err = loadstring(body, "=uai")
	if not chunk then error("[UAI] 代码解析失败：" .. tostring(err), 0) end
	return chunk()
end

local forced = type(getgenv) == "function" and getgenv().UAI_FORCE_UPDATE == true

if not forced then
	local cached = readCache()
	if cached then
		log("从本地缓存加载（免联网）。需要更新请设 getgenv().UAI_FORCE_UPDATE = true")
		return run(cached)
	end
end

local problems = {}
for index, url in ipairs(SOURCES) do
	log(string.format("下载中 %d/%d …", index, #SOURCES))
	local ok, body = pcall(function() return game:HttpGet(url, true) end)
	if ok and looksValid(body) then
		log(string.format("下载完成：%d 字节", #body))
		writeCache(body)
		return run(body)
	end
	local reason = ok and ("内容不完整或不是代码，收到 " .. tostring(type(body) == "string" and #body or 0) .. " 字节")
		or tostring(body)
	problems[#problems + 1] = url .. "  ->  " .. reason
	log("该源不可用，换下一个")
end

error("[UAI] 所有下载源都失败了：\n  " .. table.concat(problems, "\n  ")
	.. "\n\n可以把 dist/uai.lua 手动下载后放到 " .. CACHE_FILE .. "，再运行本加载器。", 0)
