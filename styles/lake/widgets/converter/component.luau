local service = require("../lib/lake/services/convert")
local shelf = require("../lib/lake/services/shelf")
local shelfView = require("../lib/lake/shelf-view")
local view = require("../lib/lake/view")

local function drop(ctx, event)
    service.accept(ctx.instance, event.items)
end

local function compact(ctx)
    return ui.box{ accepts = { "file", "image" }, onDrop = drop,
        view.compact(ctx, "arrow.triangle.2.circlepath", service.pending(ctx.instance) and "Converting…" or "Convert") }
end

local function expanded(ctx)
    local top = (ctx.view.props or {}).top or 0
    local width = math.max(140, math.min(380, (ctx.view.w or 400) - 20))
    local height = math.max(64, (ctx.view.h or 300) - top - 10)
    local instance = ctx.instance
    local error = service.error(instance)
    local provider = instance.provider
    return ui.column{ gap = 10, w = width, h = height, scroll = true, align = "top", dy = top,
        accepts = { "file", "image" }, onDrop = drop,
        ui.text{ text = "Image converter", size = 17, weight = "semibold", color = view.foreground },
        ui.text{ text = service.status(instance), size = 12, color = view.secondary },
        ui.text{ text = "Provider: " .. provider.status .. (provider.error and " · " .. provider.error or ""), size = 10, color = view.secondary, maxWidth = width - 10 },
        provider.status == "not_approved" and ui.text{ text = omniwm.l10n("Allow this program in Network & Permissions"), size = 10, color = view.secondary } or nil,
        ui.row{ gap = 6,
            shelfView.button("Retry conversion", function(next) service.retry(next.instance) end),
            shelfView.button("Retry save", function(next) shelf.retry(next.instance) end),
            shelfView.button("Clear outputs", function(next) shelf.clear(next.instance) end) },
        error and ui.text{ text = error, size = 11, color = "#fca5a5", maxWidth = width - 10 } or nil,
        shelfView.rows(ctx) }
end

return { init = service.initialize, deinit = service.cancel, options = service.options,
    activity = service.activity, views = { compact = compact, peek = compact, expanded = expanded } }
