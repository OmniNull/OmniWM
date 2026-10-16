-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")
local WIDTH = style.width
local conditions = {
    Clear = omniwm.l10n("Clear"),
    ["Partly cloudy"] = omniwm.l10n("Partly cloudy"),
    Overcast = omniwm.l10n("Overcast"),
    Fog = omniwm.l10n("Fog"),
    Drizzle = omniwm.l10n("Drizzle"),
    ["Freezing rain"] = omniwm.l10n("Freezing rain"),
    Rain = omniwm.l10n("Rain"),
    Snow = omniwm.l10n("Snow"),
    Thunderstorms = omniwm.l10n("Thunderstorms"),
    Unknown = omniwm.l10n("Unknown"),
}

local function degrees(value: number?): string
    return value and string.format("%d°", math.round(value)) or "–"
end

local function line(symbol: string, text: string)
    return ui.row{ w = WIDTH - 24, gap = 8,
        ui.symbol{ name = symbol, w = 16, h = 16, color = "secondaryForeground" },
        ui.text{ style = "caption", text = text, size = 13, maxWidth = WIDTH - 48 } }
end

function render(ctx)
    local weather = ctx.data.weather
    if not weather then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = style.scale(ctx)
    local item = { onClick = ui.popout, ui.symbol{ name = weather.symbol, size = 14 * scale } }
    if ctx.data.bar.style.vertical then
        item.gap = scale
        item.pad = 2 * scale
        item[#item + 1] = ui.text{ style = "caption", text = degrees(weather.temp), size = 10 * scale }
    else
        item[#item + 1] = ui.text{ style = "caption", text = degrees(weather.temp), size = 13 * scale, reserve = "-00°" }
    end
    return style.bar(ctx, item)
end

function popout(ctx)
    local weather = ctx.data.weather
    if not weather then
        return ui.box{ w = 0, h = 0 }
    end
    local header = { gap = 3, center = false,
        ui.text{ style = "caption", text = degrees(weather.temp), size = 28, weight = "medium" },
        ui.text{ style = "caption", text = conditions[weather.condition] or weather.condition, size = 13, maxWidth = WIDTH - 82 } }
    if weather.place then
        header[#header + 1] = ui.text{ style = "caption", text = weather.place, size = 11, color = "secondaryForeground",
            maxWidth = WIDTH - 82 }
    end
    local current = { w = WIDTH,
        ui.row{ w = WIDTH - 24, gap = 16,
            ui.symbol{ name = weather.symbol, w = 42, h = 42, color = "secondaryForeground" }, ui.column(header) } }
    if weather.feels then
        current[#current + 1] = line("thermometer.medium", omniwm.l10n("Feels like %@", degrees(weather.feels)))
    end
    if weather.high and weather.low then
        current[#current + 1] = line("arrow.up.arrow.down",
            omniwm.l10n("High %@", degrees(weather.high)) .. "  " .. omniwm.l10n("Low %@", degrees(weather.low)))
    end
    if weather.rain then
        current[#current + 1] = line("umbrella", omniwm.l10n("%lld%% chance of rain", weather.rain))
    end
    if weather.wind then
        local unit = if weather.unit == "°F" then "mph" else "km/h"
        current[#current + 1] = line("wind", omniwm.l10n("Wind %@", string.format("%d %s", math.round(weather.wind), unit)))
    end
    local rows = { style.heading(omniwm.l10n("Weather"), WIDTH), style.group(current) }
    if #weather.hours > 0 then
        local forecast = { w = WIDTH, gap = 12 }
        local strip = { gap = 4 }
        for index, hour in weather.hours do
            if index > 12 then
                break
            end
            strip[#strip + 1] = ui.column{ w = 46, gap = 6, center = true, help = conditions[hour.condition],
                ui.text{ style = "caption", text = hour.label, size = 11, color = "secondaryForeground", maxWidth = 46 },
                ui.symbol{ name = hour.symbol, w = 18, h = 18 },
                ui.text{ style = "caption", text = degrees(hour.temp), size = 13 } }
            if #strip == 6 then
                forecast[#forecast + 1] = ui.row(strip)
                strip = { gap = 4 }
            end
        end
        if #strip > 0 then
            forecast[#forecast + 1] = ui.row(strip)
        end
        rows[#rows + 1] = style.group(forecast)
    end
    if #weather.days > 0 then
        local forecast = { w = WIDTH, gap = 12 }
        for _, day in weather.days do
            forecast[#forecast + 1] = ui.row{ w = WIDTH - 24, gap = 8,
                ui.text{ style = "caption", text = day.label, size = 13, w = 110, maxWidth = 110 },
                ui.symbol{ name = day.symbol, w = 18, h = 18, help = conditions[day.condition] },
                ui.text{ style = "caption", text = if day.rain and day.rain > 0 then ctx.format.percent(day.rain / 100) else "",
                    size = 11, color = "accent", w = 46, maxWidth = 46 },
                ui.text{ style = "caption", text = degrees(day.low), size = 13, color = "secondaryForeground", w = 40 },
                ui.text{ style = "caption", text = degrees(day.high), size = 13, w = 40 } }
        end
        rows[#rows + 1] = style.group(forecast)
    end
    if weather.status == "stale" then
        rows[#rows + 1] = ui.row{ w = WIDTH, gap = 8,
            ui.symbol{ name = "exclamationmark.triangle", w = 16, h = 16, color = "warning" },
            ui.text{ style = "caption", text = omniwm.l10n("Last update failed"), size = 13, color = "secondaryForeground" } }
    end
    rows[#rows + 1] = ui.text{ style = "caption", text = omniwm.l10n("Weather by %@", "Open-Meteo.com"), size = 11,
        color = "secondaryForeground" }
    return style.panel(rows)
end
