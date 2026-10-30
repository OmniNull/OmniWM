local service = require("../lib/lake/services/calendar")
local view = require("../lib/lake/view")

local function compact(ctx)
    local data = service.snapshot(ctx)
    return view.compact(ctx, "calendar", if data and data.access == "full" then tostring(#data.events) .. (if #data.events == 1 then " event" else " events") else "—", "#fda4af")
end

local function expanded(ctx)
    local data = service.snapshot(ctx)
    local rows = { gap = 12, align = "top", dy = (ctx.view.props or {}).top or 0 }
    if not data then rows[1] = ui.text{ text = "Calendar unavailable", color = view.secondary }
    elseif data.access ~= "full" then
        rows[1] = ui.text{ text = "Calendar access: " .. data.access, color = view.secondary }
        rows[2] = view.button("lock.open", if data.access == "notDetermined" then service.authorize else service.settings)
    else
        for index, event in data.events do
            if index > 4 then break end
            rows[#rows + 1] = ui.row{ key = event.id .. ":" .. tostring(event.start), gap = 12,
                w = math.max(1, (ctx.view.w or 520) - 48), onClick = function() service.open(event.id) end,
                hover = "#ffffff12", pressScale = 0.98,
                ui.box{ w = 3, h = 28, radius = 1.5, fill = event.color or "#fda4af" },
                ui.column{ gap = 3, center = false, grow = 1,
                    ui.text{ text = event.title, color = view.foreground, size = 13, maxWidth = 330 },
                    ui.text{ text = event.day .. " · " .. event.time, color = view.secondary, size = 11 } } }
        end
        if #data.events == 0 then rows[1] = ui.text{ text = "No upcoming events", color = view.secondary } end
    end
    local failure = service.error(ctx.instance)
    if failure then
        rows[#rows + 1] = ui.text{ text = failure, maxWidth = 360, size = 11, color = "#fda4af" }
        rows[#rows + 1] = view.button("arrow.clockwise", function(next) service.retry(next.instance) end)
    end
    return ui.column(rows)
end

return { init = service.initialize, deinit = service.cancel, options = service.options,
    views = { compact = compact, expanded = expanded }, activity = service.activity }
