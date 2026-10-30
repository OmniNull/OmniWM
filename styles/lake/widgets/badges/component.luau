local service = require("../lib/lake/services/badges")
local view = require("../lib/lake/view")

return { views = { compact = function(ctx)
    local badges = service.snapshot(ctx)
    return view.compact(ctx, "app.badge", badges and tostring(#badges) .. " apps" or "—", "#c4b5fd")
end, expanded = function(ctx)
    local badges = service.snapshot(ctx)
    local rows = { gap = 12, align = "top", dy = (ctx.view.props or {}).top or 0 }
    if not badges then rows[1] = ui.text{ text = "Badges unavailable", color = view.secondary }
    elseif #badges == 0 then rows[1] = ui.text{ text = "No app badges", color = view.secondary }
    else
        for index, item in badges do
            if index > 5 then break end
            rows[#rows + 1] = ui.row{ key = item.bundle, w = math.max(1, (ctx.view.w or 520) - 48), gap = 14,
                ui.text{ text = item.bundle, grow = 1, maxWidth = 330, size = 12, color = view.secondary },
                ui.text{ text = item.label, size = 16, color = "#c4b5fd", maxWidth = 90 } }
        end
        if #badges > 5 then rows[#rows + 1] = ui.text{ text = "+" .. tostring(#badges - 5) .. " more apps", size = 11, color = view.secondary } end
    end
    return ui.column(rows)
end }, activity = service.activity }
