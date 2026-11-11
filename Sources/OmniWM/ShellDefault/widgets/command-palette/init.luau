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
    return ui.row{ gap = 6, pad = 6, radius = look.radius(8), fill = "foreground/0.06", hover = look.hover,
        look.glyph{ name = item.symbol, size = 12, weight = "medium" },
        look.text{ text = item.title, size = 12, weight = "medium" },
        badge(ctx, { text = item.shortcut, tone = "shortcut" }) }
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

local function resultRow(ctx, item, width)
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
    if item.kind == "clipboard" then
        node.onHover = "palette highlight " .. item.id
        node.hoverDelay = 0
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
        local custom = hook("commandPaletteEmpty", ctx, m, width)
        if custom then
            custom.h = if m.state == "disabled" then math.max(height - ACTIONS, 0) else height
            if m.state == "disabled" then
                local enable = action(ctx, { title = omniwm.l10n("Enable"), symbol = "power", shortcut = "" })
                enable.onClick = "palette enable"
                return ui.column{ w = width, h = height, gap = 0, custom,
                    ui.row{ w = width, h = ACTIONS, center = true, enable } }
            end
            return custom
        end
        local body = { w = width, h = height, gap = 10, center = true,
            look.glyph{ name = m.emptySymbol, size = 30, color = "secondaryForeground" },
            look.text{ text = m.emptyText, size = 13, color = "secondaryForeground", maxWidth = width - 40, lines = 2 } }
        if m.state == "disabled" then
            local enable = action(ctx, { title = omniwm.l10n("Enable"), symbol = "power", shortcut = "" })
            enable.onClick = "palette enable"
            body[#body + 1] = enable
        end
        return ui.column(body)
    end
    local list = { key = "results", w = width, h = height, pad = OUTER, gap = 0, scroll = true }
    if (m.before or 0) > 0 then
        list[#list + 1] = ui.box{ key = "results-before", w = 1, h = m.before }
    end
    for _, item in m.rows do
        list[#list + 1] = resultRow(ctx, item, width - 2 * OUTER)
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
    if item.state == "text" then
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
    local props = { key = "clipboard-preview", w = width, h = height, pad = PREVIEW_INSET, center = false, body }
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
        if #m.actions > 0 and not m.unified and m.state ~= "disabled" then
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
        if m.mode == "clipboard" and not m.unified and m.state == "results" then
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
