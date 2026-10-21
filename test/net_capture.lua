-- Network and payload capture. Every request and compile here is mocked; no
-- Roblox traffic or real executor function is touched.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Network capture")
local case, check = suite.case, suite.check

-- A tiny hook engine for the fixture. The real client calls hookfunction; the
-- mock makes request/loadstring/load/require hookable so the capture wrappers
-- can be exercised without an executor.
local function install(f)
	local s = f.h.sandbox
	local state = { wrapper = {}, original = {} }
	local function hookable(impl)
		local fn
		fn = function(...)
			local wrapper = state.wrapper[fn]
			if wrapper then return wrapper(...) end
			return impl(...)
		end
		state.original[fn] = impl
		return fn
	end
	local function replace(name, impl)
		local fn = hookable(impl)
		s[name] = fn
		return fn
	end
	local originalRequest = assert(s.request)
	replace("request", function(options) return originalRequest(options) end)
	local originalLoad = assert(s.loadstring)
	replace("loadstring", function(source, name) return originalLoad(source, name) end)
	if type(s.load) == "function" then
		local originalLoadFn = s.load
		replace("load", function(...) return originalLoadFn(...) end)
	end
	local originalRequire = s.require
	if type(originalRequire) == "function" then
		replace("require", function(...) return originalRequire(...) end)
	end
	local game = f.h.game
	local originalGet = assert(game.HttpGet)
	game.HttpGet = hookable(function(self, url) return originalGet(self, url) end)
	local hs = f.h.services.HttpService
	for _, name in ipairs({ "RequestAsync", "GetAsync", "PostAsync" }) do
		local original = hs[name]
		if type(original) == "function" then
			hs[name] = hookable(function(...) return original(...) end)
		end
	end
	s.hookfunction = function(fn, wrapper)
		if state.failRestore then error("restore failed", 0) end
		if not state.original[fn] then
			-- The lifecycle probe hooks a local function. A function this fixture
			-- did not replace is reported as hooked but cannot be observed; tests
			-- only rely on the replaced request/compile targets.
			return function(...) return fn(...) end
		end
		state.wrapper[fn] = wrapper
		return function(...) return state.original[fn](...) end
	end
	s.newcclosure = function(fn) return fn end
	s.checkcaller = function() return true end
	return state
end

local function fixture(toolGroups)
	local f = F.new()
	local state = install(f)
	f.h.http.handler = function()
		return { StatusCode = 200, Body = "fixture body", Headers = { ["content-type"] = "text/plain" } }
	end
	f.tools(toolGroups or { "net_capture" })
	return f, state
end

local function start(f, options)
	options = options or {}
	options.action = "start"
	local result = f.dispatch("net_capture", options)
	check("capture starts", result.ok and result.data.status == "running")
	return result
end

local function list(f, options)
	options = options or {}
	options.action = "list"
	return f.dispatch("net_capture_read", options)
end

local function recordsOf(kind, f)
	local result = list(f, { kind = kind, limit = 20 })
	return result.data.items
end

case("HTTP capture records foreign traffic, redacts secrets and excludes UAI requests", function()
	local f, state = fixture({ "net_capture", "net" })
	start(f, { mode = "http", duration = 60 })
	check("request is the installed target", state.wrapper[f.h.sandbox.request] ~= nil)
	f.h.http.handler = function(entry)
		if entry.url:find("uai.example", 1, true) then
			return { StatusCode = 200, Body = "UAI", Headers = {} }
		end
		return { StatusCode = 200, Body = "PAYLOAD", Headers = { ["content-type"] = "text/plain" } }
	end
	local response = f.run(function()
		return f.h.sandbox.request({
			Url = "https://api.example.com/v1/load?token=secret&mode=full",
			Method = "POST",
			Headers = { Authorization = "Bearer abc", ["X-Test"] = "yes" },
			Body = "hello",
		})
	end)
	check("forwarding preserves the response", response.Body == "PAYLOAD" and response.StatusCode == 200)

	local uai = f.dispatch("http_get", { url = "https://uai.example.com/models" })
	check("UAI's own request succeeds", uai.ok and uai.data.totalBytes == 3)

	local page = list(f)
	check("only the foreign request is recorded", page.ok and #page.data.items == 1)
	local item = page.data.items[1]
	check("method, status and alias are recorded", item.method == "POST" and item.status == 200 and item.alias == "request")
	check("sensitive query values are redacted", item.url:find("token=<redacted>", 1, true) ~= nil
		and item.url:find("secret", 1, true) == nil and item.url:find("mode=full", 1, true) ~= nil)
	local body = f.dispatch("net_capture_read", { action = "read", record_id = item.id, section = "response" })
	check("response body is readable", body.ok and body.text:find("PAYLOAD", 1, true) ~= nil)
	local request = f.dispatch("net_capture_read", { action = "read", record_id = item.id, section = "request" })
	check("request body is readable", request.ok and request.text:find("hello", 1, true) ~= nil)
	local headers = f.dispatch("net_capture_read", { action = "read", record_id = item.id, section = "headers" })
	check("authorization is redacted in headers", headers.ok and headers.text:find("<redacted>", 1, true) ~= nil
		and headers.text:find("Bearer abc", 1, true) == nil)
	local summary = f.dispatch("net_capture_read", { action = "read", record_id = item.id, section = "summary" })
	check("summary carries sizes and duration", summary.ok and summary.text:find("Response bytes: 7", 1, true) ~= nil)

	local stopped = f.dispatch("net_capture", { action = "stop" })
	check("stop reports restored hooks", stopped.ok and stopped.text:find("restored", 1, true) ~= nil)
	f.run(function()
		f.h.sandbox.request({ Url = "https://api.example.com/after", Method = "GET" })
	end)
	check("requests after stop are not recorded", #list(f).data.items == 1)
	f.healthy(); f.close()
end)

case("chunk capture links a compiled response to the request that produced it", function()
	local f = fixture()
	start(f, { mode = "both", duration = 60 })
	f.h.http.handler = function(entry)
		if entry.url:find("stage1", 1, true) then
			return { StatusCode = 200, Body = "return 42", Headers = {} }
		end
		return { StatusCode = 200, Body = "return 7", Headers = {} }
	end
	local value = f.run(function()
		local s = f.h.sandbox
		local response = s.request({ Url = "https://cdn.example.com/stage1.lua", Method = "GET" })
		local compiled = assert(s.loadstring(response.Body, "@stage1"))
		return compiled()
	end)
	check("the loader still executes and returns its value", value == 42)
	local items = list(f, { limit = 20 }).data.items
	check("request and chunk are both retained", #items == 2)
	local http, chunk
	for _, item in ipairs(items) do
		if item.kind == "http" then http = item elseif item.kind == "chunk" then chunk = item end
	end
	check("the chunk compiled and carries its hash", chunk and chunk.compileOk == true and chunk.sourceBytes == 9 and chunk.hash)
	check("the chunk is linked to the HTTP record", chunk.parentId == http.id and chunk.link == "hash")
	local source = f.dispatch("net_capture_read", { action = "read", record_id = chunk.id, section = "chunk" })
	check("chunk source is readable", source.ok and source.text:find("return 42", 1, true) ~= nil)
	local chain = f.dispatch("net_capture_read", { action = "chain" })
	check("chain renders the parent and child", chain.ok and chain.text:find("HTTP GET https://cdn.example.com/stage1.lua", 1, true)
		and chain.text:find("CHUNK", 1, true))
	f.healthy(); f.close()
end)

case("HttpService methods and require failures are observed without changing results", function()
	local f = fixture()
	start(f, { mode = "both", duration = 60 })
	f.h.http.handler = function() return { StatusCode = 201, Body = "created", Headers = {} } end
	local response = f.run(function()
		return f.h.services.HttpService:RequestAsync({ Url = "https://api.example.com/hs", Method = "POST", Body = "x" })
	end)
	check("HttpService still returns its response", response.StatusCode == 201 and response.Body == "created")
	local http = recordsOf("http", f)
	check("HttpService method is recorded", #http == 1 and http[1].alias == "HttpService:RequestAsync"
		and http[1].method == "POST" and http[1].status == 201)
	local module = f.h.Instance.new("ModuleScript")
	module.Parent = f.h.workspace
	local ok, err = pcall(function() return f.h.sandbox.require(module) end)
	check("require still raises its original error", not ok and type(err) == "string")
	local modules = recordsOf("module", f)
	check("failed require is retained with provenance", #modules == 1 and modules[1].sourceStatus == "require failed"
		and modules[1].className == "ModuleScript")
	f.healthy(); f.close()
end)

case("load and failed loadstring are captured without changing their results", function()
	local f = fixture()
	start(f, { mode = "chunks", duration = 60 })
	local seven = f.run(function() return assert(f.h.sandbox.load("return 7"))() end)
	check("load still returns its chunk value", seven == 7)
	local fn, err = f.run(function() return f.h.sandbox.loadstring("return )") end)
	check("a compile error still returns nil and a message", fn == nil and type(err) == "string")
	local reader = f.run(function()
		local produced = false
		local compiled = assert(f.h.sandbox.load(function() if produced then return nil end; produced = true; return "return 9" end))
		return compiled() == 9
	end)
	check("a reader-based load still executes", reader == true)
	local items = recordsOf("chunk", f)
	check("both compile entries are retained", #items >= 2)
	local failed, readerRecord
	for _, item in ipairs(items) do
		if item.name == "loadstring" and item.compileOk == false then failed = item end
		if item.sourceStatus == "reader" then readerRecord = item end
	end
	check("the failed compile is marked, not dropped", failed and type(failed.compileError) == "string"
		and failed.compileError:find("unexpected symbol", 1, true) ~= nil)
	check("a reader is recorded without consuming it", readerRecord and readerRecord.sourceStatus == "reader"
		and readerRecord.compileOk == false)
	f.healthy(); f.close()
end)

case("UAI compiles are excluded and a transformed payload falls back to thread linking", function()
	local f = fixture()
	start(f, { mode = "both", duration = 60 })
	f.h.http.handler = function(entry)
		if entry.url:find("stage", 1, true) then return { StatusCode = 200, Body = "return 1", Headers = {} } end
		return { StatusCode = 200, Body = "return 2", Headers = {} }
	end
	f.run(function()
		return f.env.require("runtime/caps").fn.loadstring("return 'uai'", "=uai")
	end)
	check("a client compile is not recorded", #recordsOf("chunk", f) == 0)
	local value = f.run(function()
		local s = f.h.sandbox
		s.request({ Url = "https://cdn.example.com/stage.lua", Method = "GET" })
		local compiled = assert(s.loadstring("return 43", "@rewritten"))
		return compiled()
	end)
	check("the transformed chunk still executes", value == 43)
	local items = list(f, { limit = 20 }).data.items
	check("the HTTP request and rewritten chunk are retained", #items == 2)
	local chunk
	for _, item in ipairs(items) do if item.kind == "chunk" then chunk = item end end
	check("a hash mismatch links by the same thread", chunk and chunk.link == "thread" and chunk.parentId ~= nil)
	f.healthy(); f.close()
end)

case("binary bodies are repaired for output but keep their raw hash and byte count", function()
	local f = fixture()
	start(f, { mode = "http", duration = 60 })
	local binary = string.char(255, 254, 0, 1) .. "text"
	f.h.http.handler = function() return { StatusCode = 200, Body = binary, Headers = {} } end
	f.run(function() f.h.sandbox.request({ Url = "https://api.example.com/bin", Method = "GET" }) end)
	local item = list(f).data.items[1]
	check("the raw byte count is retained", item.responseBytes == #binary and item.binary == true)
	local page = f.dispatch("net_capture_read", { action = "read", record_id = item.id, section = "response" })
	check("binary output is valid UTF-8 after repair", page.ok and f.env.require("runtime/util").validUtf8(page.text))
	local store = f.env.require("runtime/net_store")
	check("the record hash covers the original bytes", type(store.hash(binary)) == "string"
		and store.hash(binary) == store.hash(string.char(255, 254, 0, 1) .. "text")
		and store.hash(binary) ~= store.hash("text"))
	f.healthy(); f.close()
end)

case("a hook that cannot be restored is reported and forwards without recording", function()
	local f, state = fixture()
	start(f, { mode = "http", duration = 60 })
	f.run(function() f.h.sandbox.request({ Url = "https://api.example.com/one", Method = "GET" }) end)
	state.failRestore = true
	local stopped = f.dispatch("net_capture", { action = "stop" })
	check("stop reports a retained forwarding wrapper", stopped.ok and stopped.text:find("retained", 1, true) ~= nil)
	local retained = 0
	for _, target in ipairs(stopped.data.coverage.targets) do if target.state == "retained" then retained = retained + 1 end end
	check("coverage names the retained hook", retained >= 1)
	f.run(function() f.h.sandbox.request({ Url = "https://api.example.com/two", Method = "GET" }) end)
	check("the retained wrapper still forwards but records nothing", #list(f).data.items == 1)
	local restarted = f.dispatch("net_capture", { action = "start", mode = "http" })
	check("a new capture is refused while a retained hook remains", not restarted.ok
		and restarted.text:find("reload", 1, true) ~= nil)
	f.healthy(); f.close()
end)

case("HttpGet is captured and a code-like response is flagged when nothing compiles it", function()
	local f = fixture()
	start(f, { mode = "http", duration = 60 })
	f.h.http.handler = function()
		return { StatusCode = 200, Body = "local x = 1\nlocal y = 2\nreturn x + y", Headers = {} }
	end
	local body = f.run(function() return f.h.game:HttpGet("https://cdn.example.com/never-compiled.lua") end)
	check("HttpGet still returns the body", body == "local x = 1\nlocal y = 2\nreturn x + y")
	local items = list(f).data.items
	check("HttpGet is recorded as a GET", #items == 1 and items[1].method == "GET" and items[1].alias == "game:HttpGet")
	check("code-like response is flagged without a compiled chunk", items[1].suspectedCode == true)
	check("list text says the payload was not compiled", list(f).text:find("code-like", 1, true) ~= nil)
	f.healthy(); f.close()
end)

case("filters, expiry and bounded retention", function()
	local f = fixture()
	start(f, { mode = "http", host = { "cdn.example.com" }, method = { "POST" }, duration = 1 })
	f.run(function()
		local s = f.h.sandbox
		s.request({ Url = "https://cdn.example.com/get", Method = "GET" })
		s.request({ Url = "https://other.example.com/post", Method = "POST" })
		s.request({ Url = "https://cdn.example.com/post", Method = "POST" })
	end)
	check("host and method filters admit only the exact request", #list(f).data.items == 1)
	f.h.sched.advance(1.1)
	local state = f.dispatch("net_capture", { action = "status" })
	check("duration expires and stops capture", state.data.status == "expired")
	f.run(function() f.h.sandbox.request({ Url = "https://cdn.example.com/after", Method = "POST" }) end)
	check("expired capture records nothing more", #list(f).data.items == 1)
	f.healthy(); f.close()

	local g = fixture()
	start(g, { mode = "http", duration = 60 })
	local store = g.env.require("runtime/net_store")
	store.limits.records = 2
	g.run(function()
		for index = 1, 3 do
			g.h.sandbox.request({ Url = "https://api.example.com/" .. index, Method = "GET" })
		end
	end)
	local page = list(g, { limit = 20 })
	check("record cap keeps only the newest entries", #page.data.items == 2 and page.data.total == 2)
	check("oldest sequence is gone", page.data.items[1].sequence ~= 1)
	g.healthy(); g.close()
end)

case("stop is idempotent, permissions revoke, and missing records fail clearly", function()
	local f = fixture()
	start(f, { mode = "http", duration = 60 })
	f.run(function() f.h.sandbox.request({ Url = "https://api.example.com/one", Method = "GET" }) end)
	f.env.require("agent/registry").setGroupEnabled("net_capture", false)
	f.h.sched.advance(0.6)
	check("disabling the group revokes a live capture", f.env.require("runtime/net_capture").state().status == "revoked")
	f.run(function() f.h.sandbox.request({ Url = "https://api.example.com/two", Method = "GET" }) end)
	f.env.require("agent/registry").setGroupEnabled("net_capture", true)
	check("revoked capture records nothing more", #list(f).data.items == 1)
	local stop = f.dispatch("net_capture", { action = "stop" })
	check("stopping an inactive capture is a clear failure", not stop.ok and stop.text:find("No network capture", 1, true) ~= nil)
	local missing = f.dispatch("net_capture_read", { action = "read", record_id = "missing", section = "summary" })
	check("missing records fail clearly", not missing.ok and missing.text:find("expired", 1, true) ~= nil)
	f.healthy(); f.close()
end)

case("hosts without hooks or a filesystem degrade without breaking the tool group", function()
	local bare = F.new()
	bare.tools({ "net_capture" })
	local unavailable = bare.dispatch("net_capture", { action = "start", mode = "both" })
	check("the tool reports the missing capability", not unavailable.ok and unavailable.error == "capability missing")
	bare.healthy(); bare.close()

	local f = F.new()
	local s = f.h.sandbox
	s.writefile, s.readfile, s.isfile, s.listfiles = nil, nil, nil, nil
	install(f)
	f.tools({ "net_capture" })
	f.h.http.handler = function() return { StatusCode = 200, Body = "body", Headers = {} } end
	start(f, { mode = "http", duration = 60 })
	f.run(function() f.h.sandbox.request({ Url = "https://api.example.com/one", Method = "GET" }) end)
	local exported = f.dispatch("net_capture", { action = "export" })
	check("export without a filesystem fails instead of hiding the capture", not exported.ok and #list(f).data.items == 1)
	f.healthy(); f.close()
end)

case("export writes a verified envelope when the host has a filesystem", function()
	local f = fixture()
	start(f, { mode = "http", duration = 60 })
	f.run(function() f.h.sandbox.request({ Url = "https://api.example.com/one", Method = "GET" }) end)
	local exported = f.dispatch("net_capture", { action = "export" })
	check("export succeeds and verifies its bytes", exported.ok and exported.data.verified == true and exported.data.records == 1)
	check("export reports a files path", type(exported.data.path) == "string" and exported.data.path:find("files/", 1, true) == 1)
	local raw = f.h.sandbox.readfile("UAI/" .. exported.data.path)
	local envelope = f.h.json.decode(raw)
	check("envelope is versioned and contains the record", envelope.format == "uai-net-capture" and envelope.version == 1
		and #envelope.records == 1 and envelope.records[1].host == "api.example.com")
	f.healthy(); f.close()
end)

suite.finish()
