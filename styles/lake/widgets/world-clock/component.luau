local view = require("../lib/lake/view")
local digits = require("../lib/lake/digits")

local function compact(ctx)
    local options = ctx.instance.options
    return view.compact(ctx, "globe", ctx.format.date(ctx.data.seconds, if options.seconds then "jmmss" else "jmm", options.zone) or "—")
end

local function expanded(ctx)
    local options = ctx.instance.options
    local now = ctx.data.seconds
    local time = ctx.format.date(now, if options.seconds then "jmmss" else "jmm", options.zone) or "Invalid time zone"
    return ui.column{ gap = 12, dy = (ctx.view.props or {}).top or 0, align = "top",
        ui.text{ text = options.label, size = 16, color = view.secondary },
        if options.rollDigits then digits.render(time, { size = 48, color = view.foreground })
            else ui.text{ text = time, size = 48, weight = "light", color = view.foreground },
        ui.text{ text = ctx.format.date(now, "EEEE MMMd", options.zone) or options.zone, size = 13,
            color = view.secondary } }
end

return { views = { compact = compact, expanded = expanded },
    activity = function() return { priority = 1 } end }
