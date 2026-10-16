local service = require("../lib/lake/services/shelf")
local shelfView = require("../lib/lake/shelf-view")
local view = require("../lib/lake/view")

local function drop(ctx, event)
    service.add(ctx.instance, event.items)
end

local function hover(ctx, event)
    ctx.state.shelfHover = event.phase == "entered"
end

local function compact(ctx)
    return ui.box{ accepts = { "file", "url", "text", "image" }, onDrop = drop, onDropHover = hover,
        view.compact(ctx, "tray.full.fill", tostring(#service.items(ctx.instance)) .. " items") }
end

local function expanded(ctx)
    local top = (ctx.view.props or {}).top or 0
    local width = math.max(140, math.min(380, (ctx.view.w or 400) - 20))
    local height = math.max(64, (ctx.view.h or 300) - top - 10)
    local error = ctx.state.shelfFormError or service.error(ctx.instance)
    return ui.column{ gap = 10, w = width, h = height, scroll = true, align = "top", dy = top,
        accepts = { "file", "url", "text", "image" }, onDrop = drop, onDropHover = hover,
        ui.row{ gap = 8,
            ui.text{ text = ctx.state.shelfHover and "Drop to keep" or "Shelf", size = 17, weight = "semibold", color = view.foreground },
            ui.text{ text = tostring(#service.items(ctx.instance)) .. " / 32", size = 11, color = view.secondary } },
        ui.row{ gap = 6,
            shelfView.button("Add files", function(next) service.pick(next.instance) end),
            shelfView.button("Paste", function(next) service.paste(next.instance) end),
            shelfView.button("Retry save", function(next) service.retry(next.instance) end),
            shelfView.button("Clear shelf", function(next) service.clear(next.instance) end) },
        error and ui.text{ text = error, size = 11, color = "#fca5a5", maxWidth = width - 10 } or nil,
        shelfView.rows(ctx) }
end

return { init = service.initialize, deinit = service.cancel,
    views = { compact = compact, peek = compact, expanded = expanded },
    activity = function(ctx)
        local count = #service.items(ctx.instance)
        return { priority = count > 0 and 3 or 0, label = tostring(count) .. " shelf items", dropTypes = { "file", "url", "text", "image" } }
    end }
