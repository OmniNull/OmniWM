-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HUE = "accent"
local WIDTH = 480
local INNER = WIDTH - 32
local CARD = INNER - 20
local HOURS = 12
local RANGE = 120

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

local tints = {
    Clear = "yellow",
    ["Partly cloudy"] = "yellow",
    Overcast = "secondaryForeground",
    Fog = "secondaryForeground",
    Drizzle = "blue",
    ["Freezing rain"] = "cyan",
    Rain = "blue",
    Snow = "foreground",
    Thunderstorms = "accent",
}

local function tint(condition: string): string
    return tints[condition] or "mutedForeground"
end

local function degrees(value: number?): string
    return value and string.format("%d°", math.round(value)) or "–"
end

local function block(size: number, radius: number, vertical: boolean, name: string)
    return ui.stack{ w = size, h = size,
        ui.box{ w = size, h = size, radius = radius, fill = HUE },
        ui.box{ align = vertical and "bottom" or "trailing", w = vertical and size or radius,
            h = vertical and radius or size, fill = HUE },
        ui.symbol{ name = name, size = math.floor(size * 0.54), weight = "semibold", color = "accentForeground" } }
end

local function stat(symbol: string, color: string, text: string, width: number)
    return ui.column{ w = width, gap = 5, pad = 0, center = true,
        ui.box{ w = 1, h = 6 },
        ui.symbol{ name = symbol, size = 15, weight = "semibold", color = color },
        ui.text{ text = text, size = 12, weight = "semibold", color = "foreground", maxWidth = width - 12, lines = 2 },
        ui.box{ w = 1, h = 6 } }
end

local function stats(weather)
    local cells = {}
    if weather.feels then
        cells[#cells + 1] = { "thermometer.medium", "orange", omniwm.l10n("Feels like %@", degrees(weather.feels)) }
    end
    if weather.rain then
        cells[#cells + 1] = { "umbrella.fill", "blue", omniwm.l10n("%lld%% chance of rain", weather.rain) }
    end
    if weather.wind then
        local unit = if weather.unit == "°F" then "mph" else "km/h"
        cells[#cells + 1] = { "wind", "teal", omniwm.l10n("Wind %@", string.format("%d %s", math.round(weather.wind), unit)) }
    end
    if #cells == 0 then
        return nil
    end
    local width = (INNER - (#cells - 1)) / #cells
    local row = { w = INNER, gap = 0, radius = 9, fill = "elevatedSurface" }
    for index, cell in cells do
        if index > 1 then
            row[#row + 1] = ui.box{ w = 1, h = 40, fill = "foreground/0.08" }
        end
        row[#row + 1] = stat(cell[1], cell[2], cell[3], width)
    end
    return ui.row(row)
end

local function hourly(weather)
    local count = math.min(HOURS, #weather.hours)
    if count == 0 then
        return nil
    end
    local width = math.floor((INNER - 8) / count)
    local strip = { w = INNER, gap = 0, pad = 4, radius = 9, fill = "elevatedSurface" }
    for index, hour in weather.hours do
        if index > count then
            break
        end
        strip[#strip + 1] = ui.column{ w = width, gap = 5, pad = 0, radius = 7, center = true,
            fill = index == 1 and "accent/0.14" or nil, help = conditions[hour.condition],
            ui.box{ w = 1, h = 4 },
            ui.text{ text = hour.label, size = 12, weight = "semibold",
                color = index == 1 and "accent" or "mutedForeground" },
            ui.symbol{ name = hour.symbol, size = 13, weight = "medium", color = tint(hour.condition) },
            ui.text{ text = degrees(hour.temp), style = "mono", size = 12, weight = "semibold", color = "foreground" },
            ui.box{ w = 1, h = 4 } }
    end
    return ui.row(strip)
end

local function rangeBar(day, low: number, high: number)
    local span = math.max(high - low, 1)
    local from = math.floor((day.low - low) / span * RANGE)
    local to = math.max(from + 6, math.floor((day.high - low) / span * RANGE))
    local half = (to - from) / 2
    return ui.stack{ w = RANGE, h = 4, radius = 2, fill = "foreground/0.08",
        ui.row{ align = "leading", dx = from, gap = 0,
            ui.box{ w = half, h = 4, radius = 2, fill = "blue" },
            ui.box{ w = to - from - half, h = 4, radius = 2, fill = "yellow" } } }
end

local function daily(ctx, weather)
    if #weather.days == 0 then
        return nil
    end
    local low, high = math.huge, -math.huge
    for _, day in weather.days do
        low = math.min(low, day.low)
        high = math.max(high, day.high)
    end
    local card = { w = INNER, gap = 0, pad = 0, radius = 9, fill = "elevatedSurface", center = true }
    for index, day in weather.days do
        if index > 1 then
            card[#card + 1] = ui.box{ w = CARD, h = 1, fill = "foreground/0.07" }
        end
        card[#card + 1] = ui.row{ w = CARD, h = 34, gap = 8,
            ui.text{ text = day.label, size = 14, weight = index == 1 and "bold" or "medium",
                color = index == 1 and "accent" or "foreground", w = 70, maxWidth = 70 },
            ui.stack{ w = 20, h = 20, help = conditions[day.condition],
                ui.symbol{ name = day.symbol, size = 14, weight = "medium", color = tint(day.condition) } },
            ui.text{ text = if day.rain and day.rain > 0 then ctx.format.percent(day.rain / 100) else "",
                style = "mono", size = 12, weight = "semibold", color = "blue", w = 34 },
            ui.box{ grow = 1, h = 1 },
            ui.row{ w = 30, ui.box{ grow = 1, h = 1 },
                ui.text{ text = degrees(day.low), style = "mono", size = 14, weight = "medium", color = "mutedForeground" } },
            rangeBar(day, low, high),
            ui.row{ w = 30, ui.box{ grow = 1, h = 1 },
                ui.text{ text = degrees(day.high), style = "mono", size = 14, weight = "bold", color = "foreground" } } }
    end
    return ui.column(card)
end

function render(ctx)
    local weather = ctx.data.weather
    if not weather then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local radius = math.floor(size * 0.24)
    local item = { gap = 0, radius = radius, fill = "elevatedSurface", hoverOpacity = 0.9, onClick = ui.popout,
        block(size, radius, style.vertical, weather.symbol) }
    if style.vertical then
        item.w = size
        item.gap = 2
        item[#item + 1] = ui.text{ text = degrees(weather.temp), style = "mono", size = 14 * scale, weight = "semibold",
            color = HUE }
        item[#item + 1] = ui.box{ w = 1, h = 3 }
        return ui.column(item)
    end
    item.h = size
    item[#item + 1] = ui.box{ w = 8, h = 1 }
    item[#item + 1] = ui.text{ text = degrees(weather.temp), style = "mono", size = 14 * scale, weight = "semibold",
        color = HUE, reserve = "-00°" }
    item[#item + 1] = ui.box{ w = 8, h = 1 }
    return ui.row(item)
end

function popout(ctx)
    local weather = ctx.data.weather
    if not weather then
        return ui.box{ w = 0, h = 0 }
    end
    local condition = conditions[weather.condition] or weather.condition
    local frame = { w = WIDTH, gap = 0, material = "clear", radius = 12, fill = "surface", border = "border",
        borderWidth = 1, center = false }
    local headerRow = { w = INNER, gap = 8,
        ui.symbol{ name = "location.fill", size = 12, weight = "semibold", color = "accent" },
        ui.text{ text = weather.place or condition, size = 14, weight = "bold", color = "foreground", maxWidth = 240 },
        ui.box{ grow = 1, h = 1 } }
    if weather.status == "stale" then
        headerRow[#headerRow + 1] = ui.symbol{ name = "exclamationmark.triangle.fill", size = 12, color = "warning",
            help = omniwm.l10n("Last update failed") }
    end
    frame[#frame + 1] = ui.stack{ w = WIDTH, h = 44,
        ui.box{ w = WIDTH, h = 44, radius = 12, fill = "elevatedSurface" },
        ui.box{ align = "bottom", w = WIDTH, h = 12, fill = "elevatedSurface" },
        ui.row(headerRow) }
    frame[#frame + 1] = ui.box{ w = WIDTH, h = 1, fill = "border" }
    local extremes = { gap = 4, center = false }
    if weather.high and weather.low then
        extremes[#extremes + 1] = ui.row{ gap = 4,
            ui.symbol{ name = "arrow.up", size = 10, weight = "bold", color = "orange" },
            ui.text{ text = omniwm.l10n("High %@", degrees(weather.high)), size = 14, weight = "semibold",
                color = "foreground" } }
        extremes[#extremes + 1] = ui.row{ gap = 4,
            ui.symbol{ name = "arrow.down", size = 10, weight = "bold", color = "blue" },
            ui.text{ text = omniwm.l10n("Low %@", degrees(weather.low)), size = 14, weight = "semibold",
                color = "secondaryForeground" } }
    end
    local body = { w = WIDTH, pad = 16, gap = 10, center = false,
        ui.row{ w = INNER, gap = 14,
            ui.stack{ w = 52, h = 52, ui.symbol{ name = weather.symbol, size = 40, weight = "regular",
                color = tint(weather.condition) } },
            ui.column{ gap = 0, center = false,
                ui.text{ text = degrees(weather.temp), style = "rounded", size = 36, weight = "light",
                    color = "foreground" },
                ui.text{ text = condition, size = 14, weight = "medium", color = "secondaryForeground",
                    maxWidth = 200 } },
            ui.box{ grow = 1, h = 1 },
            ui.column(extremes) } }
    body[#body + 1] = stats(weather)
    body[#body + 1] = hourly(weather)
    body[#body + 1] = daily(ctx, weather)
    local footer = { w = INNER, gap = 6 }
    if weather.status == "stale" then
        footer[#footer + 1] = ui.symbol{ name = "exclamationmark.triangle", size = 10, color = "warning" }
        footer[#footer + 1] = ui.text{ text = omniwm.l10n("Last update failed"), size = 12, weight = "semibold",
            color = "warning" }
        footer[#footer + 1] = ui.box{ grow = 1, h = 1 }
    end
    footer[#footer + 1] = ui.text{ text = omniwm.l10n("Weather by %@", "Open-Meteo.com"), size = 12, weight = "medium",
        color = "mutedForeground" }
    body[#body + 1] = ui.row(footer)
    frame[#frame + 1] = ui.column(body)
    return ui.column(frame)
end
