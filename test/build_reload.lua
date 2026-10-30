-- Build identity and re-execution regressions against the shipping bundle.
-- Run after bundling: luajit test/build_reload.lua
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local luau = require("luau")
local buildId = dofile("tools/build_id.lua")
local passed = 0
local function check(label, value)
	assert(value, label)
	passed = passed + 1
	print("ok " .. label)
end
local fixture = { { id = "ui/test", source = "return function()\nreturn 1\nend\n" } }
local base = buildId("1.0", fixture, "return true\n")
check("fingerprint is reproducible", base == buildId("1.0", fixture, "return true\n"))
check("fingerprint ignores CRLF and trailing whitespace", base == buildId("1.0", { { id = "ui/test", source = "return function()\r\nreturn 1\r\nend\r\n" } }, "return true\r\n"))
check("fingerprint changes with module content", base ~= buildId("1.0", { { id = "ui/test", source = "return 2" } }, "return true"))
check("fingerprint changes with bootstrap", base ~= buildId("1.0", fixture, "return false"))
check("fingerprint changes with version", base ~= buildId("1.1", fixture, "return true"))
check("fingerprint changes with module identity", base ~= buildId("1.0", { { id = "ui/other", source = fixture[1].source } }, "return true"))

local file = assert(io.open("dist/uai.lua", "rb"))
local source = file:read("*a")
file:close()
local identity = assert(source:match('local __UAI_BUILD = "([^"]+)"'))
local manifestFile = assert(io.open("dist/uai.manifest.json", "rb"))
local manifest = require("json").decode(manifestFile:read("*a")); manifestFile:close()
check("module manifest belongs to the generated bundle", manifest.buildId == identity and manifest.hashAlgorithm == "uai-dual32-v1" and #manifest.modules > 0)
local previousId = ""
for _, entry in ipairs(manifest.modules) do
	assert(entry.id > previousId and entry.bytes >= 0 and type(entry.hash) == "string", "manifest modules must be ordered and individually identified")
	previousId = entry.id
end
check("module manifest uses canonical order", previousId ~= "")
local PASSWORD = "reload fixture master password"
local function cheapDerive(client)
	local crypto = client.env.require("runtime/credential_crypto")
	local sha = client.env.require("runtime/credential_sha256")
	crypto.derive = function(password, salt, _, progress)
		if progress and progress(0, 2) == false then return nil, crypto.error end
		local key = sha.digest(password .. "\0" .. salt) .. sha.digest(salt .. "\0" .. password)
		if progress and progress(2, 2) == false then return nil, crypto.error end
		return key
	end
end
local function authenticate(harness, handle)
	cheapDerive(handle)
	local status = handle.config.vaultStatus()
	if status.ready then return end
	local result
	harness.sched.spawn(function()
		result = { (status.enabled and handle.config.unlockVault or handle.config.enableVault)(PASSWORD) }
	end)
	harness.settle(1)
	assert(result and result[1], result and result[2] or "reload fixture password operation did not complete")
end
local function boot(harness, id, hostContext, leaveGated)
	local body = source
	if id then body = body:gsub('local __UAI_BUILD = "[^"]+"', 'local __UAI_BUILD = "' .. id .. '"', 1) end
	local chunk, errors = luau.load(body, "reload-test", { entry = true })
	assert(chunk, errors and errors[1] and errors[1].msg)
	setfenv(chunk, harness.sandbox)
	local handle = assert(chunk(hostContext))
	harness.settle(1)
	-- General reload checks run after real envelope authentication with a cheap
	-- fixture KDF. Dedicated cases below leave the shipping startup gate intact.
	if not leaveGated and handle.alive and not handle.reloadBlocked then authenticate(harness, handle) end
	return handle
end
local function screenCount(harness)
	local count = 0
	for _, item in ipairs(harness.coreGui:GetChildren()) do
		if item:IsA("ScreenGui") and item.Name:match("^UAI_") then count = count + 1 end
	end
	return count
end
local harness = envMock.new()
local originalContext = { prompt = "Embedded instructions", hooks = { preTool = function() return true end } }
local first = boot(harness, nil, originalContext)
check("handle and runtime expose build identity", first.build == identity and first.env.info.build == identity)
local toggles = 0
local toggle = first.toggle
first.toggle = function() toggles = toggles + 1; toggle() end
local same = boot(harness)
check("same build returns the existing handle and toggles once", same == first and toggles == 1 and first.alive)
check("same build leaves exactly one screen", screenCount(harness) == 1)

first.config.set("agent.customInstructions", "Preserve settings on update", { transient = true })
local session = first.sessions.current()
session.title = "Saved across reload"
session.ctx.pushUser("Keep this conversation")
session.emit("user", { text = "Keep this conversation" })
local oldId, oldScreen = session.id, first.app.screen
local nextBuild = identity .. "-changed"
local updated = boot(harness, nextBuild)
check("changed build replaces the idle instance", updated ~= first and updated.build == nextBuild and updated.alive and not first.alive)
check("old screen detaches before replacement", oldScreen.Parent == nil and screenCount(harness) == 1)
check("config survives reload including previously unsaved settings", updated.config.get("agent.customInstructions") == "Preserve settings on update")
local restored = updated.sessions.threads[oldId]
check("conversation identity and title survive reload", restored and restored.title == "Saved across reload")
check("conversation context survives reload", restored.ctx.last("user").content == "Keep this conversation")
check("conversation transcript survives reload", restored.log[1] and restored.log[1].text == "Keep this conversation")
check("reloaded handle becomes global owner", harness.sandbox.UAI == updated)
check("reload preserves embedding context when no new context is provided", updated.env.context == originalContext)

local running = updated.sessions.newThread()
running.busy = true
running.abortFlag = false
local currentBuild = updated.build
local deferred = boot(harness, identity .. "-busy")
check("busy request remains on its existing build", deferred == updated and updated.build == currentBuild and updated.alive)
check("busy reload never aborts running work", running.busy and running.abortFlag == false)
check("busy reload records pending update", updated.pendingBuild == identity .. "-busy")
check("busy reload explains how to apply the update", harness.textOf():find("Let the current work finish", 1, true) ~= nil)
running.busy = false
local replacementContext = { prompt = "Updated embedding" }
local afterWork = boot(harness, identity .. "-busy", replacementContext)
check("rerunning after work finishes applies pending build", afterWork ~= updated and afterWork.build == identity .. "-busy")

check("explicit new embedding context takes precedence", afterWork.env.context == replacementContext)
local children = afterWork.env.require("agent/subagent")
children.records = { { id = "queued-test", status = "queued" } }
check("queued subagent also defers update", boot(harness, identity .. "-children") == afterWork and afterWork.alive)
children.records = {}

local composer = afterWork.app.chatPanel.composer
composer.field.set("Unsent work")
check("composer draft defers a changed build", boot(harness, identity .. "-draft") == afterWork and composer.field.get() == "Unsent work")
check("draft deferral gives a specific explanation", harness.textOf():find("draft and attachments", 1, true) ~= nil)
check("same build still toggles with a pending draft", boot(harness, afterWork.build) == afterWork and composer.field.get() == "Unsent work")
composer.field.clear()
composer.attachments = { { label = "unsent.lua", text = "return 1" } }
check("pending attachments defer a changed build", boot(harness, identity .. "-attachment") == afterWork and #composer.attachments == 1)
composer.attachments = {}
local draftedSession = afterWork.sessions.current()
composer.field.set("Background conversation draft")
local emptySession = afterWork.sessions.newThread()
afterWork.app.openSession(emptySession.id)
check("switching away leaves the active composer empty", composer.field.get() == "")
check("background conversation draft also defers update", boot(harness, identity .. "-background-draft") == afterWork and afterWork.alive)
afterWork.app.openSession(draftedSession.id)
check("deferred background draft stays intact", composer.field.get() == "Background conversation draft")
composer.field.clear()
local quick = afterWork.env.require("ui/quickchat")
quick.field.set("Quick draft")
check("Quick Chat draft defers a changed build", boot(harness, identity .. "-quick") == afterWork and quick.field.get() == "Quick draft")
quick.field.clear()
local chatFixture = require("gamechat")(harness)
afterWork.env.services.TextChatService = harness.services.TextChatService
afterWork.config.set("permissions.mode", "full")
local chatLoops = afterWork.env.require("runtime/chatloops")
assert(chatLoops.start("auto", { messages = { "Live loop" } }, afterWork.sessions.current().toolContext()))
check("live chat loop defers a changed build", boot(harness, identity .. "-chat-loop") == afterWork and afterWork.alive)
chatLoops.stop()
local isolated = afterWork.sessions.newThread()
isolated.setEphemeral(true)
isolated.ctx.pushUser("Private unsaved conversation")
check("populated isolated conversation defers update", boot(harness, identity .. "-isolated") == afterWork and isolated.ephemeral and isolated.ctx.last("user").content == "Private unsaved conversation")
check("isolated deferral gives a specific explanation", harness.textOf():find("isolated conversations", 1, true) ~= nil)
isolated.setEphemeral(false)

local save = afterWork.config.saveNow
afterWork.config.saveNow = function() return false end
check("save failure leaves old client alive", boot(harness, identity .. "-save-failed") == afterWork and afterWork.alive and screenCount(harness) == 1)
afterWork.config.saveNow = save

local dispose = afterWork.env.require("runtime/dispose")
dispose.add(function() error("simulated cleanup failure") end, "reload-test")
local blocked = boot(harness, identity .. "-cleanup-failed")
check("cleanup failure prevents replacement", blocked == afterWork and afterWork.cleanupFailed and afterWork.reloadBlocked)
check("cleanup failure retains a guard without a duplicate screen", harness.sandbox.UAI == afterWork and screenCount(harness) == 0)
check("rerun after failed cleanup cannot mount a duplicate", boot(harness, identity .. "-retry") == afterWork and screenCount(harness) == 0)

local throwingHarness = envMock.new()
local throwing = boot(throwingHarness)
throwing.destroy = function() error("simulated destroy failure") end
check("throwing destroy cannot mount a second instance", boot(throwingHarness, identity .. "-throw") == throwing and throwing.reloadBlocked and screenCount(throwingHarness) == 1)

local legacyHarness = envMock.new()
local legacy = boot(legacyHarness)
legacy.build = nil
local replacedLegacy = boot(legacyHarness)
check("legacy handle without build metadata is replaced", replacedLegacy ~= legacy and replacedLegacy.build == identity and not legacy.alive)

-- Encrypted credentials must survive loader replacement and authenticated restart.
-- The sentinels below are synthetic and are never sent to an upstream service.
local credentialHarness = envMock.new()
local credentialContext = { ui = false, reuse = true }
local credentialClient = boot(credentialHarness, nil, credentialContext)
check("new client requires encrypted remembered credentials", credentialClient.config.get("security.rememberCredentials") == true
	and credentialClient.config.vaultStatus().ready and credentialClient.config.vaultStatus().enabled)
check("required encryption cannot switch to session-only storage", credentialClient.config.setRememberCredentials(false) == false)
local privateRecord = credentialClient.providers.blank("custom")
privateRecord.id, privateRecord.label = "reload-private-fixture", "Reload credential fixture"
privateRecord.baseUrl = "https://reload.fixture/v1?access_token=reload-url-private"
privateRecord.wsUrl = "wss://reload.fixture/socket?session=reload-socket-private"
privateRecord.apiKey = "reload-key-one\nreload-key-two"
privateRecord.keyNames = { "Reload first key", "Reload second key" }
privateRecord.keyIds = { "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222" }
privateRecord.keyPaused, privateRecord.keyMode, privateRecord.selectedKey = { true, false }, "single", 2
privateRecord.model, privateRecord.models = "fixture-model", { "fixture-model" }
privateRecord.headers = { Authorization = "Bearer reload-header-key", ["X-Fixture-Auth"] = "reload-header-private" }
privateRecord.query = { token = "reload-query-private", routing = "reload-query-route" }
privateRecord.params = { access_token = "reload-body-private", temperature = 0.2 }
assert(credentialClient.providers.save(privateRecord))
credentialClient.providers.setActive(privateRecord.id)
credentialClient.config.set("identity.extraHeaders", { ["X-Fixture-Identity"] = "reload-identity-private" })
assert(credentialClient.config.saveNow())
local function credentialData(client)
	local record = assert(client.providers.get(privateRecord.id))
	return { apiKey = record.apiKey, keyNames = record.keyNames, keyIds = record.keyIds,
		keyPaused = record.keyPaused, keyMode = record.keyMode, selectedKey = record.selectedKey,
		headers = record.headers, query = record.query, params = record.params,
		baseUrl = record.baseUrl, wsUrl = record.wsUrl, authStyle = record.authStyle,
		identity = client.config.get("identity.extraHeaders") }
end
local function sameCredentialData(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do if not sameCredentialData(value, right[key]) then return false end end
	for key in pairs(right) do if left[key] == nil then return false end end
	return true
end
local expectedCredentials = credentialClient.env.require("runtime/util").deepCopy(credentialData(credentialClient))
-- Unloading an encrypted client deliberately clears its live provider objects.
-- Keep an independent fixture template for the separate vault-lifecycle case.
local privateTemplate = credentialClient.env.require("runtime/util").deepCopy(privateRecord)
local privateValues = { "reload-key-one", "reload-key-two", "reload-header-key", "reload-header-private",
	"reload-query-private", "reload-query-route", "reload-body-private", "reload-url-private",
	"reload-socket-private", "reload-identity-private", "Reload first key", "Reload second key",
	"11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222" }
local function diskOmitsCredentials()
	local disk = credentialHarness.files["UAI/config.json"]
	if type(disk) ~= "string" then return false end
	for _, value in ipairs(privateValues) do if disk:find(value, 1, true) then return false end end
	return true
end
check("encrypted save excludes every private connection sentinel from disk", diskOmitsCredentials())
local sameCredentials = boot(credentialHarness, nil, credentialContext)
check("same-build reuse preserves the exact key pool and connection metadata", sameCredentials == credentialClient
	and sameCredentialData(credentialData(sameCredentials), expectedCredentials) and diskOmitsCredentials())
local credentialSave = credentialClient.config.saveNow
credentialClient.config.saveNow = function() return false end
local failedCredentials = boot(credentialHarness, identity .. "-credential-save-failed", credentialContext)
check("failed credential replacement keeps the live instance and all session credentials", failedCredentials == credentialClient
	and credentialClient.alive and sameCredentialData(credentialData(credentialClient), expectedCredentials) and diskOmitsCredentials())
credentialClient.config.saveNow = credentialSave
local credentialBuild = identity .. "-credential-handoff"
local handedOff = boot(credentialHarness, credentialBuild, credentialContext)
check("changed-build handoff preserves exact key pool, metadata and custom credentials", handedOff ~= credentialClient
	and handedOff.alive and not credentialClient.alive and sameCredentialData(credentialData(handedOff), expectedCredentials))
check("changed-build handoff never writes plaintext credentials to disk", diskOmitsCredentials())
handedOff.destroy()
check("genuine unload removes the live client owner while retaining ciphertext", not handedOff.alive
	and credentialHarness.sandbox.UAI == nil and diskOmitsCredentials())
local freshCredentials = boot(credentialHarness, credentialBuild, credentialContext, true)
local freshRecord = assert(freshCredentials.providers.get(privateRecord.id))
check("a genuine new boot requires a password before exposing credentials", freshCredentials ~= handedOff
	and freshRecord.apiKey == "" and freshCredentials.config.vaultStatus().locked
	and type(freshCredentials.providers.protocolProblem(freshRecord)) == "string")
authenticate(credentialHarness, freshCredentials)
check("genuine restart restores all encrypted connection fields after authentication", sameCredentialData(credentialData(freshCredentials), expectedCredentials)
	and diskOmitsCredentials())
check("credential replacement scenarios have no asynchronous errors", #credentialHarness.errors() == 0)
freshCredentials.destroy()

-- Private key handoff never grants access to a newly executed build. UI-disabled
-- embedding still mounts the mandatory prompt and authenticates each execution.
local vaultHarness = envMock.new()
local vaultClient = boot(vaultHarness, nil, credentialContext, true)
local vaultPassword = PASSWORD
local function vaultCall(method, ...)
	local args, result = { ... }, nil
	vaultHarness.sched.spawn(function() result = { method(unpack(args)) } end)
	vaultHarness.sched.advance(1)
	assert(result, "vault reload fixture operation did not complete")
	return unpack(result)
end
cheapDerive(vaultClient)
assert(vaultCall(vaultClient.config.enableVault, vaultPassword))
local vaultRecord = vaultClient.env.require("runtime/util").deepCopy(privateTemplate)
assert(vaultClient.providers.save(vaultRecord))
vaultClient.providers.setActive(vaultRecord.id)
vaultClient.config.set("identity.extraHeaders", { ["X-Fixture-Identity"] = "reload-identity-private" })
assert(vaultClient.config.saveNow())
local vaultExpected = vaultClient.env.require("runtime/util").deepCopy(credentialData(vaultClient))
local vaultUpdated = boot(vaultHarness, identity .. "-vault-handoff", credentialContext, true)
check("changed-build replacement retains vault data but requires authentication", vaultUpdated ~= vaultClient and not vaultClient.alive
	and vaultUpdated.config.vaultStatus().enabled and not vaultUpdated.config.vaultStatus().ready)
authenticate(vaultHarness, vaultUpdated)
check("vault handoff retains exact key pool and authentication fields", sameCredentialData(credentialData(vaultUpdated), vaultExpected))
local vaultDisk = vaultHarness.files["UAI/config.json"]
local vaultSaved = vaultHarness.json.decode(vaultDisk)
check("vault handoff persists ciphertext without its password or session key", type(vaultSaved.credentialVault) == "table"
	and vaultSaved.credentialVault.key == nil and not vaultDisk:find(vaultPassword, 1, true)
	and not vaultDisk:find("reload-key-one", 1, true) and not vaultDisk:find("reload-identity-private", 1, true))
vaultUpdated.destroy()
local vaultCold = boot(vaultHarness, identity .. "-vault-handoff", credentialContext, true)
check("genuine vault restart stays locked and mounts required password UI", vaultCold.config.vaultStatus().locked
	and vaultCold.providers.get(privateRecord.id).apiKey == "" and vaultCold.uiMounted
	and vaultCold.env.loadedModules["ui/credentialvault"] ~= nil)
cheapDerive(vaultCold)
assert(vaultCall(vaultCold.config.unlockVault, vaultPassword))
check("explicit unlock after a genuine restart restores exact credentials", sameCredentialData(credentialData(vaultCold), vaultExpected))
check("vault replacement and cold unlock have no asynchronous errors", #vaultHarness.errors() == 0)
local unsavedVault = vaultCold.providers.get(privateRecord.id)
unsavedVault.headers["X-Fixture-Auth"] = "reload-header-before-unload"
unsavedVault.keyNames[2] = "Renamed before unload"
vaultCold.config.save()
vaultCold.destroy()
local finalVaultBoot = boot(vaultHarness, identity .. "-vault-handoff", credentialContext, true)
cheapDerive(finalVaultBoot)
assert(vaultCall(finalVaultBoot.config.unlockVault, vaultPassword))
local finalVaultRecord = finalVaultBoot.providers.get(privateRecord.id)
check("unload before the debounce preserves the newest encrypted credential edits", finalVaultRecord.headers["X-Fixture-Auth"] == "reload-header-before-unload"
	and finalVaultRecord.keyNames[2] == "Renamed before unload" and finalVaultRecord.apiKey == vaultExpected.apiKey)
check("final unload save never exposes unsaved credentials in plaintext", not vaultHarness.files["UAI/config.json"]:find("reload-header-before-unload", 1, true))
finalVaultBoot.destroy()

local volatileHarness = envMock.new()
local volatile = boot(volatileHarness)
volatile.env.require("runtime/fsx").enabled = false
check("host without persistence keeps in-memory state", boot(volatileHarness, identity .. "-volatile") == volatile and volatile.alive)
check("successful update paths have no asynchronous errors", #harness.errors() == 0 and #legacyHarness.errors() == 0)
print("build reload: " .. passed .. " checks passed")
