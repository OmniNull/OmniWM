local service = require("../lib/lake/services/weather")
local view = require("../lib/lake/view")

local function temperature(weather)
    return weather and weather.temp and string.format("%.0f%s", weather.temp, weather.unit or "°") or "—"
end

local function number(value, suffix)
    return if value then string.format("%.0f", value) .. suffix else "—"
end

return { views = { compact = function(ctx)
    local weather = service.snapshot(ctx)
    local text = if weather and (weather.access == "off" or weather.access == "blocked")
        then service.status(weather) else temperature(weather)
    return view.compact(ctx, weather and weather.symbol or "cloud.sun.fill", text, "#fbbf24")
end, expanded = function(ctx)
    local weather = service.snapshot(ctx)
    local width = math.max(1, (ctx.view.w or 520) - 48)
    if weather and (weather.access == "off" or weather.access == "blocked") then
        return ui.text{ text = service.status(weather), maxWidth = width, color = view.secondary, size = 12 }
    end
    return ui.column{ gap = 12, align = "top", dy = (ctx.view.props or {}).top or 0,
        ui.text{ text = weather and (weather.place or "Weather") or "Weather unavailable", size = 16, maxWidth = width, color = view.secondary },
        ui.text{ text = temperature(weather), size = 48, weight = "light", color = view.foreground },
        ui.text{ text = service.status(weather), maxWidth = width, color = if weather and weather.status == "stale" then "#fbbf24" else view.secondary, size = 12 },
        ui.text{ text = weather and ("H " .. number(weather.high, "°") .. "  L " .. number(weather.low, "°")
            .. " · Humidity " .. number(weather.humidity, "%")) or "Check the weather location and network in OmniWM settings", maxWidth = width, color = view.secondary, size = 12 } }
end }, activity = function() return { priority = 0 } end }
