local view = require("../lib/lake/view")
local wallpaper = require("../lib/wallpaper")

local SKIN = table.freeze({
    fill = "#ffffff12", raised = "#ffffff1f", text = view.foreground, secondary = view.secondary,
    muted = view.secondary, border = "#ffffff24", accent = "#a78bfa", accentText = "#1e1033",
    chip = "#a78bfa33", chipText = "#ede9fe", hover = "#ffffff22", subtle = "#ffffff14",
})

local function compact(ctx)
    local data = wallpaper.state(ctx)
    local main = data and wallpaper.mainDisplay(data)
    local text = if main then wallpaper.shownText(main) else omniwm.l10n("Wallpaper")
    return view.compact(ctx, "photo.on.rectangle", text, "#a78bfa")
end

local function expanded(ctx)
    local width = math.max(1, math.min(ctx.view.w or 640, 640) - 48)
    return ui.column{ align = "top", dy = (ctx.view.props or {}).top or 0, wallpaper.panel(ctx, SKIN, width) }
end

return { views = { compact = compact, expanded = expanded }, activity = function()
    return { priority = 0, label = omniwm.l10n("Wallpaper") }
end }
