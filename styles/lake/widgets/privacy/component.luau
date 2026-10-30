local service = require("../lib/lake/services/privacy")
local view = require("../lib/lake/view")

return { views = { compact = function(ctx)
    local data = service.snapshot(ctx)
    return view.compact(ctx, if data and data.camera then "video.fill" else "mic.fill",
        if data and (data.microphone or data.camera) then "In use" else if data then "Idle" else "—", "#fb923c")
end, expanded = function(ctx)
    local data = service.snapshot(ctx)
    local rows = { gap = 16, align = "top", dy = (ctx.view.props or {}).top or 0,
        ui.text{ text = service.label(data), size = 16, color = view.foreground } }
    if data then
        for _, item in { {"microphone", "mic.fill", "Microphone"}, {"camera", "video.fill", "Camera"} } do
            rows[#rows + 1] = ui.row{ gap = 10,
                ui.symbol{ name = item[2], size = 20, color = if data[item[1]] then "#fb923c" else view.secondary },
                ui.text{ text = item[3] .. (if data[item[1]] then ": in use" else ": idle"), color = view.secondary } }
        end
    end
    return ui.column(rows)
end }, activity = service.activity }
