local service = require("../lib/lake/services/reminders")
local view = require("../lib/lake/view")

return { views = { compact = function(ctx)
    local data = service.snapshot(ctx)
    return view.compact(ctx, "checklist", if data and data.access == "full" then tostring(data.total) else "—", "#fcd34d")
end, expanded = function(ctx)
    local data = service.snapshot(ctx)
    local rows = { gap = 10, align = "top", dy = (ctx.view.props or {}).top or 0 }
    if not data then rows[1] = ui.text{ text = "Reminders unavailable", color = view.secondary }
    elseif data.access ~= "full" then
        rows[1] = ui.text{ text = "Reminders access: " .. data.access, color = view.secondary }
        rows[2] = view.button("lock.open", if data.access == "notDetermined" then service.authorize else service.settings)
    else
        for index, item in data.items do
            if index > 4 then break end
            local due = item.due and ctx.format.date(item.due, if item.allDay then "MMMd" else "MMMdjmm")
            rows[#rows + 1] = ui.row{ key = item.id, gap = 12,
                if item.canComplete then view.button("circle", function() service.complete(item.id) end)
                    else ui.symbol{ name = "lock", size = 16, color = view.secondary },
                ui.column{ center = false, gap = 3,
                    ui.text{ text = item.title, maxWidth = 320, size = 13, color = view.foreground },
                    ui.text{ text = item.list .. (if due then " · " .. due else ""), maxWidth = 320, size = 11, color = view.secondary } } }
        end
        if #data.items == 0 then rows[1] = ui.text{ text = "No incomplete reminders", color = view.secondary } end
        if data.total > 4 then rows[#rows + 1] = ui.text{ text = tostring(data.total) .. " incomplete" .. (if data.truncated then " · list limited" else ""), size = 11, color = view.secondary } end
    end
    if data and data.error then rows[#rows + 1] = ui.text{ text = data.error, maxWidth = 420, size = 11, color = "#fda4af" } end
    return ui.column(rows)
end }, activity = service.activity }
