-- Review pending messages without interrupting the active conversation worker.
return function(env)
	local util = env.require("runtime/util")
	local clock = env.require("runtime/clock")
	local sessions = env.require("agent/session")
	local theme = env.require("ui/theme")
	local P = env.require("ui/primitives")
	local overlay = env.require("ui/overlay")
	local M = {}
	local opened

	function M.open(session)
		if not session or session.removed then return end
		if opened and not opened.closed then opened.close() end
		local unsubscribes, scheduled, closed = {}, false, false
		local function cleanup()
			if closed then return end
			closed = true
			for _, unsubscribe in ipairs(unsubscribes) do unsubscribe() end
		end
		local modal = overlay.modal({ title = "Queued messages", width = theme.size.modalWide,
			description = "Follow-ups join after the current response or tool batch.", scroll = true, onClose = cleanup })
		if not modal then return end
		opened = modal
		modal.card.Name = "MessageQueue"
		local status = P.text(modal.content, { name = "QueueStatus", text = "", role = "small",
			wrap = true, auto = "Y", layoutOrder = 1, size = UDim2.new(1, 0, 0, 0) })
		local rows = P.column(modal.content, { name = "QueuedItems", auto = "Y", gap = theme.space.sm,
			size = UDim2.new(1, 0, 0, 0), layoutOrder = 2 })
		local resume = P.button(modal.footer, { name = "ResumeQueue", text = "Resume queued", variant = "primary", size = "sm",
			onClick = function()
				local ok, why = session.resumeQueue()
				if not ok then overlay.toast(tostring(why), "warn", 4) end
			end })
		P.button(modal.footer, { name = "QueueDone", text = "Done", variant = "ghost", size = "sm", layoutOrder = 2,
			onClick = function() modal.close() end })
		local function refresh()
			if closed or modal.closed then return end
			local current = sessions.current()
			if session.removed or not current or current.id ~= session.id then modal.close(); return end
			local pending = session.queueSnapshot()
			status.Text = pending.count == 0 and "No messages waiting."
				or pending.held and ("Waiting: " .. tostring(pending.reason or "Work stopped") .. ". Resume when ready.")
				or (tostring(pending.count) .. " queued. The active agent keeps working.")
			resume.instance.Visible = pending.count > 0 and pending.held == true
			resume.setEnabled(not session.busy and not session.preparing)
			for _, child in ipairs(rows:GetChildren()) do if child:IsA("GuiObject") then child:Destroy() end end
			for index, item in ipairs(pending.items) do
				local entry = P.column(rows, { name = "Queued_" .. item.id, auto = "Y", gap = theme.space.xs,
					size = UDim2.new(1, 0, 0, 0), layoutOrder = index })
				local imageCount = #(item.images or {})
				P.text(entry, { text = tostring(index) .. ". " .. (item.state == "preparing" and "Preparing" or "Queued")
					.. (imageCount > 0 and (" · " .. util.pluralise(imageCount, "image")) or ""), role = "caption",
					color = theme.color.textSecondary, auto = "Y", size = UDim2.new(1, 0, 0, 0), layoutOrder = 1 })
				P.text(entry, { text = util.ellipsis(item.text or "", 2000), role = "small", wrap = true,
					auto = "Y", size = UDim2.new(1, 0, 0, 0), layoutOrder = 2 })
				P.button(entry, { name = "RemoveQueued_" .. item.id, text = "Remove", variant = "ghost", size = "sm", layoutOrder = 3,
					onClick = function()
						local ok, why = session.removeQueued(item.id)
						if not ok then overlay.toast(tostring(why), "warn", 3) end
					end })
			end
		end
		local function queue()
			if scheduled or closed or modal.closed then return end
			scheduled = true
			clock.delay(0.05, function() scheduled = false; refresh() end)
		end
		unsubscribes[#unsubscribes + 1] = session.events:connect(function(event)
			if event.kind:sub(1, 8) == "message:" or event.kind == "queue:state" or event.kind == "status" then queue() end
		end)
		unsubscribes[#unsubscribes + 1] = sessions.listChanged:connect(queue)
		modal.scrim.Destroying:Connect(cleanup)
		refresh()
		return modal
	end
	return M
end
