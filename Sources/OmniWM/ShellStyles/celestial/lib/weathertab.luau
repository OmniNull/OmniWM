-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local icons = require("./icons")
local surface = require("./surface")
local tokens = require("./tokens")

local WIDTH = 840
local GAP = tokens.spacing.medium
local HEADER = 72
local HERO = 152
local DETAIL = 60
local TITLE = 24
local DAY = 162
local HEIGHT = HEADER + GAP + HERO + GAP + DETAIL + GAP + GAP + TITLE + GAP + DAY

local function temperature(ctx: Context, value: number?, unit: string): string
    return value and string.format("%s%s", ctx.format.number(value, 0), unit) or "--"
end

local function stat(icon: string, label: string, value: string)
    return ui.row{ gap = tokens.spacing.small,
        surface.icon(icon, { size = tokens.icon.extraLarge, color = "tertiaryAccent" }),
        ui.column{ gap = 0, center = false,
            ui.text{ text = label, font = "sans", size = tokens.body.small, color = "secondaryForeground" },
            ui.text{ text = value, font = "sans", size = tokens.body.small, weight = "semibold" } } }
end

local function detail(icon: string, label: string, value: string, tint: string, width: number)
    return ui.row{ w = width, h = DETAIL, gap = tokens.spacing.medium, radius = tokens.rounding.medium, fill = "surface",
        ui.box{ grow = 1, h = 1 },
        surface.icon(icon, { size = tokens.icon.large, color = tint }),
        ui.column{ gap = 0, center = false,
            ui.text{ text = label, font = "sans", size = tokens.body.small, opacity = 0.7 },
            ui.text{ text = value, font = "sans", size = tokens.body.small, weight = "semibold" } },
        ui.box{ grow = 1, h = 1 } }
end

local function day(ctx: Context, entry: WeatherDay, width: number)
    return ui.column{ key = tostring(entry.time), w = width, h = DAY, gap = tokens.spacing.small, radius = tokens.rounding.large,
        fill = "surface",
        ui.text{ text = entry.label, font = "sans", size = tokens.body.medium, weight = "semibold", color = "accent",
            maxWidth = width - 8 },
        ui.text{ text = ctx.format.date(entry.time, "MMMd") or "", font = "sans", size = tokens.body.small, opacity = 0.7,
            color = "secondaryForeground" },
        surface.icon(icons.weather(entry.code, true), { size = tokens.icon.extraLarge, color = "secondaryAccent" }),
        ui.text{ text = string.format("%s / %s", temperature(ctx, entry.low, "°"), temperature(ctx, entry.high, "°")),
            font = "sans", size = tokens.body.small, weight = "semibold", color = "tertiaryAccent" } }
end

local function tab(ctx: Context)
    local weather = ctx.data.weather
    local column = { w = WIDTH, gap = GAP, center = false }
    if not weather then
        column[1] = ui.stack{ w = WIDTH, h = HEIGHT,
            ui.text{ text = omniwm.l10n("Loading…"), font = "sans", size = tokens.title.large,
                color = "secondaryForeground" } }
        return ui.column(column)
    end
    local today = weather.days[1]
    local function clock(time: number?): string
        return time and ctx.format.date(time, "jmm") or "--"
    end
    column[#column + 1] = ui.row{ w = WIDTH, h = HEADER, pad = tokens.padding.large,
        ui.column{ gap = tokens.spacing.extraSmall, center = false,
            ui.text{ text = weather.place or omniwm.l10n("Weather"), font = "sans", size = 28 * 4 / 3, weight = "semibold",
                maxWidth = WIDTH / 2 },
            today and ui.text{ text = ctx.format.date(today.time, "EEEEMMMMd") or "", font = "sans",
                size = tokens.body.small, color = "secondaryForeground" } or nil },
        ui.box{ grow = 1, h = 1 },
        ui.row{ gap = tokens.spacing.largeIncreased,
            stat("wb_twilight", omniwm.l10n("Sunrise"), clock(weather.sunrise)),
            stat("bedtime", omniwm.l10n("Sunset"), clock(weather.sunset)) } }
    column[#column + 1] = ui.row{ w = WIDTH, h = HERO, radius = tokens.rounding.extraLarge * 2, fill = "surface",
        gap = tokens.spacing.largeIncreased,
        ui.box{ grow = 1, h = 1 },
        surface.icon(icons.weather(weather.code, weather.day), { size = tokens.icon.extraLarge * 3,
            color = "secondaryAccent" }),
        ui.column{ gap = -tokens.spacing.small, center = false,
            ui.text{ text = temperature(ctx, weather.temp, weather.unit), font = "sans", size = 28 * 2 * 4 / 3,
                weight = "medium", color = "accent" },
            ui.text{ text = weather.condition, font = "sans", size = tokens.body.medium, color = "secondaryForeground" } },
        ui.box{ grow = 1, h = 1 } }
    local third = (WIDTH - 2 * GAP) / 3
    local windUnit = weather.unit == "°F" and "mph" or "km/h"
    column[#column + 1] = ui.row{ w = WIDTH, gap = GAP,
        detail("water_drop", omniwm.l10n("Humidity"),
            weather.humidity and ctx.format.percent(weather.humidity / 100) or "--", "secondaryAccent", third),
        detail("thermostat", omniwm.l10n("Feels like"), temperature(ctx, weather.feels, weather.unit), "accent", third),
        detail("air", omniwm.l10n("Wind"),
            weather.wind and string.format("%s %s", ctx.format.number(weather.wind, 0), windUnit) or "--",
            "tertiaryAccent", third) }
    if #weather.days > 0 then
        column[#column + 1] = ui.row{ w = WIDTH, h = TITLE + GAP, pad = tokens.padding.medium,
            ui.text{ text = omniwm.l10n("7-day forecast"), font = "sans", size = tokens.body.medium, weight = "semibold" } }
        local count = math.min(#weather.days, 7)
        local width = (WIDTH - (count - 1) * GAP) / count
        local row = { w = WIDTH, gap = GAP }
        for index = 1, count do
            row[index] = day(ctx, weather.days[index], width)
        end
        column[#column + 1] = ui.row(row)
    end
    return ui.column(column)
end

return table.freeze({
    size = table.freeze({ w = WIDTH, h = HEIGHT }),
    tab = tab,
})
