local service = require("../lib/lake/services/battery")
local view = require("../lib/lake/view")

return { views = { compact = function(ctx)
    local battery = service.snapshot(ctx)
    return view.compact(ctx, if battery.charging then "bolt.fill" else "battery.100percent", service.label(battery), "#86efac")
end, expanded = function(ctx)
    local battery = service.snapshot(ctx)
    local power = battery.power
    local status = if battery.charging then "Charging" else if power and power.charged then "Charged"
        else if power and power.source == "ac" then "Connected to power" else if battery.level then "On battery" else "AC power"
    local rows = { gap = 12, align = "top", dy = (ctx.view.props or {}).top or 0,
        ui.symbol{ name = if battery.charging then "battery.100percent.bolt" else "battery.100percent", size = 40, color = "#86efac" },
        ui.text{ text = service.label(battery), size = 40, color = view.foreground, weight = "light" },
        ui.text{ text = status, color = view.secondary } }
    local minutes = power and (if battery.charging then power.full else power.remaining)
    if minutes then rows[#rows + 1] = ui.text{ text = string.format("%.0f min %s", minutes, if battery.charging then "to full" else "remaining"), size = 12, color = view.secondary } end
    if power and power.lowPower then rows[#rows + 1] = ui.text{ text = "Low Power Mode", size = 12, color = view.secondary } end
    return ui.column(rows)
end }, activity = service.activity }
