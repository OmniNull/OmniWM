-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local geometry = require("./geometry")
local icons = require("./icons")
local shapes = require("./shapes")
local surface = require("./surface")
local tokens = require("./tokens")

local GAP = tokens.spacing.medium
local WEATHER = tokens.dashboard.weather
local USER = tokens.dashboard.user
local MEDIA = tokens.dashboard.media
local TOP = 117
local BOTTOM = 240
local RESOURCE = math.floor((BOTTOM - 2 * tokens.padding.large - 2 * GAP) / 3)
local RESOURCES = RESOURCE + 2 * tokens.padding.large
local CALENDAR = WEATHER + GAP + USER - tokens.dashboard.dateTime - RESOURCES - 2 * GAP

local function card(w: number, h: number, radius: number, props)
    props.w = w
    props.h = h
    props.radius = radius
    props.fill = props.fill or "surface"
    return ui.stack(props)
end

local function duration(seconds: number): string
    local minutes = math.floor(seconds / 60)
    local days, hours = math.floor(minutes / 1440), math.floor(minutes / 60) % 24
    if days > 0 then
        return omniwm.l10n("%lldd %lldh %lldm", days, hours, minutes % 60)
    end
    if hours > 0 then
        return omniwm.l10n("%lldh %lldm", hours, minutes % 60)
    end
    return omniwm.l10n("%lldm", minutes % 60)
end

local function weather(ctx: Context)
    local model = require("./weather")
    local data = model.state(ctx, true)
    local message = model.accessMessage(ctx)
    local content = { gap = tokens.spacing.largeIncreased }
    content[1] = surface.icon(data and icons.weather(data.code, data.isDay) or "air",
        { size = tokens.icon.extraLarge * 1.6, color = "secondaryAccent" })
    content[2] = message and ui.text{ text = message, font = "sans", size = tokens.body.medium,
        maxWidth = WEATHER - tokens.icon.extraLarge * 1.6 - 60, lines = 3 } or ui.column{ gap = tokens.spacing.extraSmall,
        ui.text{ text = data and data.temperature or "--", font = "sans",
            size = tokens.headline.medium, weight = "semibold", color = "accent" },
        ui.text{ text = data and data.condition or omniwm.l10n("Unavailable"), font = "sans", size = tokens.body.small,
            maxWidth = WEATHER - tokens.icon.extraLarge * 1.6 - 60, lines = 2 } }
    return card(WEATHER, TOP, tokens.rounding.extraLarge * 1.5, { ui.row(content) })
end

local function user(ctx: Context)
    local data = ctx.data.user
    local system = ctx.data.system
    local pad = tokens.padding.large
    local height = TOP - 2 * pad
    local logo = tokens.dashboard.logo + tokens.padding.small * 2
    local uptime = tokens.dashboard.uptime + tokens.padding.small * 2
    local picture = ui.stack{ align = "leading", dx = logo + tokens.padding.extraSmall
            - (tokens.padding.largeIncreased + tokens.padding.extraLarge) / 2, w = height, h = height,
        ui.path{ d = shapes.path("Pill"), viewBox = shapes.viewBox, w = height, h = height, mask = true },
        ui.box{ w = height, h = height, fill = "highestSurface" },
        data and data.avatar and ui.image{ image = data.avatar, w = height, h = height }
            or surface.icon("person", { size = tokens.icon.extraLarge, color = "secondaryForeground", filled = true }) }
    local pictureEnd = logo + tokens.padding.extraSmall - (tokens.padding.largeIncreased + tokens.padding.extraLarge) / 2
        + height
    local layers = { pad = pad, w = USER, h = TOP,
        picture,
        ui.stack{ align = "topLeading", dx = tokens.padding.extraSmall, w = logo, h = logo,
            ui.path{ d = shapes.path("Gem"), viewBox = shapes.viewBox, w = logo, h = logo, fill = "accentContainer" },
            ui.symbol{ name = "apple.logo", size = tokens.dashboard.logo * 0.8, color = "accentContainerForeground" } },
        ui.stack{ align = "bottomLeading", dx = pictureEnd - tokens.padding.extraLargeIncreased, dy = tokens.padding.small,
            w = uptime, h = uptime,
            ui.path{ d = shapes.path("ClamShell"), viewBox = shapes.viewBox, w = uptime, h = uptime,
                fill = "tertiaryContainer" },
            surface.icon("clock_arrow_up", { size = tokens.icon.medium, color = "tertiaryContainerForeground" }) },
        ui.text{ align = "bottomLeading", dx = pictureEnd - tokens.padding.extraLargeIncreased + uptime
                + tokens.spacing.small, dy = -(uptime - tokens.body.medium) / 2 + tokens.padding.small,
            text = system and omniwm.l10n("up %@", duration(system.uptime)) or "", font = "sans",
            size = tokens.body.medium, maxWidth = USER - pictureEnd - uptime - tokens.padding.extraLarge },
        ui.row{ align = "topLeading", dx = pictureEnd + tokens.spacing.small - tokens.padding.medium,
            dy = tokens.padding.extraSmall - pad, gap = tokens.spacing.extraSmall, radius = tokens.rounding.largeIncreased,
            fill = "secondaryContainer", pad = tokens.padding.small,
            surface.icon("select_window", { size = tokens.body.small, color = "secondaryContainerForeground" }),
            ui.text{ text = "OmniWM…", font = "sans", size = tokens.body.small, color = "secondaryContainerForeground" } },
        ui.box{ align = "topLeading", dx = pictureEnd + tokens.spacing.small + 4, dy = 40 - pad, w = 15, h = 15,
            radius = 7.5, fill = "secondaryContainer" },
        ui.box{ align = "topLeading", dx = pictureEnd + tokens.spacing.small, dy = 54 - pad, w = 10, h = 10,
            radius = 5, fill = "secondaryContainer" } }
    return card(USER, TOP, tokens.rounding.extraLarge, { ui.stack(layers) })
end

local function dateTime(ctx: Context)
    local hour, minute = string.match(ctx.data.clock, "(%d+)%D+(%d+)")
    local meridiem = string.match(ctx.data.clock, "(%a+)%s*$")
    local size = 28 * 4 / 3
    local column = { gap = 0, ui.column{ gap = -size * 0.4,
        ui.text{ text = hour and string.format("%02d", tonumber(hour) or 0) or "--", font = "rubik", size = size,
            weight = "semibold", color = "secondaryAccent" },
        ui.text{ text = "•••", font = "rubik", size = size * 0.9, color = "accent" },
        ui.text{ text = minute or "--", font = "rubik", size = size, weight = "semibold", color = "secondaryAccent" } } }
    if meridiem then
        column[#column + 1] = ui.text{ text = meridiem, font = "rubik", size = 18 * 4 / 3, weight = "semibold",
            color = "accent" }
    end
    return card(tokens.dashboard.dateTime, BOTTOM, tokens.rounding.large, { ui.column(column) })
end

local MONTH_OFFSETS = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }

local function weekday(year: number, month: number, day: number): number
    local y = if month < 3 then year - 1 else year
    return (y + y // 4 - y // 100 + y // 400 + MONTH_OFFSETS[month] + day) % 7
end

local function calendar(ctx: Context, m)
    m = m or require("./calendar").model(ctx, true)
    local month = m and m.month
    local width = CALENDAR - 2 * tokens.padding.large
    local column = { gap = tokens.spacing.extraSmall, center = false, pad = tokens.padding.large }
    if not month then
        local action = m and m.action
        column[#column + 1] = ui.stack{ w = width, h = BOTTOM - 2 * tokens.padding.large,
            ui.row{ h = 40, radius = 20, fill = "secondaryContainer", pad = tokens.padding.medium,
                hover = m and "secondaryContainerForeground/0.08" or nil,
                onClick = action and action.command or m and m.open,
                ui.text{ text = action and action.text or (m and omniwm.l10n("Open Calendar") or omniwm.l10n("Unavailable")),
                    font = "sans", size = tokens.label.large, color = "secondaryContainerForeground" } } }
        return card(CALENDAR, BOTTOM, tokens.rounding.extraLarge, { ui.column(column) })
    end
    local cell = math.floor(width / 7)
    local firstColumn = weekday(month.year, month.month, 1)
    local function weekend(index: number): boolean
        local day = (firstColumn - month.offset + index) % 7
        return day == 0 or day == 6
    end
    column[#column + 1] = ui.row{ w = width,
        surface.button("chevron_left", "text", { onClick = m.previous, glyph = tokens.icon.small }),
        ui.stack{ grow = 1, h = 32, radius = 16, hover = "accent/0.08", onClick = m.today,
            ui.text{ text = month.title, font = "sans", size = tokens.title.small, weight = "medium", color = "accent" } },
        surface.button("chevron_right", "text", { onClick = m.next, glyph = tokens.icon.small }) }
    local names = { gap = 0 }
    for index, name in month.weekdays do
        names[index] = ui.stack{ w = cell, ui.text{ text = name, font = "sans", size = tokens.body.small,
            weight = "medium", color = weekend(index - 1) and "tertiaryAccent" or "foreground" } }
    end
    column[#column + 1] = ui.row(names)
    local rows = math.ceil((month.offset + month.days) / 7)
    local height = math.min(26, math.floor((BOTTOM - 2 * tokens.padding.large - 32 - 18 - 2 * tokens.spacing.extraSmall) / rows))
    for row = 0, rows - 1 do
        local line = { gap = 0 }
        for index = 0, 6 do
            local day = row * 7 + index - month.offset + 1
            local today = day == month.today
            local entry = { w = cell, h = height }
            if day >= 1 and day <= month.days then
                if today then
                    entry[#entry + 1] = ui.path{ d = shapes.path("Sunny"), viewBox = shapes.viewBox, w = height + 6,
                        h = height + 6, fill = "accent" }
                end
                entry[#entry + 1] = ui.text{ text = tostring(day), font = "sans", size = tokens.body.small,
                    color = today and "accentForeground" or weekend(index) and "tertiaryAccent" or "secondaryForeground" }
            end
            line[#line + 1] = ui.stack(entry)
        end
        column[#column + 1] = ui.row(line)
    end
    return card(CALENDAR, BOTTOM, tokens.rounding.extraLarge, { onScroll = m.scroll, ui.column(column) })
end

local function ring(value: number?, icon: string, tint: string)
    local gauge = geometry.gauge(RESOURCE, tokens.dashboard.resourceThickness, (value or 0) / 100)
    local stack = { w = RESOURCE, h = RESOURCE }
    if gauge.track then
        stack[#stack + 1] = ui.path{ d = gauge.track, w = RESOURCE, h = RESOURCE, fill = "secondaryContainer" }
    end
    if gauge.value then
        stack[#stack + 1] = ui.path{ d = gauge.value, w = RESOURCE, h = RESOURCE, fill = tint, animate = "normal" }
    end
    stack[#stack + 1] = surface.icon(icon, { size = tokens.icon.large * 0.85, color = tint })
    return ui.stack(stack)
end

local function resources(ctx: Context)
    local data = ctx.data
    return card(RESOURCES, BOTTOM, tokens.rounding.large, { ui.column{ gap = GAP,
        ring(data.cpu, "memory", "accent"),
        ring(data.memory, "memory_alt", "tertiaryAccent"),
        ring(data.disk, "hard_disk", "secondaryAccent") } })
end

local function media(ctx: Context)
    local m = require("./media").model(ctx, false, true)
    local height = TOP + GAP + BOTTOM
    local thickness = tokens.dashboard.mediaThickness
    local amplitude = thickness * 0.5
    local band = thickness * (1 + 0.5) * 2
    local cover = MEDIA - 2 * (tokens.padding.medium + tokens.spacing.extraSmall + band)
    local ringSize = cover + tokens.spacing.extraSmall + band * 2
    local radius = (ringSize - band) / 2
    local playing = m ~= nil and m.playing
    local fraction = m and m.fraction or 0
    local sweep = tokens.dashboard.mediaSweep
    local start = -90 - sweep / 2
    local middle = ringSize / 2
    local spacing = math.deg((tokens.spacing.small + thickness) / radius)
    local arc = { w = ringSize, h = ringSize, align = "top", dy = tokens.padding.medium - band / 2 + band / 2 }
    if fraction > 0.003 then
        arc[#arc + 1] = ui.stack{ w = ringSize, h = ringSize,
            ui.path{ d = geometry.sector(middle, middle, middle, start, sweep * fraction), w = ringSize, h = ringSize,
                mask = true },
            ui.path{ d = geometry.wavyRing(ringSize, radius, amplitude, 16), w = ringSize, h = ringSize,
                border = "accent", borderWidth = thickness,
                loop = { rotate = { 0, 22.5, 2 }, paused = not playing } } }
    end
    local remaining = sweep * (1 - fraction) - spacing
    if remaining > 1 then
        arc[#arc + 1] = ui.path{ d = geometry.band(middle, middle, radius, thickness, start + sweep * fraction + spacing,
            remaining), w = ringSize, h = ringSize, fill = "secondaryContainer" }
    end
    local art = { w = cover, h = cover,
        ui.path{ d = shapes.path("Cookie12Sided"), viewBox = shapes.viewBox, w = cover, h = cover, mask = true,
            loop = { rotate = { 360, 0, 23.5 }, paused = not playing } },
        ui.box{ w = cover, h = cover, fill = "highestSurface" } }
    art[#art + 1] = m and m.artwork and ui.image{ image = m.artwork, w = cover, h = cover }
        or surface.icon("art_track", { size = cover * 0.35, color = "secondaryForeground" })
    local function line(text: string, size: number, color: string)
        return ui.text{ text = text, font = "sans", size = size, color = color, maxWidth = MEDIA - 32 }
    end
    local controls = ui.row{ w = MEDIA - 2 * tokens.padding.large, gap = tokens.spacing.extraSmall,
        surface.button("skip_previous", "tonal", { onClick = m and m.previous }),
        surface.button(playing and "pause" or "play_arrow", "filled", { grow = 1, w = 0, radius = tokens.rounding.medium,
            onClick = m and m.toggle }),
        surface.button("skip_next", "tonal", { onClick = m and m.next }) }
    if not m then
        for index = 1, #controls do
            controls[index].hover = nil
        end
    end
    local column = { gap = 0, w = MEDIA,
        ui.stack{ w = MEDIA, h = ringSize + tokens.padding.medium,
            ui.stack(arc),
            ui.stack{ align = "top", dy = tokens.padding.medium + tokens.spacing.extraSmall / 2 + band, ui.stack(art) } },
        ui.box{ w = 1, h = tokens.spacing.medium },
        line(m and m.title or omniwm.l10n("Nothing is playing"), tokens.title.small, "accent"),
        ui.box{ w = 1, h = tokens.spacing.small },
        line(m and m.album or "", tokens.body.small, "mutedForeground"),
        ui.box{ w = 1, h = tokens.spacing.small },
        line(m and m.artist or "", tokens.body.medium, "secondaryAccent"),
        ui.box{ w = 1, h = tokens.spacing.medium },
        controls,
        ui.box{ w = 1, h = tokens.spacing.small },
        ui.image{ image = "assets/bongocat.gif", grow = 1, w = MEDIA - 2 * tokens.padding.extraLargeIncreased, h = 44,
            playing = playing, speed = playing and (ctx.data.tempo or 120) / 300 or 0.4 } }
    return card(MEDIA, height, tokens.rounding.extraLarge * 2, { ui.column(column) })
end

local function tab(ctx: Context)
    return ui.row{ gap = GAP, center = false,
        ui.column{ gap = GAP, center = false,
            ui.row{ gap = GAP, weather(ctx), user(ctx) },
            ui.row{ gap = GAP, dateTime(ctx), calendar(ctx), resources(ctx) } },
        media(ctx) }
end

return table.freeze({
    size = table.freeze({ w = WEATHER + USER + MEDIA + 2 * GAP, h = TOP + GAP + BOTTOM }),
    tab = tab,
    calendar = calendar,
    calendarWidth = CALENDAR,
})
