-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
    return ui.row{ gap = 8,
        ui.symbol{ name = symbol, w = 14, h = 14, color = "secondaryForeground" },
        ui.text{ text = text } }
end

function render(ctx)
    local weather = ctx.data.weather
    if not weather then
        return ui.box{ w = 0, h = 0 }
    end
    local item = { gap = 4, pad = 2, radius = 4, hover = "foreground/0.12", onClick = ui.popout,
        ui.symbol{ name = weather.symbol } }
    if ctx.data.bar.style.vertical then
        item.gap = 1
        item[#item + 1] = ui.text{ text = degrees(weather.temp), style = "mono", size = 9 }
        return ui.column(item)
    end
    item[#item + 1] = ui.text{ text = degrees(weather.temp), style = "mono", reserve = "-00°" }
    return ui.row(item)
end

function popout(ctx)
    local weather = ctx.data.weather
    if not weather then
        return ui.box{ w = 0, h = 0 }
    end
    local header = { gap = 2, center = false,
        ui.text{ text = degrees(weather.temp) .. " " .. (conditions[weather.condition] or weather.condition),
            style = "bold" } }
    if weather.place then
        header[#header + 1] = ui.text{ text = weather.place, style = "small", color = "secondaryForeground",
            maxWidth = 220 }
    end
    local rows = { gap = 8, pad = 12, center = false,
        ui.row{ gap = 10, ui.symbol{ name = weather.symbol, w = 26, h = 26 }, ui.column(header) } }
    if weather.feels then
        rows[#rows + 1] = line("thermometer.medium", omniwm.l10n("Feels like %@", degrees(weather.feels)))
    end
    if weather.high and weather.low then
        rows[#rows + 1] = line("arrow.up.arrow.down",
            omniwm.l10n("High %@", degrees(weather.high)) .. "  " .. omniwm.l10n("Low %@", degrees(weather.low)))
    end
    if weather.rain then
        rows[#rows + 1] = line("umbrella", omniwm.l10n("%lld%% chance of rain", weather.rain))
    end
    if weather.wind then
        local unit = if weather.unit == "°F" then "mph" else "km/h"
        rows[#rows + 1] = line("wind", omniwm.l10n("Wind %@", string.format("%d %s", math.round(weather.wind), unit)))
    end
    if #weather.hours > 0 then
        local strip = { gap = 2 }
        for index, hour in weather.hours do
            if index > 12 then
                break
            end
            strip[#strip + 1] = ui.column{ w = 34, gap = 3, center = true, help = conditions[hour.condition],
                ui.text{ text = hour.label, style = "caption", color = "secondaryForeground" },
                ui.symbol{ name = hour.symbol, w = 16, h = 16 },
                ui.text{ text = degrees(hour.temp), style = "small" } }
        end
        rows[#rows + 1] = ui.row(strip)
    end
    for _, day in weather.days do
        local entry = { gap = 8,
            ui.text{ text = day.label, w = 72, maxWidth = 72 },
            ui.symbol{ name = day.symbol, w = 16, h = 16, help = conditions[day.condition] },
            ui.text{ text = if day.rain and day.rain > 0 then ctx.format.percent(day.rain / 100) else "",
                style = "small", color = "accent", w = 34 },
            ui.text{ text = degrees(day.low), color = "secondaryForeground", w = 36 },
            ui.text{ text = degrees(day.high), w = 36 } }
        rows[#rows + 1] = ui.row(entry)
    end
    if weather.status == "stale" then
        rows[#rows + 1] = line("exclamationmark.triangle", omniwm.l10n("Last update failed"))
    end
    rows[#rows + 1] = ui.text{ text = omniwm.l10n("Weather by %@", "Open-Meteo.com"), style = "small",
        color = "mutedForeground" }
    return ui.column(rows)
end
