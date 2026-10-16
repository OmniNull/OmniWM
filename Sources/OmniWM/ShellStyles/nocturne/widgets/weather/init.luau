-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local panel = require("../lib/panel")

local HOVER = "focus/0.14"
local WIDTH = 480
local INNER = WIDTH - 2 - 24
local CARD = INNER - 20
local HOURS = 12

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

local function trailing(width: number, element)
    return ui.row{ w = width, ui.box{ grow = 1, h = 1 }, element }
end

local function chip(symbol: string, text: string)
    return ui.row{ h = 24, gap = 5, radius = 12, fill = "surface", border = "border", borderWidth = 1,
        ui.box{ w = 4, h = 1 },
        ui.symbol{ name = symbol, w = 13, h = 13, size = 11, weight = "semibold", color = "blue" },
        ui.text{ text = text, size = 12, weight = "medium" },
        ui.box{ w = 5, h = 1 } }
end

local function card(props)
    props.w = INNER
    props.pad = 10
    props.radius = 14
    props.fill = "surface"
    props.border = "border"
    props.borderWidth = 1
    props.center = false
    return ui.column(props)
end

function render(ctx)
    local weather = ctx.data.weather
    if not weather then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local fill = style.backgrounds and "surface" or nil
    local edge = style.backgrounds and "border/0.6" or nil
    local item = { gap = 5, radius = size / 2 - 1, fill = fill, border = edge, borderWidth = 1, hover = HOVER,
        onClick = ui.popout,
        ui.symbol{ name = weather.symbol, w = 22 * scale, h = 22 * scale,
            size = 20 * scale, weight = "medium", color = "foreground" } }
    if style.vertical then
        item.w = size
        item.gap = 2
        table.insert(item, 1, ui.box{ w = 1, h = 4 })
        item[#item + 1] = ui.text{ text = degrees(weather.temp), style = "mono", size = 14 * scale, weight = "semibold" }
        item[#item + 1] = ui.box{ w = 1, h = 4 }
        return ui.column(item)
    end
    item.h = size
    table.insert(item, 1, ui.box{ w = 1, h = 1 })
    item[#item + 1] = ui.text{ text = degrees(weather.temp), size = 14 * scale, weight = "semibold", reserve = "-00°" }
    item[#item + 1] = ui.box{ w = 2, h = 1 }
    return ui.row(item)
end

local function hourly(weather)
    local strip = { gap = 0 }
    local column = math.floor(CARD / HOURS)
    for index, hour in weather.hours do
        if index > HOURS then
            break
        end
        strip[#strip + 1] = ui.column{ w = column, gap = 5, help = conditions[hour.condition],
            ui.text{ text = hour.label, size = 12, weight = "medium", color = "secondaryForeground" },
            ui.symbol{ name = hour.symbol, w = 16, h = 16, size = 13, color = index == 1 and "accent" or "foreground" },
            ui.text{ text = degrees(hour.temp), size = 12, weight = index == 1 and "bold" or "medium",
                color = index == 1 and "accent" or "foreground" } }
    end
    return ui.row(strip)
end

local function daily(ctx, weather)
    local floor, ceiling = math.huge, -math.huge
    for _, day in weather.days do
        floor = math.min(floor, day.low)
        ceiling = math.max(ceiling, day.high)
    end
    local span = math.max(ceiling - floor, 1)
    local track = CARD - 210
    local rows = { gap = 6 }
    for index, day in weather.days do
        local from = (day.low - floor) / span * track
        local to = (day.high - floor) / span * track
        rows[#rows + 1] = ui.row{ w = CARD, gap = 8,
            ui.text{ text = day.label, size = 14, weight = index == 1 and "bold" or "medium", w = 52, maxWidth = 52 },
            ui.symbol{ name = day.symbol, w = 18, h = 16, size = 13, help = conditions[day.condition] },
            ui.text{ text = if day.rain and day.rain > 0 then ctx.format.percent(day.rain / 100) else "", size = 12,
                weight = "semibold", color = "blue", w = 34 },
            trailing(30, ui.text{ text = degrees(day.low), size = 14, color = "secondaryForeground" }),
            ui.stack{ w = track, h = 5, radius = 2.5, fill = "foreground/0.1",
                ui.box{ align = "leading", dx = from, w = math.max(5, to - from), h = 5, radius = 2.5,
                    fill = "accent" } },
            trailing(30, ui.text{ text = degrees(day.high), size = 14, weight = "semibold" }) }
    end
    return ui.column(rows)
end

function popout(ctx)
    local weather = ctx.data.weather
    local style = ctx.data.bar.style
    if not weather then
        return ui.box{ w = 0, h = 0 }
    end
    local summary = { gap = 1, center = false,
        ui.text{ text = degrees(weather.temp), size = 30, weight = "bold" },
        ui.text{ text = conditions[weather.condition] or weather.condition, size = 14, weight = "medium",
            color = "secondaryForeground" } }
    if weather.feels then
        summary[#summary + 1] = ui.text{ text = omniwm.l10n("Feels like %@", degrees(weather.feels)), size = 12,
            color = "mutedForeground" }
    end
    local place = { gap = 3, center = false }
    if weather.place then
        place[#place + 1] = ui.row{ gap = 4,
            ui.symbol{ name = "location.fill", size = 9, color = "accent" },
            ui.text{ text = weather.place, size = 14, weight = "bold", maxWidth = 130 } }
    end
    if weather.high and weather.low then
        place[#place + 1] = ui.text{ text = omniwm.l10n("High %@", degrees(weather.high)) .. "  "
            .. omniwm.l10n("Low %@", degrees(weather.low)), size = 12, color = "secondaryForeground" }
    end
    local rows = { w = WIDTH - 2, pad = 12, gap = 10, center = false,
        ui.row{ w = INNER, gap = 12,
            ui.box{ w = 2, h = 1 },
            ui.symbol{ name = weather.symbol, w = 46, h = 42, size = 36, color = "accent" },
            ui.column(summary),
            ui.box{ grow = 1, h = 1 },
            ui.column(place),
            ui.box{ w = 2, h = 1 } } }
    local chips = { gap = 6 }
    if weather.rain then
        chips[#chips + 1] = chip("umbrella.fill", omniwm.l10n("%lld%% chance of rain", weather.rain))
    end
    if weather.wind then
        local unit = if weather.unit == "°F" then "mph" else "km/h"
        chips[#chips + 1] = chip("wind", omniwm.l10n("Wind %@", string.format("%d %s", math.round(weather.wind), unit)))
    end
    if #chips > 0 then
        rows[#rows + 1] = ui.row(chips)
    end
    if #weather.hours > 0 then
        rows[#rows + 1] = card{ hourly(weather) }
    end
    if #weather.days > 0 then
        rows[#rows + 1] = card{ daily(ctx, weather) }
    end
    local footer = { w = INNER, gap = 6, ui.box{ w = 2, h = 1 } }
    if weather.status == "stale" then
        footer[#footer + 1] = ui.symbol{ name = "exclamationmark.triangle.fill", size = 10, color = "warning" }
        footer[#footer + 1] = ui.text{ text = omniwm.l10n("Last update failed"), size = 12, color = "warning" }
        footer[#footer + 1] = ui.box{ grow = 1, h = 1 }
    end
    footer[#footer + 1] = ui.text{ text = omniwm.l10n("Weather by %@", "Open-Meteo.com"), size = 12,
        color = "mutedForeground" }
    rows[#rows + 1] = ui.row(footer)
    return panel(style, WIDTH, ui.column(rows))
end
