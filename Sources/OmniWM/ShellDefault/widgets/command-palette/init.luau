-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("../lib/look")

local SEARCH = 56
local FIELD = 24
local ICON = 28
local OUTER = 8
local INNER = 8
local TAB = 36
local ACTIONS = 40
local TRAILING = 200
local DEFAULT_WIDTH = 640
local SECTION_TOP = 12
local SECTION_BOTTOM = 4
local SECTION_INSET = 12
local DISABLED = 0.55
local MUTED = 0.6
local CONTROL = 28
local NOTICE = 32
local PREVIEW_INSET = 12
local LIST_FRACTION = 0.55
local SPIN_SECONDS = 1
local TOOLBAR = 40
local TOGGLE = 24
local GRID_GAP = 10
local GRID_PAD = 6
local TILE = 75
local TILE_SYMBOL = 36
local CELL_PAD = 6
local CELL_GAP = 7
local CELL_LINE = 15
local DETAIL_LABEL = 80
local DETAIL_LINE = 16
local TITLE_LINES = 2
local TITLE_LINE = 17
local PREVIEW_GAP = 6
local PREVIEW_SYMBOL = 48
local LAUNCHER_KINDS = { application = true, file = true, saved = true, executable = true }
local HOVER_KINDS = { saved = true, executable = true }

function render(ctx)
    return ui.row{}
end

local function hook(name, ...)
    local draw = look[name]
    if draw then
        return draw(...)
    end
    return nil
end

local SHORTCUT = { fill = "foreground/0.08", color = "secondaryForeground", mono = true }

local TONES = {
    neutral = { fill = "secondaryForeground/0.18" },
    accent = { fill = "accent/0.12", color = "accent" },
    danger = { fill = "error/0.18", border = "error/0.65" },
    warning = { fill = "warning/0.16", color = "warning" },
    shortcut = SHORTCUT,
    shortcutMuted = { fill = SHORTCUT.fill, color = SHORTCUT.color, mono = true, opacity = MUTED },
}

local function badge(ctx, item)
    local custom = hook("commandPaletteBadge", ctx, item)
    if custom then
        return custom
    end
    local tone = TONES[item.tone] or TONES.neutral
    local row = { gap = 4, pad = 4, radius = look.radius(9), fill = tone.fill, border = tone.border,
        borderWidth = if tone.border then 1 else nil, opacity = tone.opacity }
    if item.symbol then
        row[#row + 1] = look.glyph{ name = item.symbol, size = 10, weight = "semibold", color = tone.color }
    end
    row[#row + 1] = look.text{ text = item.text, size = if tone.mono then 10 else 11,
        weight = "semibold", color = tone.color, style = if tone.mono then "mono" else nil }
    return ui.row(row)
end

local function field(ctx, m, width)
    local input = { key = "query", grow = 1, h = FIELD, size = 20, color = "foreground",
        placeholder = m.placeholder, text = m.query, focus = true }
    local custom = hook("commandPaletteSearch", ctx, m, input, width)
    if custom then
        return custom
    end
    local symbol = "magnifyingglass"
    for _, mode in m.modes do
        if m.expanded and mode.selected then
            symbol = mode.symbol
        end
    end
    local row = { w = width, h = SEARCH, gap = 10, pad = 20,
        look.glyph{ name = symbol, size = 18, weight = "medium", color = "secondaryForeground" },
        ui.input(input) }
    if m.browseModes then
        row[#row + 1] = ui.stack{ w = CONTROL, h = CONTROL, radius = look.radius(8), hover = look.hover,
            onClick = "palette menu modes", help = omniwm.l10n("Browse modes"),
            look.glyph{ name = "ellipsis.circle", size = 17, color = "secondaryForeground" } }
    end
    if m.query ~= "" then
        row[#row + 1] = ui.stack{ w = 20, h = 20, radius = look.radius(10), hover = look.hover,
            onClick = "palette clear", help = omniwm.l10n("Clear"),
            look.glyph{ name = "xmark.circle.fill", size = 14, color = "secondaryForeground" } }
    end
    return ui.row(row)
end

local function tabs(ctx, m)
    local custom = hook("commandPaletteTabs", ctx, m)
    if custom then
        return custom
    end
    local row = { gap = 8, h = SEARCH }
    for _, mode in m.modes do
        row[#row + 1] = ui.stack{ key = "mode-" .. mode.id, w = TAB, h = TAB, radius = look.radius(TAB / 2),
            fill = if mode.selected then "foreground/0.12" else nil,
            border = if mode.selected then "foreground/0.16" else "foreground/0.08", borderWidth = 1,
            opacity = if mode.enabled then 1 else 0.38,
            hover = if mode.enabled then look.hover else nil,
            onClick = if mode.enabled then "palette mode " .. mode.id else nil,
            help = mode.title .. " (" .. mode.shortcut .. ")",
            look.glyph{ name = mode.symbol, size = 15, weight = "medium",
                color = if mode.selected then "foreground" else "secondaryForeground" } }
    end
    return ui.row(row)
end

local function action(ctx, item)
    local custom = hook("commandPaletteAction", ctx, item)
    if custom then
        return custom
    end
    local node = { gap = 6, pad = 6, radius = look.radius(8), fill = "foreground/0.06", hover = look.hover,
        look.glyph{ name = item.symbol, size = 12, weight = "medium" },
        look.text{ text = item.title, size = 12, weight = "medium" } }
    if item.shortcut ~= "" then
        node[#node + 1] = badge(ctx, { text = item.shortcut, tone = "shortcut" })
    end
    return ui.row(node)
end

local function chip(ctx, item, kind)
    local custom = hook("commandPaletteChip", ctx, item, kind)
    if custom then
        return custom
    end
    if item.symbol ~= "" then
        return ui.stack{ w = TOGGLE, h = TOGGLE, radius = look.radius(6), hover = look.hover,
            fill = if item.selected then "foreground/0.12" else nil,
            look.glyph{ name = item.symbol, size = 12,
                color = if item.selected then "foreground" else "secondaryForeground" } }
    end
    local selected = if kind == "chip" then "accent/0.18" else "foreground/0.12"
    return ui.row{ pad = 6, radius = look.radius(if kind == "chip" then 12 else 6), hover = look.hover,
        fill = if item.selected then selected elseif kind == "chip" then "secondaryForeground/0.12" else nil,
        look.text{ text = item.title, size = 11, weight = "medium",
            color = if item.selected and kind == "chip" then "accent" else nil } }
end

local function chips(ctx, items, kind, props)
    for _, item in items do
        local node = chip(ctx, item, kind)
        node.key = kind .. "-" .. item.id
        node.onClick = "palette " .. kind .. " " .. item.id
        node.help = item.title
        props[#props + 1] = node
    end
    return ui.row(props)
end

local function toolbar(ctx, m, width)
    local bar = m.launcher
    local props = { key = "launcher-toolbar", w = width, h = TOOLBAR, gap = 8, pad = 8 }
    if #bar.filters > 0 then
        props[#props + 1] = chips(ctx, bar.filters, "filter",
            { gap = 2, pad = 2, radius = look.radius(8), fill = "foreground/0.06" })
    end
    props[#props + 1] = chips(ctx, bar.chips, "chip", { key = "launcher-chips", grow = 1, gap = 6, scroll = true })
    if bar.add then
        local add = action(ctx, bar.add)
        add.onClick = "palette menu " .. bar.add.id
        add.help = bar.add.title
        props[#props + 1] = add
    end
    if #bar.views > 0 then
        props[#props + 1] = chips(ctx, bar.views, "view",
            { gap = 2, pad = 2, radius = look.radius(8), fill = "foreground/0.06" })
    end
    return hook("commandPaletteToolbar", ctx, m, props) or ui.row(props)
end

local function row(ctx, item, width)
    local custom = hook("commandPaletteRow", ctx, item, width)
    if custom then
        return custom
    end
    local trailing = { gap = 8 }
    if item.hint then
        trailing[#trailing + 1] = look.text{ text = item.hint, size = 11, weight = "medium",
            color = "secondaryForeground" }
        trailing[#trailing + 1] = badge(ctx, { text = item.hintShortcut or "", tone = "shortcut" })
    end
    for _, entry in item.badges do
        trailing[#trailing + 1] = badge(ctx, entry)
    end
    local right = { gap = 4, ui.row(trailing) }
    for _, mark in item.marks do
        right[#right + 1] = badge(ctx, mark)
    end
    local hasIcon = item.kind ~= "menu"
    local hasTrailing = item.hint ~= nil or #item.badges > 0 or #item.marks > 0
    local reserved = if item.kind == "window" or item.kind == "command" or hasTrailing then TRAILING else 0
    local textWidth = math.max(width - 2 * INNER - (if hasIcon then ICON + 10 else 0) - reserved, 1)
    local title = look.text{ text = item.title, size = 13, weight = "medium",
        maxWidth = math.max(textWidth - (if item.pinned then 14 else 0), 1) }
    local label = { grow = 1, gap = 2, center = false,
        if item.pinned then ui.row{ gap = 4, title,
            look.glyph{ name = "pin.fill", size = 10, color = "secondaryForeground" } } else title }
    if item.subtitle ~= "" then
        label[#label + 1] = look.text{ text = item.subtitle, size = 11, color = "secondaryForeground",
            maxWidth = textWidth }
    end
    local body = { w = width, gap = 10, pad = INNER, radius = look.radius(10),
        fill = if item.selected then "foreground/0.10" else nil,
        hover = if item.enabled then look.hover else nil,
        opacity = if item.enabled then nil else DISABLED }
    if hasIcon then
        body[#body + 1] = if item.icon.bitmap then ui.image{ image = item.icon.bitmap, w = ICON, h = ICON }
            elseif item.icon.symbol then look.glyph{ name = item.icon.symbol, w = ICON, h = ICON, size = 20,
                color = "secondaryForeground" }
            else ui.icon{ app = item.icon.app, pid = item.icon.pid, w = ICON, h = ICON, placeholder = "app.fill" }
    end
    body[#body + 1] = ui.column(label)
    if hasTrailing then
        body[#body + 1] = ui.column(right)
    end
    return ui.row(body)
end

local function section(ctx, item, width)
    local custom = hook("commandPaletteSection", ctx, item, width)
    if custom then
        return custom
    end
    return ui.column{ w = width, gap = 0, center = false,
        ui.box{ w = 1, h = SECTION_TOP },
        ui.row{ gap = 0,
            ui.box{ w = SECTION_INSET, h = 1 },
            look.text{ text = item.title, size = 11, weight = "semibold", color = "secondaryForeground",
                maxWidth = width - SECTION_INSET } },
        ui.box{ w = 1, h = SECTION_BOTTOM } }
end

local function cell(ctx, item, width, height)
    local custom = hook("commandPaletteCell", ctx, item, width, height)
    if custom then
        return custom
    end
    local tile = if item.icon.bitmap then ui.image{ image = item.icon.bitmap, w = TILE, h = TILE }
        else look.glyph{ name = item.icon.symbol or "app.fill", size = TILE_SYMBOL, weight = "light",
            color = "secondaryForeground" }
    return ui.column{ w = width, h = height, gap = CELL_GAP, pad = CELL_PAD, radius = look.radius(10),
        fill = if item.selected then "foreground/0.10" else nil, hover = look.hover,
        ui.stack{ w = TILE, h = TILE, radius = look.radius(16), fill = "secondaryForeground/0.12", tile },
        look.text{ text = item.title, size = 12, weight = "medium", maxWidth = width - 2 * CELL_PAD,
            lines = if item.kind == "file" then 2 else 1 } }
end

local function gridRow(ctx, m, item, width)
    local columns = math.max(m.launcher.columns, 1)
    local lines = if item.cells[1].kind == "file" then 2 else 1
    local height = 2 * CELL_PAD + TILE + CELL_GAP + lines * CELL_LINE
    local cellWidth = math.max((width - 2 * GRID_PAD - (columns - 1) * GRID_GAP) / columns, 1)
    local row = { key = item.id, w = width, gap = GRID_GAP, pad = GRID_PAD, center = false }
    for _, entry in item.cells do
        local node = cell(ctx, entry, cellWidth, height)
        node.key = entry.id
        node.onClick = "palette activate " .. entry.id
        node.menu = true
        node.target = entry.id
        row[#row + 1] = node
    end
    return ui.row(row)
end

local function resultRow(ctx, m, item, width)
    if item.kind == "gridRow" then
        return gridRow(ctx, m, item, width)
    end
    local controls = item.actions or {}
    local rowWidth = math.max(width - #controls * (CONTROL + 4), 1)
    local node = if item.kind == "heading" then section(ctx, item, width) else row(ctx, item, rowWidth)
    if #controls > 0 then
        local children = { w = width, gap = 4, node }
        for _, entry in controls do
            children[#children + 1] = ui.stack{ w = CONTROL, h = CONTROL, radius = look.radius(8),
                hover = look.hover, onClick = "palette " .. entry.id, help = entry.title,
                look.glyph{ name = entry.symbol, size = 13, color = "secondaryForeground" } }
        end
        node = ui.row(children)
    end
    node.key = item.id
    node.onClick = if item.enabled then "palette activate " .. item.id else nil
    local launcher = not m.unified and LAUNCHER_KINDS[item.kind]
    if item.kind == "clipboard" or (launcher and HOVER_KINDS[item.kind]) then
        node.onHover = "palette highlight " .. item.id
        node.hoverDelay = 0
    end
    if item.kind == "clipboard" or launcher then
        node.menu = true
        node.target = item.id
    end
    return node
end

local function results(ctx, m, width, height)
    if m.state == "blank" then
        return ui.box{ w = width, h = height }
    end
    if m.state ~= "results" then
        local button = nil
        if m.emptyAction then
            button = action(ctx, m.emptyAction)
            button.onClick = "palette " .. m.emptyAction.id
        end
        local custom = hook("commandPaletteEmpty", ctx, m, width)
        if custom then
            custom.h = if button then math.max(height - ACTIONS, 0) else height
            if button then
                return ui.column{ w = width, h = height, gap = 0, custom,
                    ui.row{ w = width, h = ACTIONS, center = true, button } }
            end
            return custom
        end
        local body = { w = width, h = height, gap = 10, center = true,
            look.glyph{ name = m.emptySymbol, size = 30, color = "secondaryForeground" },
            look.text{ text = m.emptyText, size = 13, color = "secondaryForeground", maxWidth = width - 40, lines = 2 } }
        if button then
            body[#body + 1] = button
        end
        return ui.column(body)
    end
    local list = { key = "results", w = width, h = height, pad = OUTER, gap = 0, scroll = true }
    if (m.before or 0) > 0 then
        list[#list + 1] = ui.box{ key = "results-before", w = 1, h = m.before }
    end
    for _, item in m.rows do
        list[#list + 1] = resultRow(ctx, m, item, width - 2 * OUTER)
    end
    if (m.after or 0) > 0 then
        list[#list + 1] = ui.box{ key = "results-after", w = 1, h = m.after }
    end
    return ui.column(list)
end

local function preview(ctx, m, width, height)
    local item = m.preview or { id = "none", state = "unavailable" }
    local insideWidth = math.max(width - 2 * PREVIEW_INSET, 1)
    local insideHeight = math.max(height - 2 * PREVIEW_INSET, 1)
    local body
    if item.state == "file" then
        local box = math.max(insideHeight - TITLE_LINES * TITLE_LINE - #item.details * DETAIL_LINE
            - (#item.details + 1) * PREVIEW_GAP, 1)
        local picture
        if item.image then
            local ratio = math.min(1, insideWidth / math.max(item.width, 1), box / math.max(item.height, 1))
            picture = ui.image{ image = item.image, w = item.width * ratio, h = item.height * ratio }
        else
            picture = look.glyph{ name = item.symbol or "doc.fill", size = PREVIEW_SYMBOL, weight = "light",
                color = "secondaryForeground" }
        end
        local children = { w = insideWidth, h = insideHeight, gap = PREVIEW_GAP, center = false,
            ui.stack{ w = insideWidth, h = box, picture },
            look.text{ text = item.title or "", size = 13, weight = "semibold", maxWidth = insideWidth,
                lines = TITLE_LINES } }
        for _, detail in item.details do
            children[#children + 1] = ui.row{ w = insideWidth, gap = 8,
                ui.row{ w = DETAIL_LABEL, center = false,
                    look.text{ text = detail.label, size = 11, color = "secondaryForeground", maxWidth = DETAIL_LABEL } },
                look.text{ text = detail.value, size = 11, maxWidth = math.max(insideWidth - DETAIL_LABEL - 8, 1) } }
        end
        body = ui.column(children)
    elseif item.state == "blank" then
        body = ui.box{ w = insideWidth, h = insideHeight }
    elseif item.state == "text" then
        body = ui.input{ key = "clipboard-preview-" .. item.id, w = insideWidth, h = insideHeight,
            text = item.text or "", multiline = true, editable = false, wrap = false,
            size = 12, color = "foreground" }
    elseif item.state == "image" and item.image then
        local ratio = math.min(insideWidth / math.max(item.width, 1), insideHeight / math.max(item.height, 1))
        body = ui.stack{ w = insideWidth, h = insideHeight,
            ui.image{ image = item.image, w = item.width * ratio, h = item.height * ratio } }
    else
        local children = { w = insideWidth, h = insideHeight, gap = 10, center = true }
        if item.state == "loading" then
            children[#children + 1] = look.glyph{ name = "arrow.triangle.2.circlepath", size = 18,
                color = "secondaryForeground", loop = { rotate = { 0, 360, SPIN_SECONDS } } }
        end
        children[#children + 1] = look.text{ text = if item.state == "loading" then omniwm.l10n("Loading preview…")
            else omniwm.l10n("Preview unavailable"), size = 12, color = "secondaryForeground",
            maxWidth = insideWidth, lines = 2 }
        body = ui.column(children)
    end
    local props = { key = m.mode .. "-preview", w = width, h = height, pad = PREVIEW_INSET, center = false, body }
    return hook("commandPalettePreview", ctx, item, props) or ui.column(props)
end

function popout(ctx)
    local m = ctx.data.commandPalette or { width = DEFAULT_WIDTH, height = SEARCH, expanded = false, query = "",
        placeholder = "", modes = {}, rows = {}, actions = {}, state = "results", mode = "" }
    local width = m.width
    local content = { w = width, h = m.height, pad = 0, gap = 0 }
    if not m.expanded and not m.unified then
        content[1] = ui.row{ w = width, h = SEARCH, gap = 10,
            field(ctx, m, width - (#m.modes * (TAB + 8)) - 10),
            tabs(ctx, m) }
    elseif not m.expanded then
        content[1] = field(ctx, m, width)
    else
        local bodyHeight = math.max(m.height - SEARCH - 1, 0)
        content[#content + 1] = field(ctx, m, width)
        content[#content + 1] = ui.box{ w = width, h = 1, fill = "foreground/0.10" }
        if #m.actions > 0 and not m.unified then
            bodyHeight = math.max(bodyHeight - ACTIONS, 0)
            local bar = { w = width, h = ACTIONS, gap = 10, pad = 8 }
            for _, item in m.actions do
                local node = action(ctx, item)
                node.onClick = "palette " .. item.id
                node.help = item.title .. " (" .. item.shortcut .. ")"
                bar[#bar + 1] = node
            end
            content[#content + 1] = ui.row(bar)
        end
        if m.feedback then
            bodyHeight = math.max(bodyHeight - NOTICE, 0)
            content[#content + 1] = ui.row{ w = width, h = NOTICE, pad = 8,
                look.text{ text = m.feedback, size = 12, color = "secondaryForeground", maxWidth = width - 32 } }
        end
        if m.error then
            bodyHeight = math.max(bodyHeight - NOTICE, 0)
            content[#content + 1] = ui.row{ w = width, h = NOTICE, pad = 8,
                look.glyph{ name = "exclamationmark.triangle", size = 12, color = "error" },
                look.text{ text = m.error, size = 12, color = "error", maxWidth = width - 48 } }
        end
        if m.launcher and not m.unified then
            bodyHeight = math.max(bodyHeight - TOOLBAR, 0)
            content[#content + 1] = toolbar(ctx, m, width)
        end
        if not m.unified and m.state == "results" and (m.mode == "clipboard" or (m.mode == "files" and m.preview)) then
            local listWidth = math.floor(width * LIST_FRACTION)
            content[#content + 1] = ui.row{ w = width, h = bodyHeight, gap = 0, center = false,
                results(ctx, m, listWidth, bodyHeight),
                ui.box{ w = 1, h = bodyHeight, fill = "foreground/0.10" },
                preview(ctx, m, width - listWidth - 1, bodyHeight) }
        else
            content[#content + 1] = results(ctx, m, width, bodyHeight)
        end
    end
    return hook("commandPalettePanel", ctx, content) or look.panel(ctx, content)
end
