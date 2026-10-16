-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

spanIslands = true

local shapes = require("../lib/shapes")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

local WHITE = "#FFFFFFFF"
local PANEL = 300
local FOCUSED_SHAPES = {
    "Slanted", "Oval", "Pill", "Triangle", "Arrow", "Diamond", "Pentagon", "Gem", "VerySunny", "Sunny", "Cookie4Sided",
    "Cookie6Sided", "Cookie7Sided", "Cookie9Sided", "Cookie12Sided", "Clover4Leaf", "SoftBurst", "Ghostish",
}

type Metrics = {
    inner: number, pad: number, cell: number, icon: number, slot: number, gap: number, vertical: boolean, scale: number,
}

local function metrics(style: BarStyle): Metrics
    local scale = style.height / 60
    return { inner = tokens.bar.inner * scale, pad = tokens.padding.extraSmall * scale,
        cell = 32 * scale, icon = 24 * scale, slot = 28 * scale, gap = tokens.spacing.extraSmall * scale,
        vertical = style.vertical, scale = scale }
end

local function line(vertical: boolean, props)
    return vertical and ui.column(props) or ui.row(props)
end

local function contains(list: { string }?, value: string): boolean
    for _, entry in list or {} do
        if entry == value then
            return true
        end
    end
    return false
end

local function appHidden(item: BarItem): boolean
    return item.count > 0 and item.hidden == item.count
end

local function countBadge(text: string, m: Metrics)
    local size = math.max(11, m.icon * 0.62)
    return ui.row{ align = "topTrailing", dx = 3, dy = -3, h = size, radius = size / 2, fill = "tertiaryAccent",
        ui.box{ w = 3, h = 1 },
        ui.text{ text = text, font = "sans", size = 9, weight = "bold", color = "background" },
        ui.box{ w = 3, h = 1 } }
end

local function notificationBadge(item: BarItem, mode: string, m: Metrics)
    if mode == "off" or item.badge == "" then
        return nil
    end
    if mode == "dot" then
        local size = math.max(6, m.icon * 0.36)
        return ui.box{ align = "topLeading", dx = -2, dy = -2, w = size, h = size, radius = size / 2, fill = "badge",
            border = "surface", borderWidth = 1 }
    end
    local height = math.max(10, m.icon * 0.6)
    return ui.row{ align = "topLeading", dx = -3, dy = -3, h = height, radius = height / 2, fill = "badge",
        border = "surface", borderWidth = 1,
        ui.box{ w = 3, h = 1 },
        ui.text{ text = item.badge, font = "sans", size = math.max(8, m.icon * 0.42), weight = "bold", color = WHITE,
            maxWidth = m.slot },
        ui.box{ w = 3, h = 1 } }
end

local function hiddenIndicator(item: BarItem, m: Metrics)
    if item.hidden == 0 then
        return nil
    end
    local full = appHidden(item)
    local size = math.max(10, m.icon * 0.55)
    return ui.stack{ align = "bottomTrailing", dx = 3, dy = 3, w = size, h = size, radius = size / 2,
        fill = full and "error" or "highestSurface", border = "surface", borderWidth = 1,
        surface.icon("visibility_off", { size = size * 0.7, color = full and "background" or "error", filled = true }) }
end

local function windowHelp(item: BarItem, bar: Bar): string
    local text
    if item.count > 1 then
        text = item.floating and omniwm.l10n("%@, %lld floating windows", item.name, item.count)
            or omniwm.l10n("%@, %lld windows", item.name, item.count)
    else
        text = item.floating and omniwm.l10n("%@ floating window", item.name) or omniwm.l10n("%@ window", item.name)
    end
    if bar.badges ~= "off" and item.badge ~= "" then
        text ..= ", " .. omniwm.l10n("%@ notification badge: %@", item.name, item.badge)
    end
    return text
end

local function iconOpacity(item: BarItem, style: BarStyle): number
    if appHidden(item) then
        return 0.9
    end
    if item.focused then
        return 1
    end
    return style.inactive >= 0 and style.inactive or 0.7
end

local function windowIcon(item: BarItem, bar: Bar, m: Metrics, shift: number)
    local drag = bar.drag
    local icon = { key = item.id, w = m.slot, h = m.slot, radius = m.slot / 2, animate = "effects", hoverAnimate = 0.1,
        scale = item.focused and 1.08 or 1, hoverScale = 1.12, hover = "foreground/0.08",
        dx = m.vertical and 0 or shift, dy = m.vertical and shift or 0,
        border = (drag ~= nil and contains(drag.icons, item.id)) and "accent" or nil, borderWidth = 1.5,
        target = "window " .. item.id, menu = true, preview = true, drag = true, help = windowHelp(item, bar),
        ui.icon{ window = item.id, placeholder = "app.dashed", w = m.icon, h = m.icon,
            opacity = (drag ~= nil and contains(drag.sources, item.id)) and 0.35 or iconOpacity(item, bar.style),
            color = appHidden(item) and "error/0.32" or nil } }
    if item.count > 1 then
        icon.onClick = function(ctx) ctx.state.picker = item.id end
        icon.popout = true
        icon[#icon + 1] = countBadge(tostring(item.count), m)
    else
        icon.onClick = "window focus " .. item.id
    end
    icon[#icon + 1] = notificationBadge(item, bar.badges, m)
    icon[#icon + 1] = hiddenIndicator(item, m)
    return ui.stack(icon)
end

local function gapBefore(drag: BarDrag?, workspace: string): number?
    for _, gap in drag and drag.gaps or {} do
        if gap.workspace == workspace then
            return gap.before
        end
    end
    return nil
end

local function focusedShape(ctx: Context, workspace: BarWorkspace): string
    local state = ctx.state
    state.shapes = state.shapes or {}
    if workspace.focused and state.focused ~= workspace.id then
        state.shapes[workspace.id] = FOCUSED_SHAPES[math.random(#FOCUSED_SHAPES)]
    end
    return state.shapes[workspace.id] or FOCUSED_SHAPES[1]
end

local function indicator(ctx: Context, workspace: BarWorkspace, style: BarStyle, occupied: boolean, m: Metrics)
    local focused = workspace.focused
    local color = style.textColor ~= nil and "foreground" or (focused and style.accents) and "accentForeground"
        or (focused or occupied) and "foreground" or "border"
    local help = omniwm.l10n("Focus workspace %@", workspace.name)
    if style.labels then
        return ui.stack{ w = m.cell, h = m.cell, help = help,
            ui.text{ text = workspace.name, font = "rubik", size = tokens.body.small * m.scale, weight = focused and "bold" or "medium",
                color = color, maxWidth = m.cell - 4, animate = "effects" } }
    end
    local name = focused and focusedShape(ctx, workspace) or occupied and "Square" or "Circle"
    return ui.stack{ w = m.cell, h = m.cell, help = help,
        ui.path{ d = shapes.path(name), viewBox = shapes.viewBox, w = m.cell, h = m.cell, fill = color,
            scale = focused and 2 / 3 or occupied and 1 / 3 or 1 / 4, animate = "spatial" } }
end

local function floatingGroup(icons, style: BarStyle, m: Metrics)
    local group = { radius = m.cell / 2,
        w = m.vertical and m.cell or nil, h = if m.vertical then nil else m.cell,
        fill = style.backgrounds and "highestSurface" or nil,
        ui.stack{ w = m.vertical and m.cell or 16 * m.scale, h = m.vertical and 16 * m.scale or m.cell,
            ui.symbol{ name = "rectangle.on.rectangle", size = 12 * m.scale,
                color = style.textColor ~= nil and "foreground" or "secondaryForeground" } } }
    for _, icon in icons do
        group[#group + 1] = icon
    end
    group[#group + 1] = ui.box{ w = m.vertical and 1 or m.pad, h = m.vertical and m.pad or 1 }
    return line(m.vertical, group), 16 * m.scale + #icons * m.slot + m.pad
end

local function workspaceCell(ctx: Context, workspace: BarWorkspace, bar: Bar, m: Metrics)
    local style = bar.style
    local gap = gapBefore(bar.drag, workspace.id)
    local half = m.slot * 0.2
    local tiled, floating = {}, {}
    for _, item in workspace.windows do
        if item.floating then
            floating[#floating + 1] = windowIcon(item, bar, m, 0)
        else
            local index = #tiled + 1
            tiled[index] = windowIcon(item, bar, m, gap and (index < gap and -half or half) or 0)
        end
    end
    local occupied = #tiled + #floating > 0
    local cell = { key = workspace.id, w = m.vertical and m.cell or nil, h = if m.vertical then nil else m.cell,
        animate = "spatial", onClick = "switch-workspace " .. workspace.id, target = "workspace " .. workspace.id,
        menu = true, drop = true,
        border = (bar.drag ~= nil and contains(bar.drag.workspaces, workspace.id)) and "accent" or nil,
        borderWidth = 1.5, radius = m.cell / 2,
        indicator(ctx, workspace, style, occupied, m) }
    local length = m.cell + #tiled * m.slot
    for _, icon in tiled do
        cell[#cell + 1] = icon
    end
    if #floating > 0 then
        local group, span = floatingGroup(floating, style, m)
        cell[#cell + 1] = group
        length += span
    end
    if occupied then
        cell[#cell + 1] = ui.box{ w = m.pad, h = m.pad }
    end
    return line(m.vertical, cell), occupied, length + (occupied and m.pad or 0)
end

local function backdrop(m: Metrics, offset: number, length: number, props)
    props.align = m.vertical and "top" or "leading"
    props.w = m.vertical and m.cell or length
    props.h = m.vertical and length or m.cell
    props.dx = m.vertical and 0 or offset
    props.dy = m.vertical and offset or 0
    props.radius = m.cell / 2
    return ui.box(props)
end

function render(ctx: Context)
    local bar = ctx.data.bar
    local m = metrics(bar.style)
    local cells = { gap = m.gap }
    local layers = {}
    local offset = 0
    local run: { start: number, length: number }? = nil
    local runs = {}
    local active: { start: number, length: number }? = nil
    local focusedId = nil
    for _, workspace in bar.workspaces do
        if bar.island == "all" or workspace.focused == (bar.island == "active") then
            local cell, occupied, length = workspaceCell(ctx, workspace, bar, m)
            cells[#cells + 1] = cell
            if workspace.focused then
                active = { start = offset, length = length }
                focusedId = workspace.id
            end
            if occupied then
                if run then
                    run.length = offset + length - run.start
                else
                    run = { start = offset, length = length }
                    runs[#runs + 1] = run
                end
            else
                run = nil
            end
            offset += length + m.gap
        end
    end
    ctx.state.focused = focusedId
    if #cells == 0 then
        return line(m.vertical, {})
    end
    if bar.style.backgrounds and (ctx.data.settings or {}).occupiedBackground == true then
        for index, entry in runs do
            layers[#layers + 1] = backdrop(m, entry.start, entry.length,
                { key = "occupied" .. index, fill = "highestSurface", animate = "effects" })
        end
    end
    if active and (bar.style.accents or bar.style.backgrounds) then
        layers[#layers + 1] = backdrop(m, active.start, active.length,
            { key = "indicator", fill = bar.style.accents and "accent" or "foreground/0.1", animate = "spatial", trail = true })
    end
    layers[#layers + 1] = line(m.vertical, cells)
    layers.pad = m.pad
    layers.radius = m.inner / 2
    layers.fill = bar.style.backgrounds and "surface" or nil
    layers.w = m.vertical and m.inner or nil
    layers.h = if m.vertical then nil else m.inner
    return ui.stack(layers)
end

local function findItem(bar: Bar, id: string): BarItem?
    for _, workspace in bar.workspaces do
        for _, item in workspace.windows do
            if item.id == id then
                return item
            end
        end
    end
    return nil
end

function popout(ctx: Context)
    local item = findItem(ctx.data.bar, ctx.state.picker)
    if not item or item.count < 2 then
        return ui.column{}
    end
    local inner = PANEL - 2 * tokens.padding.medium
    local rows = { scroll = true, gap = tokens.spacing.extraSmall, center = false }
    for _, window in item.windows do
        local title = window.title ~= "" and window.title or item.name
        local row = { key = window.id, w = inner, pad = tokens.padding.small, gap = tokens.spacing.small,
            radius = tokens.rounding.large, fill = window.focused and "secondaryContainer" or nil,
            hover = "foreground/0.08", onClick = "window focus " .. window.id,
            help = window.hidden and omniwm.l10n("Unhide and focus %@", title) or omniwm.l10n("Focus %@", title),
            surface.icon(window.hidden and "visibility_off" or "web_asset", { size = tokens.icon.small,
                color = window.focused and "secondaryContainerForeground" or "secondaryForeground" }),
            ui.text{ text = title, font = "sans", size = tokens.body.small,
                color = ctx.data.bar.style.textColor ~= nil and "foreground"
                    or window.focused and "secondaryContainerForeground" or "foreground",
                weight = window.focused and "medium" or nil, maxWidth = inner - 60, lines = 2 },
            ui.box{ grow = 1, h = 1 } }
        rows[#rows + 1] = ui.row(row)
    end
    return ui.column{ material = "clear", pad = tokens.padding.small,
        ui.column{ w = PANEL, pad = tokens.padding.medium, gap = tokens.spacing.small, radius = tokens.rounding.extraLarge,
            fill = "background", shadow = "shadow/0.35", shadowRadius = 10, center = false,
            ui.row{ w = inner, gap = tokens.spacing.small,
                ui.stack{ w = 36, h = 36, radius = 18, fill = "accentContainer",
                    ui.icon{ app = item.bundle, placeholder = "app.dashed", w = 22, h = 22 } },
                ui.text{ text = item.name, font = "sans", size = tokens.title.small, weight = "medium", maxWidth = 180 },
                ui.box{ grow = 1, h = 1 },
                surface.button("close", "text", { onClick = ui.popout, help = omniwm.l10n("Close"),
                    glyph = tokens.icon.small }) },
            ui.column(rows) } }
end
