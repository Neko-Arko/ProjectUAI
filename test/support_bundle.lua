-- Support bundle: local diagnostics with credentials and conversations excluded.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local F = require("workspace_fixture")
local suite = F.suite("Support bundle")
local case, check = suite.case, suite.check

local SECRET = "sk-support-secret-1234"
local KEY_NAME = "Private billing account"

local function setup()
	local f = F.new(); f.tools({ "support_bundle" })
	local config = f.env.require("runtime/config")
	config.set("providers.list", {
		{ id = "fixture", label = "Fixture provider", baseUrl = "https://fixture.test/v1",
			apiKey = SECRET, model = "fixture-model", api = "openai", enabled = true,
			keyNames = { KEY_NAME }, keyMode = "single", selectedKey = 1,
			params = { headers = { Authorization = "Bearer " .. SECRET, ["X-Custom"] = "custom-secret" } } },
	})
	config.set("agent.customInstructions", "A local preference")
	f.env.require("runtime/log").error("fixture", "request failed with " .. SECRET)
	local ctx = { session = { id = "s-support" }, aborted = function() return false end }
	return f, ctx
end

case("the bundle contains diagnostics but no credentials or conversation text", function()
	local f, ctx = setup()
	local result = f.dispatch("support_bundle", {}, ctx)
	check("bundle writes and verifies", result.ok and result.data.verified == true and result.data.bytes > 0)
	check("bundle reports a workspace path", type(result.data.path) == "string" and result.data.path:find("files/", 1, true) == 1)
	local raw = f.h.sandbox.readfile("UAI/" .. result.data.path)
	check("the secret is absent from the full file", raw:find(SECRET, 1, true) == nil)
	local bundle = f.h.json.decode(raw)
	check("bundle is versioned", bundle.format == "uai-support" and bundle.version == 1)
	check("provider keys are redacted in config", bundle.config.providers.list[1].apiKey == "<redacted>")
	check("private key names are omitted from diagnostics", bundle.config.providers.list[1].keyNames == nil
		and bundle.providers[1].keyNames == nil and raw:find(KEY_NAME, 1, true) == nil)
	check("diagnostics preserve policy without changing the saved key name", bundle.config.providers.list[1].keyMode == "single"
		and bundle.config.providers.list[1].selectedKey == 1 and f.env.require("runtime/config").get("providers.list")[1].keyNames[1] == KEY_NAME)
	check("custom header values are redacted", bundle.config.providers.list[1].params.headers["X-Custom"] == "<redacted>"
		and raw:find("custom-secret", 1, true) == nil)
	check("provider summary contains health but no key", bundle.providers[1].label == "Fixture provider"
		and bundle.providers[1].apiKey == nil and bundle.providers[1].health ~= nil)
	check("capabilities and tools are present", type(bundle.capabilities.summary) == "string"
		and bundle.tools.stats.total > 0 and bundle.tools.profile == "all")
	check("sessions report metadata only", bundle.sessions.available == true and bundle.sessions.items ~= nil)
	check("conversation text is not collected", raw:find("A local preference", 1, true) == nil)
	check("logs are retained in redacted form", #bundle.logs > 0 and raw:find("sk-...", 1, true) ~= nil)
	f.healthy(); f.close()
end)

case("a host without a filesystem fails without a partial bundle", function()
	local f = F.new()
	local s = f.h.sandbox
	s.writefile, s.readfile, s.isfile, s.listfiles = nil, nil, nil, nil
	f.tools({ "support_bundle" })
	local result = f.dispatch("support_bundle", {}, { session = { id = "s-none" }, aborted = function() return false end })
	check("missing filesystem is reported", not result.ok and result.text:find("not written", 1, true) ~= nil)
	f.healthy(); f.close()
end)

suite.finish()
