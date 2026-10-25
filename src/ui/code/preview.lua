-- Copyable native source preview with the same bounded syntax as editable code.
return function(env)
	local P = env.require("ui/primitives")
	local theme = env.require("ui/theme")
	local metrics = env.require("ui/code/metrics")
	local lexer = env.require("ui/code/highlight")
	local M = {}
	function M.new(parent, source, name)
		local scroll = P.scroll(parent, { name = name or "SourcePreview", bg = theme.color.codeSurface })
		scroll.layout:Destroy(); scroll.instance.AutomaticCanvasSize = Enum.AutomaticSize.None; scroll.instance.ScrollingDirection = Enum.ScrollingDirection.XY
		local field = P.field(scroll.instance, { name = "PreviewText", role = "mono", multiline = true, bare = true, text = source, padX = theme.space.xl / 2 })
		field.instance.TextEditable, field.instance.TextWrapped = false, false
		field.instance.TextColor3 = theme.color.codeText
		local lines, widths, sourceWidth = lexer.lines(source), {}, 0
		for _, line in ipairs(lines) do
			widths[line] = widths[line] or metrics.line(line).width
			sourceWidth = math.max(sourceWidth, widths[line])
		end
		local lineCount = #lines
		local function layout()
			local width = math.max(scroll.instance.AbsoluteSize.X, sourceWidth + theme.space.md * 2)
			local height = math.max(scroll.instance.AbsoluteSize.Y, lineCount * field.syntax.lineHeight + theme.space.md * 2)
			field.shell.Size, scroll.instance.CanvasSize = UDim2.fromOffset(width, height), UDim2.fromOffset(width, height)
		end
		field.syntax.onLineHeight = layout
		scroll.instance:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout); layout()
		return { root = scroll.instance, box = field.instance, destroy = function() scroll.instance:Destroy() end }
	end
	return M
end
