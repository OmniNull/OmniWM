-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local dash = require("./dash")
local shapes = require("./shapes")
local icons = require("./icons")
local mediatab = require("./mediatab")
local performance = require("./performance")
local status = require("./status")
local surface = require("./surface")
local tokens = require("./tokens")
local weathertab = require("./weathertab")

local FOCUSED_SHAPES = {
    "Slanted", "Oval", "Pill", "Triangle", "Arrow", "Diamond", "Pentagon", "Gem", "VerySunny", "Sunny", "Cookie4Sided",
    "Cookie6Sided", "Cookie7Sided", "Cookie9Sided", "Cookie12Sided", "Clover4Leaf", "SoftBurst", "Ghostish",
}

local SYMBOLS = {
    xmark = "close",
    ["checkmark.circle.fill"] = "check_circle",
    ["eye.slash"] = "visibility_off",
    ["eye.slash.fill"] = "visibility_off",
    ["rectangle.on.rectangle"] = "filter_none",
    ["gauge.with.needle"] = "monitoring",
}

local CONTROL_CENTER_SYMBOLS = {
    ["square.grid.2x2"] = "dashboard",
    ["speaker.wave.2.fill"] = "volume_up",
    ["music.note"] = "music_note",
    calendar = "calendar_month",
    ["cloud.sun.fill"] = "partly_cloudy_day",
}

local function line(vertical, props)
    return vertical and ui.column(props) or ui.row(props)
end

local function focusedShape(ctx, workspace)
    local state = ctx.state
    state.shapes = state.shapes or {}
    if workspace.focused and state.focused ~= workspace.id then
        state.shapes[workspace.id] = FOCUSED_SHAPES[math.random(#FOCUSED_SHAPES)]
    end
    return state.shapes[workspace.id] or FOCUSED_SHAPES[1]
end

local function backdrop(m, offset, length, props)
    props.align = m.vertical and "top" or "leading"
    props.w = m.vertical and m.cell or length
    props.h = m.vertical and length or m.cell
    props.dx = m.vertical and 0 or offset
    props.dy = m.vertical and offset or 0
    props.radius = m.cell / 2
    return ui.box(props)
end

local function scratchpadColors(scratchpad, style)
    local active = (scratchpad.revealed or scratchpad.focused) and style.accents
    local hue = style.accentColor ~= nil and "accent" or "tertiaryAccent"
    local container = style.accentColor ~= nil and "accent/0.22" or "tertiaryContainer"
    local onContainer = style.accentColor ~= nil and "accent" or "tertiaryContainerForeground"
    local tint = style.textColor ~= nil and "foreground" or active and onContainer or "secondaryForeground"
    local chip = active and hue .. "/0.3" or "foreground/0.1"
    local fill = style.backgrounds and (active and container or (scratchpad.visible and "highestSurface" or nil)) or nil
    return tint, chip, hue, fill
end

local function calendarButton(text, command)
    local width = dash.calendarWidth
    return ui.row{ w = width, h = 40, radius = 20, fill = "secondaryContainer",
        hover = "secondaryContainerForeground/0.08", onClick = command,
        ui.box{ grow = 1, h = 1 },
        ui.text{ text = text, font = "sans", size = tokens.label.large, weight = "medium",
            color = "secondaryContainerForeground", maxWidth = width - 32 },
        ui.box{ grow = 1, h = 1 } }
end

local function calendarAgenda(event, first)
    local width = dash.calendarWidth
    local textWidth = width - (event.countdown and 140 or 40)
    return ui.row{ key = event.open, w = width, gap = tokens.spacing.medium, pad = tokens.padding.small,
        radius = tokens.rounding.large, hover = status.hover, onClick = event.open,
        fill = first and "secondaryContainer" or nil,
        ui.box{ w = 4, h = 30, radius = 2, fill = event.color },
        ui.column{ gap = 2, center = false, grow = 1,
            ui.text{ text = event.title, font = "sans", size = tokens.body.small, weight = "medium",
                maxWidth = textWidth },
            ui.text{ text = event.day .. " · " .. event.when, font = "sans", size = tokens.label.medium,
                color = "secondaryForeground", maxWidth = textWidth } },
        event.countdown and ui.text{ text = event.countdown, font = "sans", size = tokens.label.medium,
            weight = "semibold", color = "accent" } or nil }
end

local function batteryChip(ctx, m, mode)
    local style = ctx.data.bar.style
    local scale = style.height / 60
    local tint = m.low and "error" or "secondaryAccent"
    local glyph = mode == "inside" and require("./battery").cell(m, 30 * scale, 15 * scale, m.text)
        or surface.icon(icons.battery(m.level / 100, m.charging), { size = tokens.icon.medium * scale,
            color = tint, filled = true, animate = "effects" })
    local items = { glyph }
    if mode == nil or mode == "beside" then
        items[#items + 1] = ui.text{ text = style.vertical and m.text or m.percent, font = "sans",
            size = (style.vertical and tokens.label.small or tokens.label.large) * scale,
            weight = "medium", color = tint, reserve = not style.vertical and m.reserve or nil }
    end
    return surface.pill(style, items, { help = omniwm.l10n("Battery"), hover = mode and status.hover or nil })
end

local function iconPill(ctx, name, symbol)
    local style = ctx.data.bar.style
    local scale = style.height / 60
    local size = tokens.icon.medium * scale
    local glyph
    if symbol then
        glyph = ui.stack{
            surface.icon("", { reserve = "search", size = size, filled = true }),
            ui.symbol{ name = name, w = size, h = size, size = size, color = "secondaryAccent" },
        }
    else
        glyph = surface.icon(name, { size = size, color = "secondaryAccent", filled = true, animate = "effects" })
    end
    return surface.pill(style, {
        glyph,
    }, { hover = status.hover })
end

local function statsMeter(ctx, entry, variant)
    local style = ctx.data.bar.style
    local scale = style.height / 60
    local tint = entry.key == "cpu" and "accent" or "tertiaryAccent"
    local text = entry.available and ctx.format.percent(entry.value / 100) or "--"
    local compact = entry.available and tostring(math.round(entry.value)) or "--"
    if variant == "gauge" then
        return require("./stats").gauge(entry.value, tokens.bar.inner * scale, tint,
            ui.text{ text = compact, font = "sans", size = tokens.label.small * scale, weight = "medium",
                color = style.textColor ~= nil and "foreground" or tint })
    end
    local parts = {
        surface.icon(entry.key == "cpu" and "memory" or "memory_alt",
            { size = tokens.icon.small * scale, color = tint }),
        ui.text{ text = style.vertical and compact or text,
            font = "sans", size = (style.vertical and tokens.label.small or tokens.label.large) * scale,
            weight = "medium", color = style.textColor ~= nil and "foreground" or tint,
            reserve = not style.vertical and ctx.format.percent(1) or nil },
    }
    if variant == "graph" then
        table.insert(parts, 2, require("./stats").sparkline(entry.history, (style.vertical and 24 or 34) * scale,
            16 * scale, tint))
    end
    parts.gap = tokens.spacing.extraSmall * scale
    return line(style.vertical, parts)
end

local function panel(_, props)
    props.w = props.w or 300
    props.pad = props.pad or tokens.padding.medium
    props.gap = props.gap or tokens.spacing.small
    props.radius = props.radius or tokens.rounding.extraLarge
    props.fill = props.fill or "background"
    props.shadow = "shadow/0.35"
    props.shadowRadius = 10
    props.center = false
    return ui.column{ material = "clear", pad = tokens.padding.small, ui.column(props) }
end

return require("./skin")({
    base = 60,
    width = 300 - 2 * tokens.padding.medium,
    widths = { ["control-center"] = 320 },
    systemStatsWidth = function(ctx)
        return performance.size(ctx).w
    end,
    hover = "foreground/0.08",
    primaryButton = { w = 40, h = 40, radius = 20, fill = "accent", color = "accentForeground" },
    size = { text = tokens.body.small, icon = 24, slot = 28, symbol = tokens.icon.small },
    batteryBar = function(ctx, m)
        return batteryChip(ctx, m)
    end,
    batteryDetailsBar = function(ctx, m)
        return batteryChip(ctx, m, m.mode)
    end,
    batteryPanel = status.battery,
    wifiBar = function(ctx, m)
        return iconPill(ctx, status.wifiIcon(m))
    end,
    wifiPanel = status.network,
    bluetoothBar = function(ctx, m)
        return iconPill(ctx, status.bluetoothStateIcon(m))
    end,
    bluetoothPanel = status.bluetooth,
    statsBar = function(ctx, m)
        local style = ctx.data.bar.style
        local items = {}
        for _, entry in m.meters do
            items[#items + 1] = statsMeter(ctx, entry, m.variant)
        end
        return surface.pill(style, items, { gap = tokens.spacing.medium * style.height / 60, hover = status.hover,
            help = omniwm.l10n("Performance") })
    end,
    statsPanel = function(ctx)
        return status.pane(performance, ctx)
    end,
    inputSourceBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 60
        return surface.pill(style, {
            ui.text{ text = m.short, font = "sans", size = tokens.label.large * scale,
                weight = "medium", color = style.textColor ~= nil and "foreground" or "secondaryAccent",
                maxWidth = style.vertical and 28 * scale or nil },
        }, { hover = status.hover })
    end,
    inputSourcePanel = status.keyboard,
    launcherBar = function(ctx, m)
        return iconPill(ctx, m.symbol == "magnifyingglass" and "search" or m.symbol, m.symbol ~= "magnifyingglass")
    end,
    controlCenterBar = function(ctx)
        return iconPill(ctx, "tune")
    end,
    controlCenterPanel = function(ctx, props)
        local tabs = props[2]
        props.w = tabs.w + 2 * tokens.padding.medium
        for index = 1, #tabs do
            local glyph = tabs[index][1]
            local name = CONTROL_CENTER_SYMBOLS[glyph.name]
            if name then
                glyph.name = nil
                tabs[index][1] = surface.icon(name, glyph)
            end
        end
        return panel(ctx, props)
    end,
    privacyBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 60
        local items = {}
        for _, indicator in m.indicators do
            items[#items + 1] = m.icons
                and surface.icon(indicator.key == "microphone" and "mic" or "videocam",
                    { size = tokens.icon.small * scale, color = indicator.color, filled = true })
                or ui.box{ w = 6 * scale, h = 6 * scale, radius = 3 * scale, fill = indicator.color }
        end
        if #items == 1 then
            local size = tokens.bar.inner * scale
            return ui.stack{ w = size, h = size, radius = size / 2,
                fill = style.backgrounds and "surface" or nil, items[1] }
        end
        return surface.pill(style, items)
    end,
    worldClockBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 60
        local items = { surface.icon("public", { size = tokens.icon.medium * scale, color = "secondaryAccent" }) }
        if style.vertical then
            items[#items + 1] = ui.text{ text = string.format("%02d", m.clocks[1].hour), font = "sans",
                size = tokens.label.small * scale, weight = "medium", color = "secondaryAccent" }
        else
            for index = 1, m.shown do
                local clock = m.clocks[index]
                if index > 1 then
                    items[#items + 1] = ui.box{ w = 1, h = tokens.label.medium * scale, fill = "foreground/0.12" }
                end
                items[#items + 1] = ui.text{ text = clock.short, font = "sans", size = tokens.label.medium * scale,
                    weight = "medium", color = "secondaryForeground" }
                items[#items + 1] = ui.text{ text = clock.time, font = "sans", size = tokens.label.large * scale,
                    weight = "medium", color = "secondaryAccent", reserve = "00:00 PM" }
            end
        end
        return surface.pill(style, items, { hover = status.hover })
    end,
    activeWindowBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 60
        local props = { gap = tokens.spacing.small * scale, hover = "accent/0.08",
            radius = tokens.rounding.large * scale, pad = tokens.padding.extraSmall * scale }
        if m.display ~= "text_only" then
            props[#props + 1] = ui.icon{ app = m.bundle, w = tokens.icon.medium * scale,
                h = tokens.icon.medium * scale, placeholder = "app.dashed" }
        end
        if m.display ~= "icon_only" then
            props[#props + 1] = ui.text{ text = m.title, font = "sans", size = tokens.body.small * scale,
                color = style.textColor ~= nil and "foreground" or "accent", maxWidth = m.maxWidth,
                rotate = style.vertical and 90 or nil, animate = "effects" }
        end
        if style.vertical then
            props.w = tokens.bar.inner * scale
            return ui.column(props)
        end
        return ui.row(props)
    end,
    omniwmButton = function(ctx, glyph, locked)
        local scale = ctx.data.bar.style.height / 60
        glyph.size = tokens.body.large * 1.2 * scale
        glyph.weight = "semibold"
        local size = glyph.size + tokens.padding.small * scale
        return { w = size, h = size, radius = size / 2,
            hover = (locked and "warning" or "tertiaryAccent") .. "/0.12" }, size
    end,
    clockClick = "shell toggle dashboard",
    clockBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 60
        local size = tokens.body.small * 1.1 * scale
        local tint = "tertiaryAccent"
        local icon = m.showIcon and surface.icon("calendar_month", { size = tokens.icon.small * scale,
            color = tint }) or nil
        if style.vertical then
            local column = { w = tokens.bar.inner * scale, gap = tokens.spacing.extraSmall * scale,
                pad = tokens.padding.extraSmall * scale }
            column[#column + 1] = icon
            if m.showDate then
                column[#column + 1] = ui.text{ text = string.match(m.date, "^(%a+)") or m.date, font = "sans",
                    size = tokens.body.small * 0.9 * scale, color = tint }
            end
            column[#column + 1] = ui.column{ gap = 0,
                ui.text{ text = m.hour, font = "sans", size = size, weight = "medium", color = tint },
                ui.text{ text = m.minute, font = "sans", size = size, weight = "medium", color = tint },
                m.meridiem and ui.text{ text = m.meridiem, font = "sans", size = tokens.body.small * 0.9 * scale,
                    color = tint } or nil }
            return ui.column(column)
        end
        local row = { h = tokens.bar.inner * scale, gap = tokens.spacing.small * scale,
            pad = tokens.padding.small * scale }
        row[#row + 1] = icon
        if m.showDate then
            row[#row + 1] = ui.text{ text = m.date, font = "sans", size = size, color = tint }
        end
        row[#row + 1] = ui.text{ text = m.time, font = "sans", size = size, weight = "medium", color = tint,
            reserve = "00:00 PM" }
        return ui.row(row)
    end,
    calendarBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 60
        local items = { surface.icon("calendar_month", { size = tokens.icon.medium * scale,
            color = "secondaryAccent" }) }
        local event = m.event
        if event then
            items[#items + 1] = ui.box{ w = 6, h = 6, radius = 3, fill = event.color }
            if not style.vertical then
                items[#items + 1] = ui.text{ text = event.title, font = "sans", size = tokens.label.large * scale,
                    weight = "medium", maxWidth = 130 }
                items[#items + 1] = ui.text{ text = event.countdown, font = "sans", size = tokens.label.medium * scale,
                    weight = "semibold", color = "accent" }
            end
        end
        return surface.pill(style, items, { hover = status.hover })
    end,
    weatherBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 60
        return surface.pill(style, {
            surface.icon(icons.weather(m.code, m.isDay), { size = tokens.icon.medium * scale,
                color = "secondaryAccent" }),
            ui.text{ text = m.temp, font = "sans",
                size = (style.vertical and tokens.label.medium or tokens.label.large) * scale,
                weight = "medium", color = "accent" },
        }, { hover = status.hover, help = m.condition })
    end,
    weatherPanel = function(ctx, m)
        return status.panel(weathertab.size.w + 2 * tokens.padding.large, { weathertab.tab(ctx, m) })
    end,
    calendarPanel = function(ctx, m)
        local rows = { dash.calendar(ctx, m) }
        if m.agenda then
            for index, event in m.agenda do
                rows[#rows + 1] = calendarAgenda(event, index == 1)
            end
            if #m.agenda == 0 then
                rows[#rows + 1] = ui.text{ text = omniwm.l10n("No upcoming events"), font = "sans",
                    size = tokens.body.small, color = "secondaryForeground" }
            end
        elseif m.action and m.month then
            rows[#rows + 1] = calendarButton(m.action.text, m.action.command)
        end
        if m.month then
            rows[#rows + 1] = calendarButton(omniwm.l10n("Open Calendar"), m.open)
        end
        return status.panel(dash.calendarWidth + 2 * tokens.padding.large, rows)
    end,
    volumeBar = function(ctx, m)
        if not m.volume then
            return ui.box{ w = 0, h = 0 }
        end
        local style = ctx.data.bar.style
        local scale = style.height / 60
        local tint = m.muted and "mutedForeground" or "secondaryAccent"
        return surface.pill(style, {
            surface.icon(icons.volume(m.level, m.muted), { size = tokens.icon.medium * scale, color = tint,
                filled = true, animate = "effects" }),
            ui.text{ text = style.vertical and tostring(m.volume) or m.percent, font = "sans",
                size = (style.vertical and tokens.label.small or tokens.label.large) * scale, weight = "medium",
                color = tint, reserve = not style.vertical and ctx.format.percent(1) or nil },
        }, { hover = status.hover })
    end,
    audioPanel = status.audio,
    mediaBar = function(ctx, m)
        local style = ctx.data.bar.style
        local scale = style.height / 60
        local items = { surface.icon(if m.playing then "music_note" else "pause", { color = "secondaryAccent",
            size = tokens.icon.medium * scale, filled = true, animate = "effects" }) }
        if not style.vertical then
            items[2] = ui.text{ text = m.title, font = "sans", size = tokens.label.large * scale, weight = "medium",
                maxWidth = 160 }
        end
        return surface.pill(style, items, { hover = status.hover })
    end,
    mediaPanel = function(ctx, m)
        return status.panel(mediatab.size.w + 2 * tokens.padding.large, { mediatab.tab(ctx, m) })
    end,
    text = function(props)
        props.font = props.font or "sans"
        if props.color == nil and props.role == "secondary" then
            props.color = "secondaryForeground"
        end
        props.role = nil
        return ui.text(props)
    end,
    glyph = function(props)
        local name = SYMBOLS[props.name]
        if not name then
            return ui.symbol(props)
        end
        props.name = nil
        return surface.icon(name, props)
    end,
    hiddenMenuPanel = function(_, rows)
        rows.radius, rows.material, rows.fill = tokens.rounding.extraLarge, "clear", "background"
        rows.shadow, rows.shadowRadius, rows.center = "shadow/0.35", 10, false
        return ui.column(rows)
    end,
    systemStatsButton = function(ctx, glyph)
        local style = ctx.data.bar.style
        local scale = style.height / 60
        glyph.size = 24 * scale
        glyph.color = style.textColor ~= nil and "foreground" or "secondaryAccent"
        return { w = style.vertical and tokens.bar.inner * scale or nil,
            h = not style.vertical and tokens.bar.inner * scale or nil, pad = tokens.padding.medium * scale,
            radius = tokens.bar.inner / 2 * scale,
            fill = style.backgrounds and "surface" or nil, hover = "foreground/0.08" }
    end,
    systemStatsSection = function(ctx, kind, m, width)
        if kind == "metrics" then
            return performance.tab(ctx)
        elseif kind ~= "details" then
            return false
        end
        if not m.host then
            return ui.text{ text = omniwm.l10n("Loading…"), font = "sans", size = tokens.body.small }
        end
        local host = m.host
        local inner = width - tokens.padding.medium * 2
        return ui.column{ w = width, pad = tokens.padding.medium, gap = tokens.spacing.small,
            radius = tokens.rounding.large, fill = "surface", center = false,
            ui.row{ w = inner, gap = tokens.spacing.large,
                ui.text{ text = host.name, font = "sans", size = tokens.title.medium, weight = "medium", maxWidth = inner / 2 },
                ui.box{ grow = 1, h = 1 },
                ui.text{ text = host.uptime, font = "sans", size = tokens.body.small, color = "secondaryForeground" } },
            ui.text{ text = m.memory.title .. " · " .. m.memory.detail, font = "sans", size = tokens.body.small,
                maxWidth = inner, lines = 2 },
            ui.text{ text = m.disk.title .. " · " .. m.disk.detail, font = "sans", size = tokens.body.small,
                maxWidth = inner, lines = 2 },
            ui.text{ text = host.model .. " · " .. host.os, font = "sans", size = tokens.label.medium,
                color = "secondaryForeground", maxWidth = inner },
            ui.text{ text = table.concat(m.displays, "  ·  "), font = "sans", size = tokens.label.medium,
                color = "secondaryForeground", maxWidth = inner, lines = 2 } }
    end,
    panel = panel,
    workspaceMetrics = function(_, style, m)
        local scale = style.height / 60
        return { scale = scale, inner = tokens.bar.inner * scale, pad = tokens.padding.extraSmall * scale,
            cell = 32 * scale, item = 32 * scale, icon = 24 * scale, slot = 28 * scale,
            gap = tokens.spacing.extraSmall * scale, markerAlways = m.indicator == "pills", focusCue = m.indicator == "pills" }
    end,
    workspaceMarker = function(ctx, workspace, style, m, occupied)
        if m.indicator ~= "pills" then
            return nil
        end
        local focused = workspace.focused
        local color = style.textColor ~= nil and "foreground" or (focused and style.accents) and "accentForeground"
            or (focused or occupied) and "foreground" or "border"
        if style.labels then
            return ui.stack{ w = m.cell, h = m.cell,
                ui.text{ text = workspace.name, font = "rubik", size = tokens.body.small * m.scale,
                    weight = focused and "bold" or "medium", color = color, maxWidth = m.cell - 4, animate = "effects" } }
        end
        local name = focused and focusedShape(ctx, workspace) or occupied and "Square" or "Circle"
        return ui.stack{ w = m.cell, h = m.cell,
            ui.path{ d = shapes.path(name), viewBox = shapes.viewBox, w = m.cell, h = m.cell, fill = color,
                scale = focused and 2 / 3 or occupied and 1 / 3 or 1 / 4, animate = "spatial" } }
    end,
    workspacePill = function(pill, _, _, m)
        if m.indicator ~= "pills" then
            return
        end
        pill.radius = m.cell / 2
        pill.fill = nil
        pill.gap = 0
        pill.animate = "spatial"
    end,
    windowIcon = function(icon, _, _, _, m)
        icon.radius = m.slot / 2
        icon.animate = "effects"
        icon.hoverScale = 1.12
        icon.hover = "foreground/0.08"
    end,
    countBadge = function(text, m)
        local size = math.max(11, m.icon * 0.62)
        return ui.row{ align = "topTrailing", dx = 3, dy = -3, h = size, radius = size / 2, fill = "tertiaryAccent",
            ui.box{ w = 3, h = 1 },
            ui.text{ text = text, font = "sans", size = 9, weight = "bold", color = "background" },
            ui.box{ w = 3, h = 1 } }
    end,
    notificationBadge = function(item, mode, m)
        if mode == "dot" then
            local size = math.max(6, m.icon * 0.36)
            return ui.box{ align = "topLeading", dx = -2, dy = -2, w = size, h = size, radius = size / 2, fill = "badge",
                border = "surface", borderWidth = 1 }
        end
        local height = math.max(10, m.icon * 0.6)
        return ui.row{ align = "topLeading", dx = -3, dy = -3, h = height, radius = height / 2, fill = "badge",
            border = "surface", borderWidth = 1,
            ui.box{ w = 3, h = 1 },
            ui.text{ text = item.badge, font = "sans", size = math.max(8, m.icon * 0.42), weight = "bold", color = "#FFFFFFFF",
                maxWidth = m.slot },
            ui.box{ w = 3, h = 1 } }
    end,
    hiddenIndicator = function(item, m)
        local full = item.count > 0 and item.hidden == item.count
        local size = math.max(10, m.icon * 0.55)
        return ui.stack{ align = "bottomTrailing", dx = 3, dy = 3, w = size, h = size, radius = size / 2,
            fill = full and "error" or "highestSurface", border = "surface", borderWidth = 1,
            surface.icon("visibility_off", { size = size * 0.7, color = full and "background" or "error", filled = true }) }
    end,
    floatingGroup = function(icons, style, m)
        local group = { radius = m.cell / 2,
            w = m.vertical and m.cell or nil, h = if m.vertical then nil else m.cell,
            fill = style.backgrounds and "highestSurface" or nil,
            ui.stack{ w = m.vertical and m.cell or 16 * m.scale, h = m.vertical and 16 * m.scale or m.cell,
                surface.icon("filter_none", { size = 12 * m.scale,
                    color = style.textColor ~= nil and "foreground" or "secondaryForeground" }) } }
        for _, icon in icons do
            group[#group + 1] = icon
        end
        group[#group + 1] = ui.box{ w = m.vertical and 1 or m.pad, h = m.vertical and m.pad or 1 }
        return line(m.vertical, group), 16 * m.scale + #icons * m.slot + m.pad
    end,
    workspaceGroup = function(ctx, pills, cells, style, m)
        if m.indicator ~= "pills" then
            return nil
        end
        pills.gap = m.gap
        local layers, runs = {}, {}
        local offset, run, active, focusedId = 0, nil, nil, nil
        for _, cell in cells do
            if cell.length == nil then
                return nil
            end
            if cell.workspace.focused then
                active = { start = offset, length = cell.length }
                focusedId = cell.workspace.id
            end
            if cell.occupied then
                if run then
                    run.length = offset + cell.length - run.start
                else
                    run = { start = offset, length = cell.length }
                    runs[#runs + 1] = run
                end
            else
                run = nil
            end
            offset += cell.length + m.gap
        end
        ctx.state.focused = focusedId
        if #cells == 0 then
            return line(m.vertical, pills)
        end
        if style.backgrounds and (ctx.data.settings or {}).occupiedBackground == true then
            for index, entry in runs do
                layers[#layers + 1] = backdrop(m, entry.start, entry.length,
                    { key = "occupied" .. index, fill = "highestSurface", animate = "effects" })
            end
        end
        if active and (style.accents or style.backgrounds) then
            layers[#layers + 1] = backdrop(m, active.start, active.length,
                { key = "indicator", fill = style.accents and "accent" or "foreground/0.1", animate = "spatial", trail = true })
        end
        layers[#layers + 1] = line(m.vertical, pills)
        layers.pad = m.pad
        layers.radius = m.inner / 2
        layers.fill = style.backgrounds and "surface" or nil
        layers.w = m.vertical and m.inner or nil
        layers.h = if m.vertical then nil else m.inner
        return ui.stack(layers)
    end,
    scratchpadMetrics = function(_, style)
        local scale = style.height / 60
        return { item = (tokens.bar.inner - tokens.padding.small) * scale, icon = 24 * scale, slot = 24 * scale,
            gap = 1, compactGap = 1, edge = 7, compactEdge = 3, spacing = tokens.spacing.extraSmall * scale }
    end,
    scratchpadLabel = function(scratchpad, style, m, text, width)
        local tint = scratchpadColors(scratchpad, style)
        return ui.stack{ w = width or (m.vertical and m.item - 6 or nil), h = m.item - 6,
            ui.text{ text = text, font = "sans",
                size = if width then math.min(tokens.label.medium * m.scale, width / 2) else tokens.label.medium * m.scale,
                weight = "medium", color = tint,
                maxWidth = width } }
    end,
    scratchpadCount = function(text, scratchpad, style, m)
        local tint, chip = scratchpadColors(scratchpad, style)
        local height = m.item - 8
        return ui.row{ h = height, radius = height / 2, fill = chip,
            ui.box{ w = 4, h = 1 },
            ui.text{ text = text, font = "sans", size = 10, weight = "bold", color = tint },
            ui.box{ w = 4, h = 1 } }
    end,
    scratchpadIcon = function(_, glyph, member, _, style)
        glyph.opacity = member.focused and 1 or (style.inactive >= 0 and style.inactive or 0.85)
    end,
    scratchpadPill = function(node, scratchpad, style, m)
        local _, _, hue, fill = scratchpadColors(scratchpad, style)
        local short = scratchpad.compact or m.vertical
        node.radius = m.item / 2
        node.animate = "effects"
        node.fill = fill
        node.hover = hue .. "/0.12"
        node[1].w = m.vertical and 1 or (short and 3 or 7)
        node[1].h = m.vertical and (short and 3 or 7) or 1
        local trailing = node[#node]
        trailing.w = m.vertical and 1 or (scratchpad.compact and 2 or 3)
        trailing.h = m.vertical and (scratchpad.compact and 2 or 3) or 1
        table.insert(node, 3, ui.box{ w = m.vertical and 1 or (short and 2 or 4),
            h = m.vertical and (short and 2 or 4) or 1 })
    end,
    scratchpadGroup = function(_, items, style, m)
        if #items == 0 then
            return ui.row{}
        end
        local capsule = tokens.bar.inner * m.scale
        items.radius = capsule / 2
        items.pad = tokens.padding.extraSmall * m.scale
        items.w = m.vertical and capsule or nil
        items.h = if m.vertical then nil else capsule
        items.fill = style.backgrounds and "surface" or nil
        return line(m.vertical, items)
    end,
    pickerHeader = function(header, item)
        header[1].size = tokens.title.small
        header[1].weight = "medium"
        header[1].maxWidth = 180
        table.insert(header, 1, ui.stack{ w = 36, h = 36, radius = 18, fill = "accentContainer",
            ui.icon{ app = item.bundle, placeholder = "app.dashed", w = 22, h = 22 } })
    end,
    pickerRow = function(row, window)
        row.pad = tokens.padding.small
        row.gap = tokens.spacing.small
        row.radius = tokens.rounding.large
        row.fill = window.focused and "secondaryContainer" or nil
        row[1].font = "sans"
        row[1].maxWidth = math.max(0, row[1].maxWidth - tokens.icon.small - 2 * tokens.spacing.small)
        table.insert(row, 1, surface.icon(window.hidden and "visibility_off" or "web_asset",
            { size = tokens.icon.small, color = window.focused and "secondaryContainerForeground" or "secondaryForeground" }))
    end,
})
