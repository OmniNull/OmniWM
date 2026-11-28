-- SPDX-License-Identifier: GPL-2.0-only
-- Lefty for OmniWM. Follows the structure of OmniWM's Sakura style, (C) 2026 OmniNull, GPL-2.0-only.

-- The accent is reserved for the focused workspace and the primary control, so hover stays neutral.
local HOVER = "foreground/0.08"
local RADIUS = { control = 10, group = 14, panel = 20 }
local DURATION = 0.18
local COVERS = { background = true, surface = true, elevatedSurface = true }
local PANEL_GLOW = { 0.35, 0.7, 1.4, 0.35 }

-- Items keep their full size from a 30 pt bar up to 40 pt, then grow with the bar.
local function scale(ctx): number
    local height = ctx.data.bar.style.height
    return math.max(height / 40, math.min(1, height / 30))
end

local function bar(ctx, props)
    local style = ctx.data.bar.style
    local s = scale(ctx)
    props.gap = props.gap or 5 * s
    props.pad = props.pad or 4 * s
    props.radius = RADIUS.control * s
    if props.onClick or props.onRightClick then
        props.hover = props.hover or HOVER
    end
    if style.backgrounds then
        props.fill = props.fill or "elevatedSurface/0.8"
    end
    if style.vertical then
        props.w = props.w or style.height - 4
        return ui.column(props)
    end
    props.h = props.h or style.height - 4
    return ui.row(props)
end

local function panel(_, props)
    props.pad = props.pad or 14
    props.gap = props.gap or 12
    props.center = false
    return ui.stack{ w = props.w, h = props.h, radius = RADIUS.panel, material = "clear",
        fill = "surface", border = "border/0.8", borderWidth = 1, open = 0.2, close = 0.16,
        ui.shader{ source = "glow.metal", values = PANEL_GLOW, fps = 24, radius = RADIUS.panel },
        ui.column(props) }
end

local function group(props)
    props.pad = props.pad or 12
    props.gap = props.gap or 8
    props.radius = RADIUS.group
    props.fill = props.fill or "elevatedSurface/0.85"
    props.border = "border/0.5"
    props.borderWidth = 1
    props.center = false
    return ui.column(props)
end

local function heading(text: string, width: number?)
    return ui.row{ w = width, gap = 8,
        ui.box{ w = 6, h = 6, radius = 3, fill = "accent" },
        ui.text{ text = text, size = 14, weight = "semibold", color = "foreground" } }
end

local function button(name: string, action, props)
    local color = props.color
    props.color = nil
    props.w = props.w or 28
    props.h = props.h or 28
    props.radius = props.radius or RADIUS.control
    props.hover = props.hover or HOVER
    props.onClick = action
    props[#props + 1] = ui.symbol{ name = name, size = 14, weight = "medium", color = color or "foreground" }
    return ui.stack(props)
end

local function clockBar(ctx, m)
    if ctx.data.bar.style.vertical then
        return nil
    end
    local s = scale(ctx)
    local row = { gap = 8 * s, hover = HOVER }
    if m.showIcon then
        row[#row + 1] = ui.symbol{ name = "calendar", size = 13 * s, color = "secondaryForeground" }
    end
    if m.showDate then
        row[#row + 1] = ui.text{ text = m.date, size = 13 * s, color = "secondaryForeground" }
        row[#row + 1] = ui.box{ w = 3 * s, h = 3 * s, radius = 1.5 * s, fill = "mutedForeground" }
    end
    row[#row + 1] = ui.text{ text = m.time, size = 13 * s, weight = "semibold", color = "foreground",
        reserve = "00:00 PM" }
    return bar(ctx, row)
end

-- The cover's colour and width, which displays may set for themselves by name.
local function cover(ctx, style): (string?, number?)
    local settings = ctx.data.settings or {}
    local own = if type(settings.displays) == "table" then settings.displays[ctx.data.bar.monitor] else nil
    own = if type(own) == "table" then own else {}
    local color, width = own.cover or settings.cover, own.coverWidth or settings.coverWidth
    if style.vertical or type(color) ~= "string" or type(width) ~= "number" or width <= 0 then
        return nil
    end
    if not COVERS[color] and not string.match(color, "^#%x%x%x%x%x%x$") then
        return nil
    end
    return color, width
end

local function workspaceMarker(ctx, workspace, style, m, occupied: boolean)
    if m.indicator ~= "numbers" or (m.compact and not style.labels) then
        return nil
    end
    local focused = workspace.focused
    local fill, color
    if focused then
        fill = if style.accents then "accent" else "foreground/0.14"
        color = if style.accents then "accentForeground" else "foreground"
    else
        fill = if occupied then "foreground/0.08" else nil
        -- A cover can be any colour, so keep empty workspaces legible on it.
        local dim = if cover(ctx, style) then "foreground/0.9" else "secondaryForeground"
        color = if occupied then "foreground" else dim
    end
    if style.textColor ~= nil then
        color = "foreground"
    end
    local size = math.min(math.max(16, math.round(m.icon * 0.95)) + 6, m.item - 2)
    local label = ui.text{ text = workspace.name, size = 13 * m.scale,
        weight = if focused then "semibold" else "medium", color = color,
        maxWidth = if m.vertical then m.item - 10 else nil }
    if utf8.len(workspace.name) == 1 then
        local long = if focused then math.round(size * 1.5) else size
        return ui.stack{ w = if m.vertical then size else long, h = if m.vertical then long else size,
            radius = size / 2, fill = fill, animate = DURATION, label }
    end
    return ui.row{ h = size, radius = size / 2, fill = fill, animate = DURATION,
        ui.box{ w = 8, h = 1 }, label, ui.box{ w = 8, h = 1 } }
end

-- Fill Left of Notch leaves the macOS app menus visible behind a transparent bar. Setting a cover colour and width
-- on the workspaces widget draws one opaque strip over them, with buttons that open the same menus. The strip always
-- spans at least the whole width, because an app's menus can be longer than the workspaces.
local function workspaceGroup(ctx, pills, _, style, m)
    local color, width = cover(ctx, style)
    if not color then
        return nil
    end
    local app = ctx.data.menuApp
    -- The row sizes itself and paints its own cover, so workspaces that outgrow the strip widen the bar.
    local row = { h = style.height, gap = 8, align = "leading", fill = color, ui.box{ w = 4, h = 1 },
        ui.stack{ w = m.item, h = m.item, radius = RADIUS.control, hover = HOVER, onClick = "menu apple",
            help = omniwm.l10n("Apple Menu"),
            ui.symbol{ name = "apple.logo", size = 15 * m.scale, color = "foreground" } } }
    if app then
        row[#row + 1] = ui.stack{ w = m.item, h = m.item, radius = RADIUS.control, hover = HOVER, onClick = "menu app",
            help = app.name, ui.icon{ app = if app.bundle ~= "" then app.bundle else nil,
                pid = if app.bundle == "" then app.pid else nil, w = m.icon, h = m.icon, placeholder = "app.dashed" } }
    end
    row[#row + 1] = ui.row(pills)
    row[#row + 1] = ui.box{ w = 4, h = 1 }
    return ui.stack{ h = style.height,
        ui.box{ w = width, h = style.height, align = "leading", fill = color }, ui.row(row) }
end

return require("./skin")({
    base = 40,
    scale = scale,
    hover = HOVER,
    width = 320,
    bar = bar,
    panel = panel,
    group = group,
    heading = heading,
    button = button,
    primaryButton = { w = 36, h = 36, radius = 18, fill = "accent", color = "accentForeground" },
    clockBar = clockBar,
    workspaceMarker = workspaceMarker,
    workspaceGroup = workspaceGroup,
    workspacePill = function(pill, _, _, m)
        pill.radius = m.item / 2
    end,
    windowIcon = function(icon)
        icon.radius = 6
        icon.hoverScale = 1.08
    end,
})
