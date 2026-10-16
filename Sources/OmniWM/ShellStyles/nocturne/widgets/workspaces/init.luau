-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local panel = require("../lib/panel")

spanIslands = true

local HOVER = "focus/0.14"
local WIDTH = 300

type Metrics = { capsule: number, chip: number, icon: number, slot: number, vertical: boolean, scale: number }

local function metrics(style: BarStyle): Metrics
    local scale = style.height / 40
    local capsule = 32 * scale
    local icon = 24 * scale
    return { capsule = capsule, chip = 24 * scale, icon = icon, slot = icon + 3 * scale,
        vertical = style.vertical, scale = scale }
end

local function line(vertical: boolean, props)
    return vertical and ui.column(props) or ui.row(props)
end

local function spacer(vertical: boolean, length: number)
    return vertical and ui.box{ w = 1, h = length } or ui.box{ w = length, h = 1 }
end

local function contains(list: { string }?, value: string): boolean
    for _, entry in ipairs(list or {}) do
        if entry == value then
            return true
        end
    end
    return false
end

local function appHidden(item: BarItem): boolean
    return item.count > 0 and item.hidden == item.count
end

local function iconOpacity(item: BarItem, style: BarStyle, workspaceFocused: boolean): number
    if appHidden(item) then
        return 0.9
    end
    if item.focused then
        return 1
    end
    if style.inactive >= 0 then
        return style.inactive
    end
    return workspaceFocused and 0.55 or 0.45
end

local function pill(text: string, size: number, fill: string, color: string, align: Align, dx: number, dy: number)
    return ui.row{ align = align, dx = dx, dy = dy, h = size, radius = size / 2, fill = fill,
        border = "surface", borderWidth = 1,
        ui.box{ w = 2.5, h = 1 },
        ui.text{ text = text, style = "mono", size = size - 3, weight = "bold", color = color },
        ui.box{ w = 2.5, h = 1 } }
end

local function notificationBadge(item: BarItem, mode: string, m: Metrics)
    if mode == "off" or item.badge == "" then
        return nil
    end
    if mode == "dot" then
        return ui.box{ align = "topTrailing", dx = 1, dy = -1, w = 7, h = 7, radius = 3.5, fill = "badge",
            border = "surface", borderWidth = 1 }
    end
    return pill(item.badge, math.max(11, m.icon * 0.55), "badge", "background", "topTrailing", 3, -2)
end

local function hiddenIndicator(item: BarItem, m: Metrics)
    if item.hidden == 0 then
        return nil
    end
    local full = appHidden(item)
    local size = math.max(10, m.icon * 0.52)
    return ui.stack{ align = "bottomLeading", dx = -1, dy = 1, w = size, h = size, radius = size / 2,
        fill = full and "badge" or "elevatedSurface", border = "surface", borderWidth = 1,
        ui.symbol{ name = full and "eye.slash.fill" or "eye.slash", size = size * 0.55, weight = "bold",
            color = full and "background" or "badge" } }
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

local function windowIcon(item: BarItem, workspace: BarWorkspace, bar: Bar, m: Metrics, shift: number)
    local style = bar.style
    local drag = bar.drag
    local icon = { key = item.id, w = m.slot, h = m.slot, radius = 6, animate = 0.15, hoverAnimate = 0.1,
        hoverScale = 1.08, dx = m.vertical and 0 or shift, dy = m.vertical and shift or 0,
        border = (drag ~= nil and contains(drag.icons, item.id)) and "accent" or nil, borderWidth = 1.5,
        target = "window " .. item.id, menu = true, preview = true, drag = true, help = windowHelp(item, bar),
        ui.icon{ window = item.id, placeholder = "app.dashed", w = m.icon, h = m.icon,
            opacity = (drag ~= nil and contains(drag.sources, item.id)) and 0.35 or iconOpacity(item, style, workspace.focused),
            color = appHidden(item) and "error/0.32" or nil } }
    if item.focused then
        icon[#icon + 1] = ui.box{ align = m.vertical and "trailing" or "bottom", dx = m.vertical and 3 or 0,
            dy = m.vertical and 0 or 1.5, w = m.vertical and 2 or 8, h = m.vertical and 8 or 2, radius = 1,
            fill = style.accents and "accent" or "foreground" }
    end
    if item.count > 1 then
        icon.onClick = function(ctx) ctx.state.picker = item.id end
        icon.popout = true
        icon[#icon + 1] = pill(tostring(item.count), math.max(11, m.icon * 0.55), "elevatedSurface", "foreground",
            "bottomTrailing", 3, 1)
    else
        icon.onClick = "window focus " .. item.id
    end
    icon[#icon + 1] = notificationBadge(item, bar.badges, m)
    icon[#icon + 1] = hiddenIndicator(item, m)
    return ui.stack(icon)
end

local function divider(m: Metrics)
    return m.vertical and ui.box{ w = m.chip - 4, h = 1, fill = "mutedForeground/0.35" }
        or ui.box{ w = 1, h = m.chip - 4, fill = "mutedForeground/0.35" }
end

local function floatingGroup(icons, style: BarStyle, m: Metrics)
    local group = { gap = 2, radius = m.slot / 2,
        w = if m.vertical then m.slot else nil, h = if m.vertical then nil else m.slot,
        fill = style.backgrounds and "elevatedSurface" or nil,
        spacer(m.vertical, 3),
        ui.symbol{ name = "rectangle.on.rectangle", size = math.max(9, m.icon * 0.5), weight = "semibold",
            color = style.textColor ~= nil and "foreground" or "mutedForeground" } }
    for _, icon in ipairs(icons) do
        group[#group + 1] = icon
    end
    group[#group + 1] = spacer(m.vertical, 1)
    return line(m.vertical, group)
end

local function gapBefore(drag: BarDrag?, workspace: string): number?
    for _, gap in ipairs(drag and drag.gaps or {}) do
        if gap.workspace == workspace then
            return gap.before
        end
    end
    return nil
end

local function chip(workspace: BarWorkspace, style: BarStyle, m: Metrics)
    local focused = workspace.focused
    local fill, color
    if focused then
        fill = style.accents and "accent" or "foreground"
        color = style.accents and "accentForeground" or "background"
    else
        fill, color = "elevatedSurface", "secondaryForeground"
    end
    if not style.backgrounds and not (focused and style.accents) then
        fill = nil
        color = focused and "foreground" or color
    end
    local label = ui.text{ text = workspace.name, size = 14 * m.scale, weight = "bold",
        color = style.textColor ~= nil and "foreground" or color,
        maxWidth = m.vertical and m.chip - 4 or 96, help = omniwm.l10n("Focus workspace %@", workspace.name),
        target = "workspace " .. workspace.id }
    if utf8.len(workspace.name) <= 2 then
        local length = focused and m.capsule or m.chip
        return ui.stack{ w = m.vertical and m.chip or length, h = m.vertical and length or m.chip, radius = m.chip / 2,
            fill = fill, label }
    end
    return line(m.vertical, { radius = m.chip / 2, fill = fill,
        w = m.vertical and m.chip or nil, h = m.vertical and nil or m.chip,
        spacer(m.vertical, 7), label, spacer(m.vertical, 7) })
end

local function workspaceCapsule(workspace: BarWorkspace, bar: Bar, m: Metrics)
    local style = bar.style
    local dropTarget = bar.drag ~= nil and contains(bar.drag.workspaces, workspace.id)
    local gap = gapBefore(bar.drag, workspace.id)
    local half = math.min(8, m.icon * 0.4) / 2
    local node = { key = workspace.id, gap = 3, radius = m.capsule / 2 - 1,
        w = if m.vertical then m.capsule else nil, h = if m.vertical then nil else m.capsule,
        fill = style.backgrounds and "surface" or nil, hover = HOVER,
        border = dropTarget and "accent" or (style.backgrounds and "border/0.6" or nil),
        borderWidth = dropTarget and 1.5 or 1,
        onClick = "switch-workspace " .. workspace.id,
        target = "workspace " .. workspace.id, menu = true, drop = true,
        spacer(m.vertical, 1) }
    local tiled, floating = {}, {}
    for _, item in ipairs(workspace.windows) do
        if item.floating then
            floating[#floating + 1] = windowIcon(item, workspace, bar, m, 0)
        else
            local index = #tiled + 1
            tiled[index] = windowIcon(item, workspace, bar, m, gap and (index < gap and -half or half) or 0)
        end
    end
    local hasWindows = #tiled + #floating > 0
    if style.labels or not hasWindows then
        node[#node + 1] = chip(workspace, style, m)
    end
    for _, icon in ipairs(tiled) do
        node[#node + 1] = icon
    end
    if #floating > 0 then
        if #tiled > 0 then
            node[#node + 1] = divider(m)
        end
        node[#node + 1] = floatingGroup(floating, style, m)
    end
    node[#node + 1] = spacer(m.vertical, 1)
    return line(m.vertical, node)
end

local function findItem(bar: Bar, id: string): BarItem?
    for _, workspace in ipairs(bar.workspaces) do
        for _, item in ipairs(workspace.windows) do
            if item.id == id then
                return item
            end
        end
    end
    return nil
end

function render(ctx: Context)
    local bar = ctx.data.bar
    local m = metrics(bar.style)
    local capsules = { gap = 6 }
    for _, workspace in ipairs(bar.workspaces) do
        if bar.island == "all" or workspace.focused == (bar.island == "active") then
            capsules[#capsules + 1] = workspaceCapsule(workspace, bar, m)
        end
    end
    return line(m.vertical, capsules)
end

local function hiddenBadge()
    return ui.row{ gap = 4, h = 20, radius = 10, fill = "error/0.16", border = "error/0.55", borderWidth = 1,
        ui.box{ w = 3, h = 1 },
        ui.symbol{ name = "eye.slash.fill", size = 10, weight = "semibold", color = "error" },
        ui.text{ text = omniwm.l10n("App hidden"), size = 11, weight = "semibold", color = "error" },
        ui.box{ w = 4, h = 1 } }
end

function popout(ctx: Context)
    local item = findItem(ctx.data.bar, ctx.state.picker)
    if not item or item.count < 2 then
        return ui.column{}
    end
    local inner = WIDTH - 2 - 24
    local custom = ctx.data.bar.style.textColor ~= nil
    local rows = { gap = 2, scroll = true, center = false }
    for _, window in ipairs(item.windows) do
        local title = window.title ~= "" and window.title or item.name
        local reserved = (window.focused and 19 or 0) + (window.hidden and 116 or 0)
        local row = { key = window.id, w = inner, pad = 8, gap = 8, radius = 10, hover = HOVER,
            fill = window.focused and "surface" or nil, border = window.focused and "border" or nil, borderWidth = 1,
            onClick = "window focus " .. window.id,
            help = window.hidden and omniwm.l10n("Unhide and focus %@", title) or omniwm.l10n("Focus %@", title),
            ui.box{ w = 6, h = 6, radius = 3, fill = window.focused and "accent" or "mutedForeground/0.5" },
            ui.text{ text = title, size = 14, color = (window.focused or custom) and "foreground" or "secondaryForeground",
                weight = window.focused and "semibold" or nil, maxWidth = inner - 38 - reserved, lines = 3 },
            ui.box{ grow = 1, h = 1 } }
        if window.focused then
            row[#row + 1] = ui.symbol{ name = "checkmark", size = 11, weight = "bold", color = "accent" }
        end
        if window.hidden then
            row[#row + 1] = hiddenBadge()
        end
        rows[#rows + 1] = ui.row(row)
    end
    return panel(ctx.data.bar.style, WIDTH, ui.column{ w = WIDTH - 2, pad = 12, gap = 10, center = false,
        ui.row{ w = inner, gap = 8,
            ui.icon{ app = item.bundle, w = 22, h = 22, placeholder = "app.dashed" },
            ui.text{ text = item.name, size = 14, weight = "bold", maxWidth = 150 },
            ui.row{ h = 18, radius = 9, fill = "blue/0.2",
                ui.box{ w = 7, h = 1 },
                ui.text{ text = tostring(item.count), size = 11, weight = "bold", color = "blue" },
                ui.box{ w = 7, h = 1 } },
            ui.box{ grow = 1, h = 1 },
            ui.box{ pad = 5, radius = 8, hover = HOVER, onClick = ui.popout,
                ui.text{ text = omniwm.l10n("Close"), size = 12, color = "secondaryForeground" } } },
        ui.column(rows) })
end
