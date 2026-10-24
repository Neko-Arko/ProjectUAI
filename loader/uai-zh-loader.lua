-- UAI 中文版加载器（国内网络 + 手机可用）
--
-- 取包顺序：内存缓存 → 本地文件 → 多个镜像。每一层都做内容校验，镜像返回的
-- HTML 错误页、只下了一半的残包都会被跳过，不会把半截代码执行掉。
--
-- 桌面执行器与 Android 执行器的文件 API 并不一致：有的只有 readfile/writefile、
-- 没有 isfile；有的没有 makefolder，只能在已存在的目录里写。所以这里不依赖某一个
-- 具体函数，而是逐个尝试、失败就降级，最差也会退回到「每次都下载」。
--
--   桌面 / 手机通用：把本文件整段粘进执行器跑一次即可
--   手机建议先设好缓存路径（见下），避免每次都下 3.6 MB
--
--   自定义缓存位置（找不到文件时很有用）：
--     getgenv().UAI_CACHE_PATH = "/sdcard/Download/uai-zh.lua"
--   强制重新下载：
--     getgenv().UAI_FORCE_UPDATE = true

local REF = "14330e3"
local MIN_BYTES = 1000000 -- 完整包约 3.6 MB；小于这个数一定是坏了

local SOURCES = {
	"https://testingcf.jsdelivr.net/gh/Neko-Arko/ProjectUAI@" .. REF .. "/dist/uai.lua",
	"https://ghfast.top/https://raw.githubusercontent.com/Neko-Arko/ProjectUAI/" .. REF .. "/dist/uai.lua",
	"https://fastly.jsdelivr.net/gh/Neko-Arko/ProjectUAI@" .. REF .. "/dist/uai.lua",
	"https://raw.githubusercontent.com/Neko-Arko/ProjectUAI/" .. REF .. "/dist/uai.lua",
}

local function log(message)
	print("[UAI] " .. tostring(message))
end

local function globals()
	if type(getgenv) == "function" then
		local ok, value = pcall(getgenv)
		if ok and type(value) == "table" then return value end
	end
	return _G
end

local G = globals()

-- 往 getgenv() 里放东西只是加速，不是前提：个别环境给的是一张只读表，
-- 直接赋值会抛错并让整个加载失败，所以统一用 pcall 包起来。
local function remember(body)
	pcall(function() G.__UAI_ZH_BUNDLE = body end)
end

-- 内容校验：文件头、长度、以及必须像一段 Lua。
local function looksValid(body)
	if type(body) ~= "string" or #body < MIN_BYTES then return false end
	if body:sub(1, 2) ~= "--" then return false end
	if not body:find("Project UAI", 1, true) then return false end
	if body:find("<!DOCTYPE", 1, true) or body:find("<html", 1, true) then return false end
	return true
end

-- 候选路径：先用户指定的，再执行器工作区的常规位置，最后是根目录。
-- Android 上 writefile("UAI/...") 在目录不存在时经常直接失败，所以根目录也要试。
local function cachePaths()
	local list = {}
	local override = G.UAI_CACHE_PATH
	if type(override) == "string" and override ~= "" then list[#list + 1] = override end
	list[#list + 1] = "UAI/uai-zh.lua"
	list[#list + 1] = "uai-zh.lua"
	return list
end

local function readAny()
	if type(readfile) ~= "function" then return nil end
	for _, path in ipairs(cachePaths()) do
		local ok, body = pcall(readfile, path)
		if ok and looksValid(body) then return body, path end
	end
	return nil
end

-- 不假设 makefolder / isfolder 存在：能建就建，建不了就直接写，写不进去就算了。
-- 缓存只是加速手段，失败不该拦住启动。
local function writeAny(body)
	if type(writefile) ~= "function" then return false end
	for _, path in ipairs(cachePaths()) do
		local folder = path:match("^(.*)/[^/]+$")
		if folder and folder ~= "" then
			pcall(function()
				if type(makefolder) == "function" then
					local exists = type(isfolder) == "function" and isfolder(folder) or false
					if not exists then makefolder(folder) end
				end
			end)
		end
		if pcall(writefile, path, body) then
			log("已缓存到 " .. path)
			return true, path
		end
	end
	return false
end

local function run(body)
	local chunk, err = loadstring(body, "=uai")
	if not chunk then error("[UAI] 代码解析失败：" .. tostring(err), 0) end
	return chunk()
end

local forced = G.UAI_FORCE_UPDATE == true

if not forced then
	-- 1) 内存缓存：同一次执行器会话里反复重载时，连磁盘都不用碰。
	if looksValid(G.__UAI_ZH_BUNDLE) then
		log("从内存缓存加载")
		return run(G.__UAI_ZH_BUNDLE)
	end
	-- 2) 本地文件：手机上一次下载之后就走这里，完全离线。
	local cached, path = readAny()
	if cached then
		remember(cached)
		log("从本地文件加载：" .. tostring(path))
		return run(cached)
	end
end

local problems = {}
for index, url in ipairs(SOURCES) do
	log(string.format("下载中 %d/%d …", index, #SOURCES))
	local ok, body = pcall(function() return game:HttpGet(url, true) end)
	if ok and looksValid(body) then
		log(string.format("下载完成：%d 字节", #body))
		remember(body)
		writeAny(body)
		return run(body)
	end
	local reason = ok and ("内容不完整或不是代码，收到 " .. tostring(type(body) == "string" and #body or 0) .. " 字节")
		or tostring(body)
	problems[#problems + 1] = url .. "  ->  " .. reason
	log("该源不可用，换下一个")
end

error("[UAI] 所有下载源都失败了：\n  " .. table.concat(problems, "\n  ")
	.. "\n\n手机端建议：用浏览器打开上面的地址下载 uai-zh.lua，放进执行器能读到的目录，"
	.. "\n然后设置 getgenv().UAI_CACHE_PATH = \"<该文件的绝对路径>\" 再运行本加载器。", 0)
