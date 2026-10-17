-- Unload must not rebuild UI from callbacks queued before destruction.
package.path = "test/?.lua;test/mock/?.lua;" .. package.path
local envMock = require("env")
local suite = require("workspace_fixture").suite("App unload")

for _, eager in ipairs({ false, true }) do
	suite.case(eager and "unload with parent-first destruction callbacks" or "unload with queued appearance changes", function()
		local h = envMock.new()
		local uai = assert(h.boot())
		local app = uai.env.require("ui/app")
		app.show("code")
		uai.env.require("ui/overlay").modal({ title = "Unload fixture" })
		h.settle(0.7)
		local window = app.window
		-- Both debounce producers have a pending callback when unload begins.
		uai.config.set("ui.accent", "amber")
		uai.config.set("ui.showToolDetail", not uai.config.get("ui.showToolDetail"))
		if eager then
			-- Roblox fires Destroying before removing children/Parent. The default
			-- mock does the reverse; exercise this ordering locally as well.
			local function prepare(node)
				for _, child in ipairs(node:GetChildren()) do prepare(child) end
				rawset(node, "Destroy", function(self)
					if rawget(self, "__destroyed") then return end
					rawset(self, "__destroyed", true)
					self.Destroying:Fire()
					for _, child in ipairs(self:GetChildren()) do child:Destroy() end
					self.Parent = nil
				end)
			end
			prepare(app.screen)
		end
		uai.destroy()
		local created = h.instanceState.count
		h.settle(3)
		suite.check("queued rebuilds do not create controls after unload", h.instanceState.count == created)
		suite.check("queued callbacks do not replace the old window", app.window == window)
		suite.check("all lifetime resources drain once", not uai.cleanupFailed and uai.env.require("runtime/dispose").count() == 0 and uai.destroy() == 0)
		suite.check("the interface stays removed", h.screen() == nil)
		suite.check("late callbacks leave no scheduler errors", #h.errors() == 0)
	end)
end

suite.finish()
