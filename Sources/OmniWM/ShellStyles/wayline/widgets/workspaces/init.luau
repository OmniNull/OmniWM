-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

spanIslands = true

local HOVER = "foreground/0.07"
local WIDTH = 320
local INNER = WIDTH - 24

type Metrics = {
    size: number,
    icon: number,
    slot: number,
    radius: number,
    vertical: boolean,
    underline: boolean,
    scale: number,
}

local function metrics(style: BarStyle, settings): Metrics
    local scale = style.height / 40
    local size = 32 * scale
    local icon = 24 * scale
    local slot = icon + 4 * scale
    return { size = size, icon = icon, slot = slot,
        radius = math.floor(size * 0.24), vertical = style.vertical, underline = settings.indicator == "underline", scale = scale }
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

local function filled(style: BarStyle, m: Metrics, focused: boolean): boolean
    return focused and style.accents and not m.underline
end

local function labelColor(style: BarStyle, m: Metrics, workspace: BarWorkspace): Color
    if style.textColor ~= nil then
        return "foreground"
    end
    if filled(style, m, workspace.focused) then
        return "accentForeground"
    end
    if workspace.focused then
        return style.accents and "accent" or "foreground"
    end
    return style.accents and "accent" or (#workspace.windows > 0 and "secondaryForeground" or "mutedForeground")
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
    return workspaceFocused and 0.55 or 0.6
end

local function countBadge(text: string)
    local size = 11
    return ui.row{ align = "bottomTrailing", dx = 1, dy = 1, h = size, radius = size / 2,
        fill = "surface", border = "border", borderWidth = 1,
        ui.box{ w = 2.5, h = 1 },
        ui.text{ text = text, style = "mono", size = 8, weight = "bold", color = "foreground" },
        ui.box{ w = 2.5, h = 1 } }
end

local function notificationBadge(item: BarItem, mode: string, m: Metrics)
    if mode == "off" or item.badge == "" then
        return nil
    end
    if mode == "dot" then
        return ui.box{ align = "topTrailing", dx = 0, dy = 0, w = 7, h = 7, radius = 3.5, fill = "badge",
            border = "elevatedSurface", borderWidth = 1 }
    end
    return ui.row{ align = "topTrailing", dx = 1, dy = -1, h = 11, radius = 5.5, fill = "badge",
        ui.box{ w = 2.5, h = 1 },
        ui.text{ text = item.badge, style = "mono", size = 8, weight = "bold", color = "background",
            maxWidth = m.slot },
        ui.box{ w = 2.5, h = 1 } }
end

local function hiddenIndicator(item: BarItem)
    if item.hidden == 0 then
        return nil
    end
    local full = appHidden(item)
    return ui.stack{ align = "bottomLeading", dx = -1, dy = 1, w = 10, h = 10, radius = 5,
        fill = full and "badge" or "surface", border = full and nil or "badge", borderWidth = 1,
        ui.symbol{ name = full and "eye.slash.fill" or "eye.slash", size = 6, weight = "bold",
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
    local icon = { key = item.id, w = m.slot, h = m.slot, radius = 5, animate = 0.15, hoverAnimate = 0.1,
        scale = item.focused and 1.08 or 1, hoverScale = item.focused and 1.08 or 1.05,
        dx = m.vertical and 0 or shift, dy = m.vertical and shift or 0,
        border = (drag ~= nil and contains(drag.icons, item.id)) and "accent" or nil, borderWidth = 1.5,
        target = "window " .. item.id, menu = true, preview = true, drag = true, help = windowHelp(item, bar),
        ui.icon{ window = item.id, placeholder = "app.dashed", w = m.icon, h = m.icon,
            opacity = (drag ~= nil and contains(drag.sources, item.id)) and 0.35 or iconOpacity(item, style, workspace.focused),
            color = appHidden(item) and "error/0.32" or nil } }
    if item.count > 1 then
        icon.onClick = function(ctx) ctx.state.picker = item.id end
        icon.popout = true
        icon[#icon + 1] = countBadge(tostring(item.count))
    else
        icon.onClick = "window focus " .. item.id
    end
    icon[#icon + 1] = notificationBadge(item, bar.badges, m)
    icon[#icon + 1] = hiddenIndicator(item)
    return ui.stack(icon)
end

local function floatingGroup(icons, style: BarStyle, m: Metrics)
    local thickness = m.slot
    local group = { gap = m.scale, radius = 5 * m.scale,
        w = if m.vertical then thickness else nil, h = if m.vertical then nil else thickness,
        fill = style.backgrounds and "foreground/0.06" or nil,
        spacer(m.vertical, 3 * m.scale),
        ui.symbol{ name = "rectangle.on.rectangle", size = 12 * m.scale, weight = "semibold",
            color = style.textColor ~= nil and "foreground" or "mutedForeground" },
        spacer(m.vertical, m.scale) }
    for _, icon in ipairs(icons) do
        group[#group + 1] = icon
    end
    group[#group + 1] = spacer(m.vertical, m.scale)
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

local function underline(m: Metrics)
    if m.vertical then
        return ui.path{ viewBox = { 0, 0, m.size, 100 }, d = "M0 20 H2 V80 H0 Z", fill = "accent" }
    end
    return ui.path{ viewBox = { 0, 0, 100, m.size }, d = "M12 " .. tostring(m.size - 2) .. " H88 V" .. tostring(m.size)
        .. " H12 Z", fill = "accent" }
end

local function prefix(workspace: BarWorkspace, style: BarStyle, m: Metrics, joined: boolean)
    local fill = filled(style, m, workspace.focused) and "accent"
        or (style.backgrounds and (style.accents and "accent/0.24" or "foreground/0.07") or nil)
    local block = { w = m.vertical and m.size or (utf8.len(workspace.name) <= 2 and 28 * m.scale or nil),
        h = m.size, radius = m.radius, fill = fill }
    if joined then
        block[#block + 1] = ui.box{ align = m.vertical and "bottom" or "trailing",
            w = m.vertical and m.size or m.radius, h = m.vertical and m.radius or m.size,
            fill = style.backgrounds and "elevatedSurface" or nil,
            ui.box{ w = m.vertical and m.size or m.radius, h = m.vertical and m.radius or m.size, fill = fill } }
    end
    block[#block + 1] = ui.row{ ui.box{ w = 4 * m.scale, h = 1 },
        ui.text{ text = workspace.name, size = 14 * m.scale, weight = "bold", color = labelColor(style, m, workspace),
            maxWidth = m.vertical and m.size - 8 * m.scale or nil,
            help = omniwm.l10n("Focus workspace %@", workspace.name), target = "workspace " .. workspace.id },
        ui.box{ w = 4 * m.scale, h = 1 } }
    return ui.stack(block)
end

local function workspacePill(workspace: BarWorkspace, bar: Bar, m: Metrics)
    local style = bar.style
    local dropTarget = bar.drag ~= nil and contains(bar.drag.workspaces, workspace.id)
    local gap = gapBefore(bar.drag, workspace.id)
    local half = math.min(8, m.icon * 0.4) / 2
    local pill = { key = workspace.id, gap = 4 * m.scale, radius = m.radius,
        w = if m.vertical then m.size else nil, h = if m.vertical then nil else m.size,
        fill = style.backgrounds and "elevatedSurface" or nil,
        hover = (not workspace.focused) and "accent/0.15" or nil,
        border = dropTarget and "accent" or nil, borderWidth = 1.5,
        onClick = "switch-workspace " .. workspace.id,
        target = "workspace " .. workspace.id, menu = true, drop = true }
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
        pill[#pill + 1] = prefix(workspace, style, m, hasWindows)
    else
        pill[#pill + 1] = spacer(m.vertical, 2 * m.scale)
        if filled(style, m, workspace.focused) then
            pill.border = "accent"
        elseif workspace.focused and style.backgrounds and not style.accents then
            pill.border = dropTarget and "accent" or "secondaryForeground/0.5"
        end
    end
    for _, icon in ipairs(tiled) do
        pill[#pill + 1] = icon
    end
    if #floating > 0 then
        if #tiled > 0 then
            pill[#pill + 1] = spacer(m.vertical, 1)
        end
        pill[#pill + 1] = floatingGroup(floating, style, m)
    end
    if hasWindows then
        pill[#pill + 1] = spacer(m.vertical, 2 * m.scale)
    end
    if m.underline and workspace.focused and style.accents then
        return ui.stack{ key = workspace.id .. ".underline", line(m.vertical, pill), underline(m) }
    end
    return line(m.vertical, pill)
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

local function hiddenBadge()
    return ui.row{ gap = 4, h = 20, radius = 6, fill = "error/0.16",
        ui.box{ w = 3, h = 1 },
        ui.symbol{ name = "eye.slash.fill", size = 10, weight = "semibold", color = "error" },
        ui.text{ text = omniwm.l10n("App hidden"), size = 11, weight = "semibold", color = "error" },
        ui.box{ w = 4, h = 1 } }
end

function render(ctx: Context)
    local bar = ctx.data.bar
    local m = metrics(bar.style, ctx.data.settings or {})
    local pills = { gap = 6 * m.scale }
    for _, workspace in ipairs(bar.workspaces) do
        if bar.island == "all" or workspace.focused == (bar.island == "active") then
            pills[#pills + 1] = workspacePill(workspace, bar, m)
        end
    end
    return line(m.vertical, pills)
end

function popout(ctx: Context)
    local item = findItem(ctx.data.bar, ctx.state.picker)
    if not item or item.count < 2 then
        return ui.column{}
    end
    local custom = ctx.data.bar.style.textColor ~= nil
    local rows = { w = INNER, gap = 0, pad = 0, radius = 9, fill = "elevatedSurface", center = true, scroll = true }
    for index, window in ipairs(item.windows) do
        local title = window.title ~= "" and window.title or item.name
        local reserved = (window.focused and 22 or 0) + (window.hidden and 120 or 0)
        if index > 1 then
            rows[#rows + 1] = ui.box{ w = INNER - 20, h = 1, fill = "foreground/0.07" }
        end
        local row = { key = window.id, w = INNER, pad = 10, gap = 8, radius = 9, hover = HOVER,
            onClick = "window focus " .. window.id,
            help = window.hidden and omniwm.l10n("Unhide and focus %@", title) or omniwm.l10n("Focus %@", title),
            ui.box{ w = 3, h = 16, radius = 1.5, fill = window.focused and "accent" or "foreground/0.12" },
            ui.text{ text = title, size = 14, weight = window.focused and "semibold" or "medium",
                color = (window.focused or custom) and "foreground" or "secondaryForeground",
                maxWidth = INNER - 40 - reserved, lines = 255 },
            ui.box{ grow = 1, h = 1 } }
        if window.focused then
            row[#row + 1] = ui.symbol{ name = "checkmark", size = 11, weight = "bold", color = "accent" }
        end
        if window.hidden then
            row[#row + 1] = hiddenBadge()
        end
        rows[#rows + 1] = ui.row(row)
    end
    return ui.column{ w = WIDTH, gap = 0, material = "clear", radius = 12, fill = "surface", border = "border",
        borderWidth = 1, center = false,
        ui.stack{ w = WIDTH, h = 44,
            ui.box{ w = WIDTH, h = 44, radius = 12, fill = "elevatedSurface" },
            ui.box{ align = "bottom", w = WIDTH, h = 12, fill = "elevatedSurface" },
            ui.row{ w = INNER, gap = 8,
                ui.icon{ app = item.bundle, w = 18, h = 18, placeholder = "app.dashed" },
                ui.text{ text = item.name, size = 13, weight = "bold", color = "foreground", maxWidth = 180 },
                ui.box{ grow = 1, h = 1 },
                ui.row{ h = 24, radius = 6, fill = "foreground/0.06", hover = HOVER, onClick = ui.popout,
                    ui.box{ w = 9, h = 1 },
                    ui.text{ text = omniwm.l10n("Close"), size = 11, weight = "semibold", color = "secondaryForeground" },
                    ui.box{ w = 9, h = 1 } } } },
        ui.box{ w = WIDTH, h = 1, fill = "border" },
        ui.column{ w = WIDTH, pad = 12, center = false, ui.column(rows) } }
end
