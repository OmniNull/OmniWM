-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local panel = require("./panel")
local panelFrame = require("./panel-frame")

local function line(vertical, props)
    return vertical and ui.column(props) or ui.row(props)
end

local function spacer(vertical, length)
    return vertical and ui.box{ w = 1, h = length } or ui.box{ w = length, h = 1 }
end

local function badge(text, size, fill, color, align, dx, dy)
    return ui.row{ align = align, dx = dx, dy = dy, h = size, radius = size / 2, fill = fill,
        border = "surface", borderWidth = 1,
        ui.box{ w = 2.5, h = 1 },
        ui.text{ text = text, style = "mono", size = size - 3, weight = "bold", color = color },
        ui.box{ w = 2.5, h = 1 } }
end

local function statsPanel(ctx, props)
    local style = ctx.data.bar.style
    local attached = not style.vertical
    local width = props.w
    props.center = true
    for _, index in { 1, #props } do
        local section = props[index]
        section.dy = (section.dy or 0) + (index == 1 and -4 or 4)
        props[index] = ui.stack{ section }
    end
    local body = { w = width - (attached and panelFrame.shoulder * 2 or 8), gap = 0,
        radius = panelFrame.corner, fill = "background", border = "border", borderWidth = 1, ui.column(props) }
    local edge
    if attached then
        local flip = style.position == "bottom"
        local band = ui.box{ w = body.w, h = panelFrame.shoulder }
        if flip then
            body[#body + 1] = band
        else
            table.insert(body, 1, band)
        end
        edge = panelFrame.edge(body.w, flip, true)
        edge.align = flip and "bottom" or "top"
    end
    return ui.stack{ w = width, material = "clear", attach = attached or nil, ui.column(body), edge }
end

local function statsCircle(size, stroke)
    local c = size / 2
    local r = c - stroke / 2
    return string.format("M%g %g A%g %g 0 1 1 %g %g A%g %g 0 1 1 %g %g", c, c - r, r, r, c, c + r, r, r, c, c - r)
end

local function statsArc(size, stroke, value)
    if not value or value <= 0.001 then
        return nil
    end
    if value >= 0.999 then
        return statsCircle(size, stroke)
    end
    local c = size / 2
    local r = c - stroke / 2
    local angle = (value * 2 - 0.5) * math.pi
    return string.format("M%g %g A%g %g 0 %d 1 %.2f %.2f", c, c - r, r, r, value > 0.5 and 1 or 0,
        c + r * math.cos(angle), c + r * math.sin(angle))
end

local function statsCard(props)
    props.radius, props.fill, props.border, props.borderWidth = 14, "surface", "border", 1
    if props.center == nil then
        props.center = false
    end
    return ui.column(props)
end

local function statsGauge(metric, width, tint)
    local size, stroke = 64, 6
    local path = statsArc(size, stroke, metric.value)
    local color = if metric.warn or metric.hot then "warning" else tint
    local contents = { w = width, pad = 12, gap = 8,
        ui.stack{ w = size, h = size,
            ui.path{ w = size, h = size, d = statsCircle(size, stroke), border = tint .. "/0.16", borderWidth = stroke },
            ui.text{ text = metric.percent, size = 14, weight = "bold" },
            if path then ui.path{ w = size, h = size, d = path, border = color, borderWidth = stroke } else nil },
        ui.row{ gap = 5,
            ui.symbol{ name = metric.symbol, size = 10, weight = "semibold", color = tint },
            ui.text{ text = metric.title, size = 14, weight = "bold" } } }
    if metric.temperatureText then
        contents[#contents + 1] = ui.text{ text = metric.temperatureText, style = "mono", size = 12,
            color = if metric.hot then "warning" else "secondaryForeground" }
    end
    contents[#contents + 1] = ui.text{ text = metric.detail, size = 12, color = "secondaryForeground",
        maxWidth = width - 24, lines = 2 }
    contents.center = true
    return statsCard(contents)
end

local function statsBar(metric, width, tint)
    return ui.column{ w = width, gap = 5, center = false,
        ui.row{ w = width, gap = 8,
            ui.stack{ w = 24, h = 24, radius = 12, fill = tint .. "/0.18",
                ui.symbol{ name = metric.symbol, size = 11, weight = "semibold", color = tint } },
            ui.column{ gap = 1, center = false, grow = 1,
                ui.text{ text = metric.title, size = 14, weight = "bold" },
                ui.text{ text = metric.detail, size = 12, color = "secondaryForeground", maxWidth = width - 90, lines = 2 } },
            ui.text{ text = metric.percent, size = 14, weight = "bold" } },
        ui.progress{ value = metric.value or 0, w = width, h = 6, radius = 3, fill = tint .. "/0.16",
            color = if metric.warn then "warning" else tint, animate = "ease" } }
end

local function statsHeader(m, width)
    local host = m.host
    return ui.row{ w = width, gap = 10,
        ui.stack{ w = 34, h = 34, radius = 17, fill = "accent",
            ui.symbol{ name = "applelogo", size = 16, weight = "semibold", color = "accentForeground" } },
        ui.column{ gap = 1, center = false, grow = 1,
            ui.text{ text = host and host.name or omniwm.l10n("System"), size = 14, weight = "bold", maxWidth = width - 170 },
            ui.text{ text = host and host.chip or omniwm.l10n("Loading…"), size = 12, color = "secondaryForeground",
                maxWidth = width - 170 } },
        ui.row{ h = 22, gap = 4, radius = 11, fill = "blue/0.2",
            ui.box{ w = 4, h = 1 },
            ui.symbol{ name = "clock.arrow.circlepath", size = 10, weight = "semibold", color = "blue" },
            ui.text{ text = host and host.uptime or "—", style = "mono", size = 12, weight = "semibold", color = "blue" },
            ui.box{ w = 5, h = 1 } } }
end

local function statsLine(symbol, label, value, width, tint)
    return ui.row{ w = width, gap = 8,
        ui.stack{ w = 24, h = 24, radius = 12, fill = tint .. "/0.18",
            ui.symbol{ name = symbol, size = 11, weight = "semibold", color = tint } },
        ui.text{ text = label, size = 12, color = "secondaryForeground", grow = 1 },
        ui.text{ text = value, style = "mono", size = 12, weight = "semibold", maxWidth = width - 105 } }
end

local function statsNetwork(m, width)
    local inner, height = width - 20, 48
    local graph = { w = inner, h = height }
    if m.network.graph then
        local down, up = m.network.graph(inner, height)
        graph[#graph + 1] = ui.path{ w = inner, h = height, d = down, border = "cyan", borderWidth = 2 }
        graph[#graph + 1] = ui.path{ w = inner, h = height, d = up, border = "purple", borderWidth = 2 }
    else
        graph[#graph + 1] = ui.text{ text = omniwm.l10n("Collecting data…"), size = 12, color = "secondaryForeground" }
    end
    return statsCard{ w = width, pad = 10, gap = 8,
        ui.row{ gap = 5,
            ui.symbol{ name = "network", size = 11, weight = "semibold", color = "cyan" },
            ui.text{ text = omniwm.l10n("Network"), size = 14, weight = "bold" } },
        ui.stack(graph),
        statsLine("arrow.down", omniwm.l10n("Download"), m.network.down, inner, "cyan"),
        statsLine("arrow.up", omniwm.l10n("Upload"), m.network.up, inner, "purple"),
        statsLine("arrow.up.arrow.down", omniwm.l10n("Total"), m.network.total, inner, "blue") }
end

local function statsBattery(m, width)
    local battery = m.battery
    local tint = if battery.low then "warning" else "green"
    return statsCard{ w = width, pad = 10, gap = 6,
        statsLine(battery.symbol, omniwm.l10n("Battery"), battery.percent, width - 20, tint),
        ui.progress{ value = battery.level, w = width - 20, h = 6, radius = 3, fill = tint .. "/0.16", color = tint },
        ui.text{ text = battery.status, size = 12, color = "secondaryForeground", maxWidth = width - 20 } }
end

local function statsDetails(m, width)
    if not m.host then
        return statsCard{ w = width, pad = 10,
            ui.text{ text = omniwm.l10n("Loading…"), size = 12, color = "secondaryForeground" } }
    end
    return statsCard{ w = width, pad = 10, gap = 6,
        ui.row{ gap = 8,
            ui.symbol{ name = "laptopcomputer", w = 16, h = 14, size = 12, color = "secondaryForeground" },
            ui.text{ text = m.host.model .. " · " .. m.host.os, size = 12, weight = "medium", maxWidth = width - 44, lines = 2 } },
        ui.row{ gap = 8,
            ui.symbol{ name = "display.2", w = 16, h = 14, size = 12, color = "secondaryForeground" },
            ui.text{ text = table.concat(m.displays, "  ·  "), size = 12, color = "secondaryForeground",
                maxWidth = width - 44, lines = 2 } } }
end

local AUDIO_WIDTH = 360
local AUDIO_INNER = AUDIO_WIDTH - 2 - 24
local AUDIO_CARD = AUDIO_INNER - 20

local function audioRound(name, command, active, size)
    return ui.stack{ w = size, h = size, radius = size / 2, hover = "focus/0.14", onClick = command,
        fill = active and "error/0.18" or "elevatedSurface",
        ui.symbol{ name = name, size = size * 0.42, weight = "semibold", color = active and "error" or "foreground" } }
end

local function audioCard(props)
    props.w, props.pad, props.radius = AUDIO_INNER, 10, 14
    props.fill, props.border, props.borderWidth, props.center = "surface", "border", 1, false
    return ui.column(props)
end

local function audioSection(text)
    return ui.row{ w = AUDIO_INNER, ui.box{ w = 4, h = 1 },
        ui.text{ text = text, size = 12, weight = "semibold", color = "secondaryForeground" } }
end

local function audioApp(app)
    return ui.row{ w = AUDIO_CARD, gap = 8,
        ui.icon{ app = app.id, w = 20, h = 20, opacity = if app.playing then 1 else 0.55 },
        ui.text{ text = app.name, size = 14, w = 72, maxWidth = 72,
            color = if app.playing then "foreground" else "secondaryForeground" },
        ui.slider{ value = app.level, w = AUDIO_CARD - 136, h = 14,
            color = if app.muted then "mutedForeground" else "accent", onChange = app.set },
        audioRound(app.symbol, app.mute, app.muted, 24) }
end

local function audioOutput(device)
    local chosen = device.default
    return ui.row{ w = AUDIO_CARD, gap = 10, pad = 3, radius = 10, hover = "focus/0.14", onClick = device.select,
        ui.stack{ w = 26, h = 26, radius = 13, fill = chosen and "accent" or "elevatedSurface",
            ui.symbol{ name = device.symbol, size = 12, weight = "semibold",
                color = chosen and "accentForeground" or "secondaryForeground" } },
        ui.text{ text = device.name, size = 14, grow = 1, maxWidth = AUDIO_CARD - 70,
            weight = chosen and "semibold" or nil, color = chosen and "foreground" or "secondaryForeground" },
        ui.stack{ w = 16, h = 16,
            ui.path{ w = 16, h = 16, d = "M8 0.75 A7.25 7.25 0 1 1 8 15.25 A7.25 7.25 0 1 1 8 0.75 Z",
                border = chosen and "accent" or "mutedForeground/0.6", borderWidth = 1.5 },
            ui.box{ w = 8, h = 8, radius = 4, fill = chosen and "accent" or nil } },
        ui.box{ w = 2, h = 1 } }
end

local function framedPanel(ctx, props, width)
    width = width or props.w or 300
    props.w = width - 2
    props.pad = props.pad or 12
    props.gap = props.gap or 10
    props.center = false
    return panel(ctx.data.bar.style, width, ui.column(props))
end

local COMPACT_STATS_TINTS = { cpu = "accent", memory = "blue", gpu = "purple", disk = "orange", down = "green", up = "teal" }

local function capsule(ctx, props)
    local style = ctx.data.bar.style
    local size = 32 * style.height / 40
    props.radius = size / 2 - 1
    props.fill = style.backgrounds and "surface" or nil
    props.border, props.borderWidth = style.backgrounds and "border/0.6" or nil, 1
    if style.vertical then
        props.w = size
    else
        props.h = size
    end
    if props.w == props.h then
        return ui.stack(props)
    end
    return line(style.vertical, props)
end

local function squareChip(ctx, child)
    local size = 32 * ctx.data.bar.style.height / 40
    return capsule(ctx, { w = size, h = size, hover = "focus/0.14", child })
end

local function symbolChip(ctx, m)
    local scale = ctx.data.bar.style.height / 40
    return squareChip(ctx, ui.symbol{ name = m.symbol, size = 18 * scale, weight = "semibold" })
end

local function compactStatsMeter(ctx, entry, variant)
    local vertical = ctx.data.bar.style.vertical
    local scale = ctx.data.bar.style.height / 40
    local tint = entry.hot and "warning" or COMPACT_STATS_TINTS[entry.key]
    local library = require("./stats")
    if variant == "gauge" then
        return library.gauge(entry.value, 26 * scale, tint,
            ui.text{ text = tostring(math.round(entry.value)), style = "mono", size = 9 * scale, weight = "semibold" })
    end
    local props = { gap = (vertical and 2 or 5) * scale, library.gauge(entry.value, 18 * scale, tint) }
    if variant == "graph" then
        props[#props + 1] = library.sparkline(entry.history, (vertical and 24 or 34) * scale, 14 * scale, tint)
    end
    props[#props + 1] = ui.text{ text = if vertical then tostring(entry.value) else ctx.format.percent(entry.value / 100),
        style = vertical and "mono" or nil, size = 14 * scale, weight = "semibold",
        reserve = if vertical then nil else ctx.format.percent(1) }
    return line(vertical, props)
end

local function compactStatsPanel(ctx, m)
    local width, inner = 340, 314
    local rows = { w = inner, pad = 10, gap = 8 }
    for _, entry in m.rows do
        local tint = COMPACT_STATS_TINTS[entry.key]
        local color = entry.hot and "warning" or tint
        local row = { w = inner - 20, gap = 9,
            ui.stack{ w = 24, h = 24, radius = 12, fill = tint .. "/0.18",
                ui.symbol{ name = entry.symbol, size = 11, weight = "semibold", color = tint } },
            ui.text{ text = entry.label, size = 14, weight = "medium", w = 72, maxWidth = 72 },
            ui.box{ grow = 1, h = 1 } }
        if entry.history then
            row[#row + 1] = require("./stats").sparkline(entry.history, 44, 18, color)
        elseif entry.value then
            row[#row + 1] = ui.progress{ value = math.clamp(entry.value / 100, 0, 1), w = 44, h = 5, radius = 2.5,
                fill = "foreground/0.12", color = color, animate = "ease" }
        end
        row[#row + 1] = ui.row{ w = 74, ui.box{ grow = 1, h = 1 },
            ui.text{ text = entry.text, style = "mono", size = 12, weight = "semibold", maxWidth = 74 } }
        rows[#rows + 1] = ui.row(row)
    end
    return framedPanel(ctx, { statsCard(rows) }, width)
end

local function utilityPanel(ctx, m, library, title, width)
    width = width or 340
    local inner = width - 26
    local content = library.content(ctx, inner, m)
    local header
    if m then
        header = table.remove(content, 1)
        header[1].size, header[1].weight = 15, "bold"
        if m.power == nil or (m.power and (not m.devices or #m.devices > 0)) then
            content[1] = statsCard(content[1])
        end
    else
        header = ui.row{ w = inner, ui.text{ text = title, size = 15, weight = "bold" } }
        content = statsCard(content)
    end
    header.gap = 0
    table.insert(header, 1, ui.box{ w = 2, h = 1 })
    return framedPanel(ctx, { header, content }, width)
end

local function worldClockBar(ctx, m)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local props = { gap = (style.vertical and 2 or 7) * scale, hover = "focus/0.14" }
    if style.vertical then
        props[#props + 1] = ui.box{ w = 1, h = 4 * scale }
        props[#props + 1] = ui.symbol{ name = "globe", size = 15 * scale, color = "secondaryForeground" }
        props[#props + 1] = ui.text{ text = string.format("%02d", m.clocks[1].hour), style = "mono",
            size = 14 * scale, weight = "semibold", color = "accent" }
        props[#props + 1] = ui.box{ w = 1, h = 4 * scale }
    else
        props[#props + 1] = ui.box{ w = 2 * scale, h = 1 }
        props[#props + 1] = ui.symbol{ name = "globe", size = 16 * scale, color = "secondaryForeground" }
        for index = 1, m.shown do
            local clock = m.clocks[index]
            if index > 1 then
                props[#props + 1] = ui.box{ w = 1, h = 14 * scale, fill = "border" }
            end
            props[#props + 1] = ui.text{ text = clock.short, size = 11 * scale, weight = "semibold", color = "secondaryForeground",
                maxWidth = 45 * scale }
            props[#props + 1] = ui.text{ text = clock.time, style = "mono", size = 14 * scale, weight = "semibold",
                color = "accent", reserve = "00:00 PM" }
        end
        props[#props + 1] = ui.box{ w = 2 * scale, h = 1 }
    end
    return capsule(ctx, props)
end

local function audioPanel(ctx, m)
    local rows = { gap = 8 }
    rows[#rows + 1] = ui.row{ w = AUDIO_INNER, gap = 8,
        ui.box{ w = 2, h = 1 },
        ui.text{ text = omniwm.l10n("Volume"), size = 15, weight = "bold" },
        ui.box{ grow = 1, h = 1 },
        ui.text{ text = m.percent or "—", size = 15, weight = "bold",
            color = m.muted and "mutedForeground" or "accent", reserve = ctx.format.percent(1) },
        ui.box{ w = 2, h = 1 } }
    if m.volume then
        rows[#rows + 1] = audioCard{ gap = 0,
            ui.row{ w = AUDIO_CARD, gap = 10,
                ui.symbol{ name = m.symbol, w = 20, h = 18, size = 14, weight = "semibold",
                    color = m.muted and "mutedForeground" or "foreground" },
                ui.slider{ value = m.level, w = AUDIO_CARD - 64, h = 18,
                    color = if m.muted then "mutedForeground" else "accent", onChange = m.set },
                audioRound(m.muteSymbol, m.mute, m.muted, 26) } }
    end
    if #m.outputs > 0 then
        rows[#rows + 1] = audioSection(omniwm.l10n("Output"))
        local list = { gap = 4 }
        for _, device in m.outputs do
            list[#list + 1] = audioOutput(device)
        end
        rows[#rows + 1] = audioCard(list)
    end
    local apps = { gap = 8 }
    if m.permission then
        apps[#apps + 1] = ui.row{ w = AUDIO_CARD, gap = 8, pad = 4, radius = 10,
            hover = "focus/0.14", onClick = m.permission,
            ui.stack{ w = 26, h = 26, radius = 13, fill = "warning/0.18",
                ui.symbol{ name = "lock.fill", size = 11, color = "warning" } },
            ui.text{ text = omniwm.l10n("Allow System Audio Recording to set app volumes"), size = 14,
                maxWidth = AUDIO_CARD - 46, lines = 2 } }
    end
    for _, app in m.apps do
        apps[#apps + 1] = audioApp(app)
    end
    if #apps > 0 then
        rows[#rows + 1] = audioSection(omniwm.l10n("Applications"))
        rows[#rows + 1] = audioCard(apps)
    end
    return framedPanel(ctx, rows, AUDIO_WIDTH)
end

local MEDIA_WIDTH = 360
local MEDIA_INNER = MEDIA_WIDTH - 2 - 24
local MEDIA_CARD = MEDIA_INNER - 24

local function mediaCover(artwork, bundle, size, radius)
    if artwork then
        return ui.image{ image = artwork, w = size, h = size, radius = radius }
    end
    return ui.stack{ w = size, h = size, radius = radius, fill = "elevatedSurface",
        ui.icon{ app = bundle, w = size * 0.6, h = size * 0.6, placeholder = "music.note" } }
end

local function mediaButton(name, command, size, active)
    return ui.stack{ w = size + 16, h = size + 16, radius = 10, hover = "focus/0.14", onClick = command,
        fill = active and "accent/0.18" or nil,
        ui.symbol{ name = name, size = size, weight = "semibold", color = active and "accent" or "foreground" } }
end

local function mediaBar(ctx, m)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size, art = 32 * scale, 24 * scale
    local item = { gap = 6, radius = size / 2 - 1, fill = style.backgrounds and "surface" or nil,
        border = style.backgrounds and "border/0.6" or nil, borderWidth = 1, hover = "focus/0.14" }
    local disc = ui.stack{ w = art, h = art,
        mediaCover(ctx.select("media", "artwork"), ctx.select("media", "bundle"), art, art / 2),
        ui.stack{ align = "bottomTrailing", dx = 3, dy = 3, w = 11, h = 11, radius = 5.5, fill = "accent",
            border = "surface", borderWidth = 1,
            ui.symbol{ name = m.symbol, size = 5, weight = "black", color = "accentForeground" } } }
    if style.vertical then
        item.w, item.h, item[1] = size, size, disc
        return ui.stack(item)
    end
    item.h = size
    item[1], item[2] = ui.box{ w = 0, h = 1 }, disc
    item[3] = ui.text{ text = m.title, size = 14 * scale, weight = "medium", maxWidth = 130 }
    item[4] = ui.box{ w = 3, h = 1 }
    return ui.row(item)
end

local function mediaLyrics(m)
    local lyric = m.lyrics
    if not lyric then
        return nil
    end
    local rows = { w = MEDIA_INNER, pad = 12, gap = 6,
        ui.text{ text = omniwm.l10n("Lyrics"), size = 12, weight = "semibold", color = "secondaryForeground" } }
    if lyric.visible then
        for _, entry in lyric.visible do
            rows[#rows + 1] = ui.row{ w = MEDIA_CARD, pad = 4, radius = 8, hover = "focus/0.14",
                fill = entry.current and "accent/0.1" or nil, onClick = entry.seek,
                ui.text{ text = entry.text, size = 13, maxWidth = MEDIA_CARD - 8,
                    lines = 2, weight = entry.current and "semibold" or nil,
                    color = entry.current and "accent" or "secondaryForeground" } }
        end
    else
        rows[#rows + 1] = ui.text{ text = lyric.message, size = 13, color = "secondaryForeground", maxWidth = MEDIA_CARD }
    end
    return statsCard(rows)
end

local function mediaPanel(ctx, m)
    if not m then
        return framedPanel(ctx, { pad = 16,
            ui.stack{ w = MEDIA_WIDTH - 2 - 32,
                ui.text{ text = omniwm.l10n("Nothing is playing"), color = "secondaryForeground" } } }, MEDIA_WIDTH)
    end
    local controls = { w = MEDIA_CARD, gap = 6,
        ui.stack{ w = 30, h = 30, radius = 10, hover = "focus/0.14", onClick = m.open, help = m.app,
            ui.icon{ app = m.bundle, w = 18, h = 18, placeholder = "arrow.up.forward.app" } },
        ui.box{ grow = 1, h = 1 } }
    if m.shuffle ~= nil then
        controls[#controls + 1] = mediaButton("shuffle", m.shuffleCommand, 14, m.shuffle)
    end
    controls[#controls + 1] = mediaButton("backward.fill", m.previous, 14)
    controls[#controls + 1] = ui.stack{ w = 44, h = 44, radius = 14, fill = "accent", hoverScale = 1.05,
        onClick = m.toggle,
        ui.symbol{ name = m.playSymbol, size = 18, weight = "bold", color = "accentForeground" } }
    controls[#controls + 1] = mediaButton("forward.fill", m.next, 14)
    if m.repeatMode ~= nil then
        controls[#controls + 1] = mediaButton(m.repeatSymbol, m.repeatCommand, 14, m.repeating)
    end
    controls[#controls + 1] = ui.box{ grow = 1, h = 1 }
    controls[#controls + 1] = ui.box{ w = 30, h = 30 }
    local card = { w = MEDIA_INNER, pad = 12, gap = 12,
        ui.row{ w = MEDIA_CARD, gap = 12,
            mediaCover(m.artwork, m.bundle, 76, 12),
            ui.column{ gap = 3, center = false,
                ui.text{ text = m.title, size = 15, weight = "bold", color = "accent", maxWidth = MEDIA_CARD - 88 },
                ui.text{ text = m.artist, size = 14, color = "foreground", maxWidth = MEDIA_CARD - 88 },
                ui.text{ text = m.album, size = 12, color = "blue", maxWidth = MEDIA_CARD - 88 } } } }
    if m.duration then
        card[#card + 1] = ui.column{ gap = 3,
            ui.slider{ value = m.fraction, w = MEDIA_CARD, h = 12, color = "accent", onChange = m.seek },
            ui.row{ w = MEDIA_CARD,
                ui.text{ text = m.elapsedText, style = "mono", size = 12, color = "secondaryForeground" },
                ui.box{ grow = 1 },
                ui.text{ text = m.durationText, style = "mono", size = 12, color = "secondaryForeground" } } }
    end
    card[#card + 1] = ui.row(controls)
    return framedPanel(ctx, { gap = 8,
        ui.row{ w = MEDIA_INNER, gap = 6,
            ui.box{ w = 2, h = 1 },
            ui.text{ text = omniwm.l10n("Now Playing"), size = 15, weight = "bold" },
            ui.box{ grow = 1, h = 1 },
            ui.text{ text = m.app, size = 12, weight = "semibold", color = "secondaryForeground", maxWidth = 120 },
            ui.box{ w = 2, h = 1 } },
        statsCard(card), mediaLyrics(m) }, MEDIA_WIDTH)
end

local function batteryCell(state, scale, inside)
    local w, h = 24 * scale, 13 * scale
    local tint = state.low and "error" or state.tint
    local props = { w = w, h = h, radius = 3.5 * scale,
        border = state.low and "error/0.8" or "foreground/0.45", borderWidth = 1.2 * scale,
        ui.box{ align = "leading", dx = 2 * scale,
            w = math.max(2 * scale, (w - 4 * scale) * math.clamp(state.level, 0, 100) / 100), h = h - 4 * scale,
            radius = 1.5 * scale, fill = inside and tint .. "/0.22" or tint } }
    if inside then
        props[#props + 1] = ui.text{ text = inside, size = 9 * scale, weight = "semibold", color = "foreground" }
    end
    local body = ui.stack(props)
    if state.charging and not inside then
        body = ui.stack{ w = w, h = h, body,
            ui.symbol{ name = "bolt.fill", size = 8 * scale, weight = "black", color = "background" } }
    end
    return ui.row{ gap = scale, body,
        ui.box{ w = 1.5 * scale, h = 4 * scale, radius = 0.75 * scale,
            fill = state.low and "error/0.8" or "foreground/0.45" } }
end

local function batteryChip(ctx, state, details)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local mode = details and state.mode or "beside"
    local glyph = batteryCell(state, scale, mode == "inside" and state.text or nil)
    local props = { radius = size / 2 - 1, fill = style.backgrounds and "surface" or nil,
        border = style.backgrounds and "border/0.6" or nil, borderWidth = 1,
        hover = details and "focus/0.14" or nil }
    if style.vertical and mode ~= "beside" then
        props.w, props.h, props[1] = size, size, glyph
        return ui.stack(props)
    end
    if style.vertical then
        props.w, props.gap = size, 3
        props[1], props[2] = ui.box{ w = 1, h = 3 }, glyph
        if mode == "beside" then
            props[#props + 1] = ui.text{ text = state.text, style = "mono", size = 14 * scale, weight = "semibold",
                color = state.low and "error" or "foreground" }
        end
        props[#props + 1] = ui.box{ w = 1, h = 3 }
        return ui.column(props)
    end
    props.h, props.gap = size, 6
    props[1], props[2] = ui.box{ w = 2, h = 1 }, glyph
    if mode == "beside" then
        props[#props + 1] = ui.text{ text = state.percent, size = 14 * scale, weight = "semibold",
            color = state.low and "error" or "foreground", reserve = state.reserve }
    end
    props[#props + 1] = ui.box{ w = 2, h = 1 }
    return ui.row(props)
end

local RADIO_WIDTH = 320

local function radioChip(ctx, library, state)
    local style = ctx.data.bar.style
    local size = 32 * style.height / 40
    return ui.stack{ w = size, h = size, radius = size / 2 - 1,
        fill = style.backgrounds and "surface" or nil,
        border = style.backgrounds and "border/0.6" or nil, borderWidth = 1, hover = "focus/0.14",
        library.glyph(state, 18 * style.height / 40) }
end

local CALENDAR_WIDTH = 320
local CALENDAR_INNER = CALENDAR_WIDTH - 2 - 24
local CALENDAR_CARD = CALENDAR_INNER - 20
local CALENDAR_CELL = math.floor(CALENDAR_CARD / 7)

local function clockBar(ctx, m)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local rows = { gap = 7, radius = size / 2 - 1, fill = style.backgrounds and "surface" or nil,
        border = style.backgrounds and "border/0.6" or nil, borderWidth = 1, hover = "focus/0.14" }
    if style.vertical then
        rows.w, rows.gap = size, 0
        rows[#rows + 1] = ui.box{ w = 1, h = 6 }
        if m.showIcon then
            rows[#rows + 1] = ui.symbol{ name = "calendar", size = 12 * scale, color = "secondaryForeground" }
        end
        rows[#rows + 1] = ui.text{ text = m.hour, size = 14 * scale, weight = "bold", color = "accent" }
        rows[#rows + 1] = ui.text{ text = m.minute, size = 14 * scale, weight = "medium" }
        if m.meridiem then
            rows[#rows + 1] = ui.text{ text = m.meridiem, size = 9 * scale, color = "secondaryForeground" }
        end
        rows[#rows + 1] = ui.box{ w = 1, h = 6 }
        return ui.column(rows)
    end
    rows.h = size
    rows[#rows + 1] = ui.box{ w = 3, h = 1 }
    if m.showIcon then
        rows[#rows + 1] = ui.symbol{ name = "calendar", size = 14 * scale, color = "secondaryForeground" }
    end
    if m.showDate then
        rows[#rows + 1] = ui.text{ text = m.date, size = 12 * scale, weight = "medium", color = "secondaryForeground" }
        rows[#rows + 1] = ui.box{ w = 3, h = 3, radius = 1.5, fill = "mutedForeground" }
    end
    rows[#rows + 1] = ui.text{ text = m.time, size = 14 * scale, weight = "bold", color = "accent", reserve = "00:00 PM" }
    rows[#rows + 1] = ui.box{ w = 3, h = 1 }
    return ui.row(rows)
end

local function calendarTag(text, scale)
    scale = scale or 1
    return ui.row{ h = 18 * scale, radius = 9 * scale, fill = "blue/0.2",
        ui.box{ w = 7 * scale, h = 1 },
        ui.text{ text = text, size = 12 * scale, weight = "semibold", color = "blue" },
        ui.box{ w = 7 * scale, h = 1 } }
end

local function calendarBar(ctx, m)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local event = m.event
    local glyph = ui.symbol{ name = "calendar", w = 20 * scale, h = 20 * scale, size = 18 * scale,
        weight = "semibold", color = "foreground" }
    local props = { gap = 6, radius = size / 2 - 1, fill = style.backgrounds and "surface" or nil,
        border = style.backgrounds and "border/0.6" or nil, borderWidth = 1, hover = "focus/0.14",
        help = event and event.title or nil }
    if style.vertical then
        props.w, props.gap = size, 3
        props[1], props[2] = ui.box{ w = 1, h = 5 }, glyph
        if event then
            props[#props + 1] = ui.box{ w = 6, h = 6, radius = 3, fill = event.color }
        end
        props[#props + 1] = ui.box{ w = 1, h = 5 }
        return ui.column(props)
    end
    props.h = size
    if not event then
        props.w, props[1] = size, glyph
        return ui.stack(props)
    end
    props[1], props[2] = ui.box{ w = 2, h = 1 }, glyph
    props[3] = ui.box{ w = 3, h = 14, radius = 1.5, fill = event.color }
    props[4] = calendarTag(event.countdown, scale)
    props[5] = ui.box{ w = 0, h = 1 }
    return ui.row(props)
end

local function calendarButton(symbol, command)
    return ui.stack{ w = 26, h = 26, radius = 13, hover = "focus/0.14", onClick = command,
        ui.symbol{ name = symbol, size = 11, weight = "bold", color = "secondaryForeground" } }
end

local function calendarGrid(month, scroll)
    local rows = { gap = 0, center = false, onScroll = scroll }
    local header = { gap = 0 }
    for _, symbol in month.weekdays do
        header[#header + 1] = ui.box{ w = CALENDAR_CELL, h = 20,
            ui.text{ text = symbol, size = 12, weight = "bold", color = "mutedForeground" } }
    end
    rows[#rows + 1] = ui.row(header)
    local week = { gap = 0 }
    for _ = 1, month.offset do
        week[#week + 1] = ui.box{ w = CALENDAR_CELL, h = CALENDAR_CELL }
    end
    for day = 1, month.days do
        local today = day == month.today
        week[#week + 1] = ui.stack{ w = CALENDAR_CELL, h = CALENDAR_CELL,
            ui.stack{ w = CALENDAR_CELL - 5, h = CALENDAR_CELL - 5, radius = (CALENDAR_CELL - 5) / 2,
                fill = if today then "accent" else nil,
                ui.text{ text = tostring(day), size = 14, weight = if today then "bold" else "medium",
                    color = if today then "accentForeground" else "foreground" } },
            if month.marked[day] then ui.box{ align = "bottom", dy = -2, w = 4, h = 4, radius = 2,
                fill = if today then "accentForeground" else "blue" } else nil }
        if #week == 7 then
            rows[#rows + 1] = ui.row(week)
            week = { gap = 0 }
        end
    end
    if #week > 0 then
        rows[#rows + 1] = ui.row(week)
    end
    return ui.column(rows)
end

local function calendarCard(props)
    props.w, props.pad = CALENDAR_INNER, 10
    return statsCard(props)
end

local function calendarAgenda(event)
    local width = if event.countdown then CALENDAR_CARD - 128 else CALENDAR_CARD - 40
    local rows = { w = CALENDAR_CARD, gap = 9, pad = 4, radius = 10, hover = "focus/0.14", onClick = event.open,
        ui.box{ w = 4, h = 30, radius = 2, fill = event.color },
        ui.column{ gap = 2, center = false,
            ui.text{ text = event.title, size = 14, weight = "semibold", maxWidth = width },
            ui.text{ text = event.day .. " · " .. event.when, size = 12, color = "secondaryForeground", maxWidth = width } },
        ui.box{ grow = 1, h = 1 } }
    if event.countdown then
        rows[#rows + 1] = calendarTag(event.countdown)
    end
    return ui.row(rows)
end

local function calendarAction(symbol, text, command)
    return ui.row{ w = CALENDAR_INNER, gap = 8, pad = 6, radius = 10, hover = "focus/0.14", onClick = command,
        ui.stack{ w = 24, h = 24, radius = 12, fill = "elevatedSurface",
            ui.symbol{ name = symbol, size = 11, weight = "semibold", color = "secondaryForeground" } },
        ui.text{ text = text, size = 14, weight = "medium", maxWidth = CALENDAR_INNER - 50, lines = 2 } }
end

local function calendarPanel(ctx, m)
    local header = { w = CALENDAR_INNER, gap = 2,
        ui.box{ w = 2, h = 1 },
        ui.text{ text = m.month and m.month.title or omniwm.l10n("Calendar"), size = 15, weight = "bold", grow = 1 } }
    local rows = { gap = 8 }
    if m.month then
        header[#header + 1] = calendarButton("chevron.left", m.previous)
        header[#header + 1] = calendarButton("smallcircle.filled.circle", m.today)
        header[#header + 1] = calendarButton("chevron.right", m.next)
        rows[#rows + 1] = ui.row(header)
        rows[#rows + 1] = calendarCard{ calendarGrid(m.month, m.scroll) }
    else
        rows[#rows + 1] = ui.row(header)
    end
    if m.agenda then
        local agenda = { gap = 2 }
        for _, event in m.agenda do
            agenda[#agenda + 1] = calendarAgenda(event)
        end
        if #agenda == 0 then
            agenda[1] = ui.text{ text = omniwm.l10n("No upcoming events"), size = 14, color = "secondaryForeground" }
        end
        rows[#rows + 1] = calendarCard(agenda)
    elseif m.action then
        rows[#rows + 1] = calendarAction(m.action.symbol, m.action.text, m.action.command)
    end
    rows[#rows + 1] = calendarAction("arrow.up.forward.app", omniwm.l10n("Open Calendar"), m.open)
    return framedPanel(ctx, rows, CALENDAR_WIDTH)
end

local WEATHER_WIDTH = 480
local WEATHER_INNER = WEATHER_WIDTH - 2 - 24
local WEATHER_CARD = WEATHER_INNER - 20

local function weatherBar(ctx, m)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local item = { gap = 5, radius = size / 2 - 1, fill = style.backgrounds and "surface" or nil,
        border = style.backgrounds and "border/0.6" or nil, borderWidth = 1, hover = "focus/0.14",
        ui.symbol{ name = m.symbol, w = 22 * scale, h = 22 * scale,
            size = 20 * scale, weight = "medium", color = "foreground" } }
    if style.vertical then
        item.w, item.gap = size, 2
        table.insert(item, 1, ui.box{ w = 1, h = 4 })
        item[#item + 1] = ui.text{ text = m.temp, style = "mono", size = 14 * scale, weight = "semibold" }
        item[#item + 1] = ui.box{ w = 1, h = 4 }
        return ui.column(item)
    end
    item.h = size
    table.insert(item, 1, ui.box{ w = 1, h = 1 })
    item[#item + 1] = ui.text{ text = m.temp, size = 14 * scale, weight = "semibold", reserve = "-00°" }
    item[#item + 1] = ui.box{ w = 2, h = 1 }
    return ui.row(item)
end

local function weatherChip(symbol, text)
    return ui.row{ h = 24, gap = 5, radius = 12, fill = "surface", border = "border", borderWidth = 1,
        ui.box{ w = 4, h = 1 },
        ui.symbol{ name = symbol, w = 13, h = 13, size = 11, weight = "semibold", color = "blue" },
        ui.text{ text = text, size = 12, weight = "medium" },
        ui.box{ w = 5, h = 1 } }
end

local function weatherCard(props)
    props.w, props.pad = WEATHER_INNER, 10
    return statsCard(props)
end

local function weatherHourly(m)
    local strip = { gap = 0 }
    local column = math.floor(WEATHER_CARD / m.forecastHours)
    for index, hour in m.hours do
        strip[#strip + 1] = ui.column{ w = column, gap = 5, help = hour.condition,
            ui.text{ text = hour.label, size = 12, weight = "medium", color = "secondaryForeground" },
            ui.symbol{ name = hour.symbol, w = 16, h = 16, size = 13, color = index == 1 and "accent" or "foreground" },
            ui.text{ text = hour.temp, size = 12, weight = index == 1 and "bold" or "medium",
                color = index == 1 and "accent" or "foreground" } }
    end
    return ui.row(strip)
end

local function weatherTrailing(element)
    return ui.row{ w = 30, ui.box{ grow = 1, h = 1 }, element }
end

local function weatherDaily(m)
    local track = WEATHER_CARD - 210
    local rows = { gap = 6 }
    for index, day in m.days do
        rows[#rows + 1] = ui.row{ w = WEATHER_CARD, gap = 8,
            ui.text{ text = day.label, size = 14, weight = index == 1 and "bold" or "medium", w = 52, maxWidth = 52 },
            ui.symbol{ name = day.symbol, w = 18, h = 16, size = 13, help = day.condition },
            ui.text{ text = day.rain or "", size = 12, weight = "semibold", color = "blue", w = 34 },
            weatherTrailing(ui.text{ text = day.low, size = 14, color = "secondaryForeground" }),
            ui.stack{ w = track, h = 5, radius = 2.5, fill = "foreground/0.1",
                ui.box{ align = "leading", dx = day.from * track, w = math.max(5, (day.to - day.from) * track),
                    h = 5, radius = 2.5, fill = "accent" } },
            weatherTrailing(ui.text{ text = day.high, size = 14, weight = "semibold" }) }
    end
    return ui.column(rows)
end

local function weatherPanel(ctx, m)
    if not m then
        return nil
    end
    local summary = { gap = 1, center = false,
        ui.text{ text = m.temp, size = 30, weight = "bold" },
        ui.text{ text = m.condition, size = 14, weight = "medium", color = "secondaryForeground" } }
    if m.feels then
        summary[#summary + 1] = ui.text{ text = m.feels, size = 12, color = "mutedForeground" }
    end
    local place = { gap = 3, center = false }
    if m.place then
        place[#place + 1] = ui.row{ gap = 4,
            ui.symbol{ name = "location.fill", size = 9, color = "accent" },
            ui.text{ text = m.place, size = 14, weight = "bold", maxWidth = 130 } }
    end
    if m.high then
        place[#place + 1] = ui.text{ text = m.high .. "  " .. m.low, size = 12, color = "secondaryForeground" }
    end
    local rows = { gap = 10,
        ui.row{ w = WEATHER_INNER, gap = 12,
            ui.box{ w = 2, h = 1 },
            ui.symbol{ name = m.symbol, w = 46, h = 42, size = 36, color = "accent" },
            ui.column(summary), ui.box{ grow = 1, h = 1 }, ui.column(place), ui.box{ w = 2, h = 1 } } }
    local chips = { gap = 6 }
    if m.rain then
        chips[#chips + 1] = weatherChip("umbrella.fill", m.rain)
    end
    if m.wind then
        chips[#chips + 1] = weatherChip("wind", m.wind)
    end
    if #chips > 0 then
        rows[#rows + 1] = ui.row(chips)
    end
    if #m.hours > 0 then
        rows[#rows + 1] = weatherCard{ weatherHourly(m) }
    end
    if #m.days > 0 then
        rows[#rows + 1] = weatherCard{ weatherDaily(m) }
    end
    local footer = { w = WEATHER_INNER, gap = 6, ui.box{ w = 2, h = 1 } }
    if m.stale then
        footer[#footer + 1] = ui.symbol{ name = "exclamationmark.triangle.fill", size = 10, color = "warning" }
        footer[#footer + 1] = ui.text{ text = m.stale, size = 12, color = "warning" }
        footer[#footer + 1] = ui.box{ grow = 1, h = 1 }
    end
    footer[#footer + 1] = ui.text{ text = m.attribution, size = 12, color = "mutedForeground" }
    rows[#rows + 1] = ui.row(footer)
    return framedPanel(ctx, rows, WEATHER_WIDTH)
end

return require("./skin")({
    base = 40,
    hover = "focus/0.14",
    primaryButton = { w = 40, h = 40, radius = 20, fill = "accent", color = "accentForeground" },
    controlCenterBar = symbolChip,
    controlCenterPanel = function(ctx, props)
        props.w -= 2
        return framedPanel(ctx, props)
    end,
    activeWindowBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 40
        local size = 32 * scale
        local props = { w = style.vertical and size or nil, h = size, gap = 7 * scale, pad = 6 * scale,
            radius = size / 2 - 1, fill = style.backgrounds and "surface" or nil,
            border = style.backgrounds and "border/0.6" or nil, borderWidth = 1, hover = "focus/0.14" }
        if m.showIcon then
            props[#props + 1] = ui.icon{ app = m.bundle, w = 20 * scale, h = 20 * scale, placeholder = "app.dashed" }
        end
        if m.showText then
            props[#props + 1] = ui.text{ text = m.title, size = 14 * scale, weight = "medium",
                color = "foreground", maxWidth = m.maxWidth }
        end
        return line(style.vertical, props)
    end,
    clockBar = clockBar,
    calendarBar = calendarBar,
    calendarPanel = calendarPanel,
    weatherBar = weatherBar,
    weatherPanel = weatherPanel,
    statsBar = function(ctx, m)
        local scale = ctx.data.bar.style.height / 40
        local vertical = ctx.data.bar.style.vertical
        local props = { gap = (vertical and 6 or 9) * scale, hover = "focus/0.14",
            spacer(vertical, (vertical and 3 or 1) * scale) }
        for _, entry in m.meters do
            props[#props + 1] = compactStatsMeter(ctx, entry, m.variant)
        end
        props[#props + 1] = spacer(vertical, (vertical and 3 or 0) * scale)
        return capsule(ctx, props)
    end,
    statsPanel = compactStatsPanel,
    inputSourceBar = function(ctx, m)
        local scale = ctx.data.bar.style.height / 40
        return squareChip(ctx,
            ui.text{ text = m.short, size = 13 * scale, weight = "semibold", maxWidth = 32 * scale - 6 })
    end,
    inputSourcePanel = function(ctx, m)
        return utilityPanel(ctx, m, require("./input-source"), omniwm.l10n("Input Sources"))
    end,
    launcherBar = symbolChip,
    privacyBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 40
        local props = { gap = 6 * scale, pad = 6 * scale }
        if #m.indicators == 1 then
            props.w, props.h = 32 * scale, 32 * scale
        end
        for _, indicator in m.indicators do
            props[#props + 1] = if m.icons
                then ui.symbol{ name = indicator.symbol, size = 16 * scale, weight = "semibold", color = indicator.color }
                else ui.box{ w = 7 * scale, h = 7 * scale, radius = 3.5 * scale, fill = indicator.color }
        end
        return capsule(ctx, props)
    end,
    worldClockBar = worldClockBar,
    worldClockPanel = function(ctx, m)
        return utilityPanel(ctx, m, require("./world-clock"), omniwm.l10n("World Clock"))
    end,
    wifiBar = function(ctx, state)
        return radioChip(ctx, require("./wifi"), state)
    end,
    bluetoothBar = function(ctx, state)
        return radioChip(ctx, require("./bluetooth"), state)
    end,
    wifiPanel = function(ctx, m)
        return utilityPanel(ctx, m, require("./wifi"), omniwm.l10n("Wi-Fi"), RADIO_WIDTH)
    end,
    bluetoothPanel = function(ctx, m)
        return utilityPanel(ctx, m, require("./bluetooth"), omniwm.l10n("Bluetooth"), RADIO_WIDTH)
    end,
    batteryBar = function(ctx, state)
        return batteryChip(ctx, state, false)
    end,
    batteryDetailsBar = function(ctx, state)
        return batteryChip(ctx, state, true)
    end,
    batteryPanel = function(ctx, m)
        local width = 320
        local inner = width - 26
        return framedPanel(ctx, { gap = 10,
            ui.row{ w = inner, gap = 0,
                ui.box{ w = 2, h = 1 },
                ui.text{ text = omniwm.l10n("Battery"), size = 15, weight = "bold" } },
            require("./battery").content(ctx, inner, m) }, width)
    end,
    width = 300,
    widths = { workspaces = 274, ["system-stats"] = 380, ["control-center"] = 316 },
    size = { text = 14, icon = 24, slot = 27 },
    volumeBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 40
        local size = 32 * scale
        local muted = m.muted or m.volume == 0
        local glyph = ui.symbol{ name = m.symbol, w = 20 * scale, h = 20 * scale, size = 18 * scale,
            weight = "semibold", color = muted and "mutedForeground" or "foreground" }
        local node = { gap = 5, radius = size / 2 - 1, fill = style.backgrounds and "surface" or nil,
            border = style.backgrounds and "border/0.6" or nil, borderWidth = 1, hover = "focus/0.14" }
        if style.vertical then
            node.w, node.gap = size, 2
            node[1], node[2] = ui.box{ w = 1, h = 4 }, glyph
            if m.volume then
                node[3] = ui.text{ text = tostring(m.volume), style = "mono", size = 14 * scale, weight = "semibold" }
            end
            node[#node + 1] = ui.box{ w = 1, h = 4 }
            return ui.column(node)
        end
        node.h = size
        node[1], node[2] = ui.box{ w = 2, h = 1 }, glyph
        if m.volume then
            node[3] = ui.text{ text = m.percent, size = 14 * scale, weight = "semibold",
                color = muted and "mutedForeground" or "foreground", reserve = ctx.format.percent(1) }
        end
        node[#node + 1] = ui.box{ w = 3, h = 1 }
        return ui.row(node)
    end,
    audioPanel = audioPanel,
    mediaBar = mediaBar,
    mediaPanel = mediaPanel,
    omniwmButton = function(ctx, glyph)
        local style = ctx.data.bar.style
        local scale = style.height / 40
        local size = 32 * scale
        glyph.size = 24 * scale
        return { w = size, h = size, radius = size / 2,
            fill = style.backgrounds and "accent/0.18" or nil, hoverScale = 1.06 }, size
    end,
    systemStatsButton = function(ctx, glyph)
        local style = ctx.data.bar.style
        local size = 32 * style.height / 40
        glyph.size, glyph.weight, glyph.color = math.max(11, size * 0.5), "semibold", "foreground"
        return { w = size, h = size, radius = size / 2 - 1,
            fill = style.backgrounds and "surface" or nil, border = style.backgrounds and "border/0.6" or nil,
            borderWidth = 1, hover = "focus/0.14" }
    end,
    systemStatsSection = function(ctx, kind, m, width)
        if not ctx.data.bar.style.vertical then
            width -= 20
        end
        if kind == "header" then
            return statsHeader(m, width)
        elseif kind == "metrics" then
            local half = (width - 10) / 2
            return ui.column{ w = width, gap = 10, center = false,
                ui.row{ w = width, gap = 10, statsGauge(m.cpu, half, "cyan"), statsGauge(m.gpu, half, "purple") },
                statsCard{ w = width, pad = 10, gap = 12,
                    statsBar(m.memory, width - 20, "green"), statsBar(m.disk, width - 20, "orange") } }
        elseif kind == "network" then
            return statsNetwork(m, width)
        elseif kind == "battery" then
            return statsBattery(m, width)
        elseif kind == "details" then
            return statsDetails(m, width)
        end
        return nil
    end,
    systemStatsPanel = statsPanel,
    hiddenMenuPanel = function(_, rows)
        rows.radius, rows.material, rows.fill = 18, "clear", "background"
        rows.border, rows.borderWidth, rows.center = "border", 1, false
        return ui.column(rows)
    end,
    panel = framedPanel,
    list = function(props)
        props.center = false
        props.gap = props.gap or 2
        props.divided = nil
        return ui.column(props)
    end,
    workspaceMetrics = function(_, style, m)
        return { item = if m.indicator == "pills" then 32 * m.scale else m.item, chip = 24 * m.scale }
    end,
    workspaceMarker = function(_, workspace, style, m)
        if m.indicator ~= "pills" or (m.compact and not style.labels) then
            return nil
        end
        local focused = workspace.focused
        local fill = if focused then (if style.accents then "accent" else "foreground") else "elevatedSurface"
        local color = if focused then (if style.accents then "accentForeground" else "background") else "secondaryForeground"
        if not style.backgrounds and not (focused and style.accents) then
            fill = nil
            color = if focused then "foreground" else color
        end
        local label = ui.text{ text = workspace.name, size = 14 * m.scale, weight = "bold",
            color = if style.textColor ~= nil then "foreground" else color,
            maxWidth = if m.vertical then m.chip - 4 else 96 }
        if utf8.len(workspace.name) <= 2 then
            local length = if focused then m.item else m.chip
            return ui.stack{ w = if m.vertical then m.chip else length,
                h = if m.vertical then length else m.chip, radius = m.chip / 2, fill = fill, label }
        end
        return line(m.vertical, { radius = m.chip / 2, fill = fill,
            w = if m.vertical then m.chip else nil, h = if m.vertical then nil else m.chip,
            spacer(m.vertical, 7), label, spacer(m.vertical, 7) })
    end,
    workspacePill = function(pill, workspace, style, m, occupied)
        if m.indicator ~= "pills" then
            return
        end
        pill.gap = 3
        pill.radius = m.item / 2 - 1
        if not (m.occupiedBackground and occupied and not workspace.focused) then
            pill.fill = if style.backgrounds then "surface" else nil
        end
        pill.hover = "focus/0.14"
        pill.border = if style.backgrounds then "border/0.6" else nil
        pill.borderWidth = 1
    end,
    windowIcon = function(icon, _, item, style, m)
        icon.radius = 6
        icon.hoverScale = 1.08
        if item.focused then
            icon[#icon + 1] = ui.box{ align = if m.vertical then "trailing" else "bottom",
                dx = if m.vertical then 3 else 0, dy = if m.vertical then 0 else 1.5,
                w = if m.vertical then 2 else 8, h = if m.vertical then 8 else 2, radius = 1,
                fill = if style.accents then "accent" else "foreground" }
        end
    end,
    countBadge = function(text, m)
        return badge(text, math.max(11, m.icon * 0.55), "elevatedSurface", "foreground", "bottomTrailing", 3, 1)
    end,
    notificationBadge = function(item, mode, m)
        if mode == "dot" then
            return ui.box{ align = "topTrailing", dx = 1, dy = -1, w = 7, h = 7, radius = 3.5,
                fill = "badge", border = "surface", borderWidth = 1 }
        end
        return badge(item.badge, math.max(11, m.icon * 0.55), "badge", "background", "topTrailing", 3, -2)
    end,
    hiddenIndicator = function(item, m)
        local full = item.count > 0 and item.hidden == item.count
        local size = math.max(10, m.icon * 0.52)
        return ui.stack{ align = "bottomLeading", dx = -1, dy = 1, w = size, h = size, radius = size / 2,
            fill = if full then "badge" else "elevatedSurface", border = "surface", borderWidth = 1,
            ui.symbol{ name = if full then "eye.slash.fill" else "eye.slash", size = size * 0.55,
                weight = "bold", color = if full then "background" else "badge" } }
    end,
    floatingGroup = function(icons, style, m)
        local symbol = math.max(9, m.icon * 0.5)
        local group = { gap = 2, radius = m.slot / 2,
            w = if m.vertical then m.slot else nil, h = if m.vertical then nil else m.slot,
            fill = if style.backgrounds then "elevatedSurface" else nil,
            spacer(m.vertical, 3),
            ui.symbol{ name = "rectangle.on.rectangle", size = symbol, w = symbol, h = symbol, weight = "semibold",
                color = if style.textColor ~= nil then "foreground" else "mutedForeground" } }
        for _, icon in ipairs(icons) do
            group[#group + 1] = icon
        end
        group[#group + 1] = spacer(m.vertical, 1)
        return line(m.vertical, group), 4 + symbol + #icons * m.slot + (#icons + 2) * 2
    end,
    pickerHeader = function(header, item)
        header[1].weight = "bold"
        header[1].maxWidth = 150
        table.insert(header, 1, ui.icon{ app = item.bundle, w = 22, h = 22, placeholder = "app.dashed" })
        table.insert(header, 3, ui.row{ h = 18, radius = 9, fill = "blue/0.2",
            ui.box{ w = 7, h = 1 },
            ui.text{ text = tostring(item.count), size = 11, weight = "bold", color = "blue" },
            ui.box{ w = 7, h = 1 } })
    end,
    pickerRow = function(row, window)
        row.gap = 8
        row.radius = 10
        row.fill = if window.focused then "surface" else nil
        row.border = if window.focused then "border" else nil
        row.borderWidth = 1
        row[1].size = 14
        row[1].weight = if window.focused then "semibold" else nil
        row[1].maxWidth -= 22
        table.insert(row, 1, ui.box{ w = 6, h = 6, radius = 3,
            fill = if window.focused then "accent" else "mutedForeground/0.5" })
    end,
    scratchpadMetrics = function(_, _, m)
        return { item = 32 * m.scale, icon = 24 * m.scale, slot = 27 * m.scale,
            gap = 3, compactGap = 3, edge = 1, compactEdge = 1, spacing = 6 }
    end,
    scratchpadLabel = function(scratchpad, style, m, text, width)
        local active = (scratchpad.revealed or scratchpad.focused) and style.accents
        local fill, color
        if active then
            fill, color = "accent", "accentForeground"
        elseif scratchpad.visible then
            fill, color = "blue/0.2", if style.textColor ~= nil then "foreground" else "blue"
        else
            fill, color = "foreground/0.07", if style.textColor ~= nil then "foreground" else "mutedForeground"
        end
        if not style.backgrounds and not active then
            fill = nil
        end
        local size = 24 * m.scale
        local label = ui.text{ text = text, size = if width then math.min(14 * m.scale, width / 2) else 14 * m.scale,
            weight = "bold",
            color = if style.textColor ~= nil then "foreground" else color, maxWidth = width }
        if scratchpad.compact or m.vertical then
            return ui.stack{ w = size, h = size, radius = size / 2, fill = fill, label }
        end
        return ui.row{ h = size, gap = 4, radius = size / 2, fill = fill,
            ui.box{ w = 5, h = 1 },
            ui.symbol{ name = "tray.fill", size = 9, weight = "bold", color = color },
            label,
            ui.box{ w = 6, h = 1 } }
    end,
    scratchpadCount = function(text, _, _, m)
        local size = m.item - 10
        return ui.row{ h = size, radius = size / 2, fill = "elevatedSurface",
            ui.box{ w = 4, h = 1 },
            ui.text{ text = text, style = "mono", size = size - 6, weight = "bold", color = "foreground" },
            ui.box{ w = 4, h = 1 } }
    end,
    scratchpadPill = function(node, scratchpad, style, m)
        node.radius = m.item / 2 - 1
        node.fill = if style.backgrounds then "surface" else nil
        node.hover = "focus/0.14"
        node.border = if style.backgrounds then "border/0.6" else nil
        node.borderWidth = 1
        node[#node] = spacer(m.vertical, if scratchpad.compact then 3 else 1)
    end,
})
