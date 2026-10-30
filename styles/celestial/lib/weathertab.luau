-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

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
local HOURLY = 100
local FOOTER = 24
local HEIGHT = HEADER + GAP + HERO + GAP + DETAIL + GAP + GAP + TITLE + GAP + DAY

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

local function day(ctx: Context, entry, width: number)
    local reading = entry.reading
    return ui.column{ key = tostring(reading.time), w = width, h = DAY, gap = tokens.spacing.small,
        radius = tokens.rounding.large, fill = "surface", help = entry.condition,
        ui.text{ text = entry.label, font = "sans", size = tokens.body.medium, weight = "semibold", color = "accent",
            maxWidth = width - 8 },
        ui.text{ text = ctx.format.date(reading.time, "MMMd") or "", font = "sans", size = tokens.body.small, opacity = 0.7,
            color = "secondaryForeground" },
        surface.icon(icons.weather(reading.code, true), { size = tokens.icon.extraLarge, color = "secondaryAccent" }),
        ui.row{ gap = tokens.spacing.extraSmall,
            ui.text{ text = entry.low .. " / " .. entry.high,
                font = "sans", size = tokens.body.small, weight = "semibold", color = "tertiaryAccent" },
            entry.rain and ui.text{ text = entry.rain, font = "sans", size = tokens.label.small,
                color = "secondaryAccent" } or nil } }
end

local function hourly(hours)
    local width = WIDTH / #hours
    local rows = { w = WIDTH, h = HOURLY, gap = 0, radius = tokens.rounding.large, fill = "surface" }
    for _, hour in hours do
        local reading = hour.reading
        rows[#rows + 1] = ui.column{ w = width, gap = tokens.spacing.small, help = hour.condition,
            ui.text{ text = hour.label, font = "sans", size = tokens.label.medium, color = "secondaryForeground",
                maxWidth = width - 8 },
            surface.icon(icons.weather(reading.code, reading.day), { size = tokens.icon.medium,
                color = "secondaryAccent" }),
            ui.text{ text = hour.temp, font = "sans", size = tokens.body.small, weight = "medium", color = "accent" } }
    end
    return ui.row(rows)
end

local function tab(ctx: Context, m)
    local model = require("./weather")
    m = m or model.model(ctx)
    local weather = m and m.reading
    local column = { w = WIDTH, h = HEIGHT, scroll = true, gap = GAP, center = false }
    if not weather then
        column[1] = ui.stack{ w = WIDTH, h = HEIGHT,
            ui.text{ text = model.accessMessage(ctx) or omniwm.l10n("Unavailable"), font = "sans", size = tokens.title.large,
                color = "secondaryForeground" } }
        return ui.column(column)
    end
    local today = m.days[1] and m.days[1].reading
    local function clock(time: number?): string
        return time and ctx.format.date(time, "jmm") or "--"
    end
    local header = ui.row{ w = WIDTH, h = HEADER, pad = tokens.padding.large,
        ui.column{ gap = tokens.spacing.extraSmall, center = false,
            ui.text{ text = m.place or omniwm.l10n("Weather"), font = "sans", size = 28 * 4 / 3, weight = "semibold",
                maxWidth = WIDTH / 2 },
            today and ui.text{ text = ctx.format.date(today.time, "EEEEMMMMd") or "", font = "sans",
                size = tokens.body.small, color = "secondaryForeground" } or nil },
        ui.box{ grow = 1, h = 1 },
        ui.row{ gap = tokens.spacing.largeIncreased,
            stat("wb_twilight", omniwm.l10n("Sunrise"), clock(weather.sunrise)),
            stat("bedtime", omniwm.l10n("Sunset"), clock(weather.sunset)) } }
    column[#column + 1] = ui.stack{ w = WIDTH, h = HEADER, header,
        m.stale and surface.icon("warning", { align = "top", dy = 4, size = tokens.icon.small,
            color = "warning", help = m.stale }) or nil }
    column[#column + 1] = ui.row{ w = WIDTH, h = HERO, radius = tokens.rounding.extraLarge * 2, fill = "surface",
        gap = tokens.spacing.largeIncreased,
        ui.box{ grow = 1, h = 1 },
        surface.icon(icons.weather(weather.code, weather.day), { size = tokens.icon.extraLarge * 3,
            color = "secondaryAccent" }),
        ui.column{ gap = -tokens.spacing.small, center = false,
            ui.text{ text = m.temperature, font = "sans", size = 28 * 2 * 4 / 3,
                weight = "medium", color = "accent" },
            ui.text{ text = m.condition, font = "sans", size = tokens.body.medium, color = "secondaryForeground" } },
        ui.box{ grow = 1, h = 1 } }
    local width = (WIDTH - 2 * GAP) / 3
    local details = { w = WIDTH, gap = GAP,
        detail("water_drop", omniwm.l10n("Humidity"),
            weather.humidity and ctx.format.percent(weather.humidity / 100) or "--", "secondaryAccent", width),
        detail("thermostat", omniwm.l10n("Feels like"), m.feelsValue, "accent", width),
        detail("air", omniwm.l10n("Wind"), m.windValue or "--", "tertiaryAccent", width) }
    column[#column + 1] = ui.row(details)
    if #m.days > 0 then
        column[#column + 1] = ui.row{ w = WIDTH, h = TITLE + GAP, pad = tokens.padding.medium,
            ui.text{ text = omniwm.l10n("7-day forecast"), font = "sans", size = tokens.body.medium, weight = "semibold" } }
        local count = #m.days
        local width = (WIDTH - (count - 1) * GAP) / count
        local row = { w = WIDTH, gap = GAP }
        for index = 1, count do
            row[index] = day(ctx, m.days[index], width)
        end
        column[#column + 1] = ui.row(row)
    end
    if #m.hours > 0 then
        column[#column + 1] = hourly(m.hours)
    end
    if m.rain then
        column[#column + 1] = ui.row{ w = WIDTH, h = FOOTER, gap = tokens.spacing.small,
            surface.icon("rainy", { size = tokens.icon.small, color = "secondaryAccent" }),
            ui.text{ text = m.rain, font = "sans", size = tokens.body.small, color = "secondaryForeground" } }
    end
    if m.stale then
        column[#column + 1] = ui.row{ w = WIDTH, h = FOOTER, gap = tokens.spacing.small,
            surface.icon("warning", { size = tokens.icon.small, color = "warning" }),
            ui.text{ text = m.stale, font = "sans", size = tokens.body.small,
                color = "secondaryForeground" } }
    end
    column[#column + 1] = ui.row{ w = WIDTH, h = FOOTER,
        ui.text{ text = m.attribution, font = "sans", size = tokens.label.small, color = "secondaryForeground" } }
    return ui.column(column)
end

return table.freeze({
    size = table.freeze({ w = WIDTH, h = HEIGHT }),
    tab = tab,
})
