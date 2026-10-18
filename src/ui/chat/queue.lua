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
		local unsubscribes, scheduled, closed, editor = {}, false, false, nil
		local entries = {}
		local function cleanup()
			if closed then return end
			closed = true
			if editor and not editor.closed then editor.close() end
			for _, unsubscribe in ipairs(unsubscribes) do unsubscribe() end
		end
		local modal = overlay.modal({ title = "Queued messages", width = theme.size.modalWide,
			description = "Follow-ups join in this order after the current response or tool batch. Your current draft stays in the composer.", scroll = true, onClose = cleanup })
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
		local clear = P.button(modal.footer, { name = "ClearQueue", text = "Clear queued", variant = "ghost", size = "sm", layoutOrder = 2,
			onClick = function()
				local ids = {}; for _, item in ipairs(session.queueSnapshot().items) do ids[#ids + 1] = item.id end
				overlay.confirm({ title = "Clear queued messages?", description = "Remove these " .. tostring(#ids) .. " follow-ups. The active response keeps running.",
					confirmText = "Clear queued", danger = true, onConfirm = function()
						local ok, why = session.clearQueued(ids)
						if not ok then overlay.toast(tostring(why), "warn", 3) end
					end })
			end })
		P.button(modal.footer, { name = "QueueDone", text = "Done", variant = "ghost", size = "sm", layoutOrder = 3,
			onClick = function() modal.close() end })
		local function edit(item)
			if editor and not editor.closed then editor.close() end
			editor = overlay.modal({ title = "Edit follow-up", description = "Changes apply to this queued message. Attached images stay attached.", width = theme.size.modalWide })
			if not editor then return end
			local currentEditor = editor
			local field = P.field(editor.content, { name = "QueuedEditField", text = item.text, multiline = true,
				height = theme.size.promptTextarea, layoutOrder = 1 })
			local notice = P.text(editor.content, { name = "QueuedEditNotice", text = "Up to 8,000 bytes.", role = "caption",
				wrap = true, auto = "Y", size = UDim2.new(1, 0, 0, 0), layoutOrder = 2 })
			P.button(editor.footer, { name = "CancelQueuedEdit", text = "Cancel", variant = "ghost", size = "sm",
				onClick = function() currentEditor.close() end })
			P.button(editor.footer, { name = "SaveQueuedEdit", text = "Save changes", variant = "primary", size = "sm", layoutOrder = 2,
				onClick = function()
					local ok, why = session.editQueued(item.id, field.get(), item.text)
					if ok then currentEditor.close() else notice.Text = tostring(why); notice.TextColor3 = theme.color.warn end
				end })
			field.focus()
		end
		local function refresh()
			if closed or modal.closed then return end
			local current = sessions.current()
			if session.removed or not current or current.id ~= session.id then modal.close(); return end
			local pending = session.queueSnapshot()
			status.Text = pending.count == 0 and "No messages waiting."
				or pending.held and ("Waiting: " .. tostring(pending.reason or "Work stopped") .. ". Resume when ready.")
				or (tostring(pending.count) .. " of " .. tostring(pending.limit) .. " queued. The active agent keeps working.")
			status.TextColor3 = pending.held and theme.color.warn or theme.color.textSecondary
			resume.instance.Visible = pending.count > 0 and pending.held == true
			resume.setEnabled(not session.busy and not session.preparing)
			clear.instance.Visible = pending.count > 0
			local wanted = {}; for _, item in ipairs(pending.items) do wanted[item.id] = true end
			for id, entry in pairs(entries) do if not wanted[id] then entry.frame:Destroy(); entries[id] = nil end end
			for index, item in ipairs(pending.items) do
				local entry = entries[item.id]
				if not entry then
					entry = {}; entries[item.id] = entry
					entry.frame = P.column(rows, { name = "Queued_" .. item.id, auto = "Y", gap = theme.space.xs,
						size = UDim2.new(1, 0, 0, 0), bg = theme.color.surface, radius = theme.radius.md, padding = theme.space.sm })
					P.stroke(entry.frame, theme.color.border)
					entry.status = P.text(entry.frame, { name = "QueuedPosition", text = "", role = "caption",
						color = theme.color.textSecondary, auto = "Y", size = UDim2.new(1, 0, 0, 0), layoutOrder = 1 })
					entry.text = P.text(entry.frame, { name = "QueuedText", text = "", role = "small", wrap = true,
						auto = "Y", size = UDim2.new(1, 0, 0, 0), layoutOrder = 2 })
					local actions = P.row(entry.frame, { auto = "Y", wrap = true, gap = theme.space.xxs, size = UDim2.new(1, 0, 0, 0), layoutOrder = 3 })
					entry.read = P.button(actions, { name = "ReadQueued_" .. item.id, text = "Show full", variant = "ghost", size = "sm",
						onClick = function()
						entry.expanded = not entry.expanded
						entry.text.Text = entry.expanded and entry.item.text or util.ellipsis(entry.item.text, 320)
						entry.read.setText(entry.expanded and "Show less" or "Show full")
						end })
					entry.edit = P.button(actions, { name = "EditQueued_" .. item.id, text = "Edit", variant = "ghost", size = "sm", layoutOrder = 2,
						onClick = function() edit(entry.item) end })
					local function move(direction)
						local neighbor = direction == -1 and entry.previous or entry.next
						local ok, why = session.moveQueued(entry.item.id, direction, neighbor and neighbor.id)
						if not ok then overlay.toast(tostring(why), "warn", 3) end
					end
					entry.up = P.button(actions, { name = "MoveQueuedUp_" .. item.id, text = "Move up", variant = "ghost", size = "sm", layoutOrder = 3,
						onClick = function() move(-1) end })
					entry.down = P.button(actions, { name = "MoveQueuedDown_" .. item.id, text = "Move down", variant = "ghost", size = "sm", layoutOrder = 4,
						onClick = function() move(1) end })
					P.button(actions, { name = "RemoveQueued_" .. item.id, text = "Remove", variant = "ghost", size = "sm", layoutOrder = 5,
						onClick = function()
							local ok, why = session.removeQueued(entry.item.id)
							if not ok then overlay.toast(tostring(why), "warn", 3) end
						end })
				end
				entry.item, entry.previous, entry.next = item, pending.items[index - 1], pending.items[index + 1]
				entry.frame.LayoutOrder = index
				local imageCount, fileCount = #(item.images or {}), #(item.files or {})
				entry.status.Text = tostring(index) .. " of " .. tostring(pending.count) .. " · "
					.. (item.state == "preparing" and "Preparing attachments" or pending.held and "Paused" or index == 1 and "Up next" or "Waiting")
					.. (fileCount > 0 and (" · " .. util.pluralise(fileCount, "file")) or "")
					.. (imageCount > 0 and (" · " .. util.pluralise(imageCount, "image")) or "")
				entry.text.Text = entry.expanded and item.text or util.ellipsis(item.text or "", 320)
				entry.read.instance.Visible = #(item.text or "") > 320
				entry.edit.instance.Visible = item.state == "queued" and fileCount == 0
				entry.up.instance.Visible = entry.previous ~= nil
				entry.down.instance.Visible = entry.next ~= nil
				entry.up.setEnabled(item.state == "queued" and entry.previous and entry.previous.state == "queued")
				entry.down.setEnabled(item.state == "queued" and entry.next and entry.next.state == "queued")
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
