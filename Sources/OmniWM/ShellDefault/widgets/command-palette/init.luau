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
    local textWidth = width - 2 * INNER - ICON - 10 - TRAILING
    local label = { grow = 1, gap = 2, center = false,
        look.text{ text = item.title, size = 13, weight = "medium", maxWidth = textWidth } }
    if item.subtitle ~= "" then
        label[#label + 1] = look.text{ text = item.subtitle, size = 11, color = "secondaryForeground",
            maxWidth = textWidth }
    end
    return ui.row{ w = width, gap = 10, pad = INNER, radius = look.radius(10),
        fill = if item.selected then "foreground/0.10" else nil,
        hover = if item.enabled then look.hover else nil,
        opacity = if item.enabled then nil else DISABLED,
        if item.icon.symbol then look.glyph{ name = item.icon.symbol, w = ICON, h = ICON, size = 20,
            color = "secondaryForeground" }
            else ui.icon{ app = item.icon.app, pid = item.icon.pid, w = ICON, h = ICON, placeholder = "app.fill" },
        ui.column(label),
        ui.column(right) }
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

local function results(ctx, m, width)
    if m.state == "empty" then
        local custom = hook("commandPaletteEmpty", ctx, m, width)
        if custom then
            return custom
        end
        return ui.column{ w = width, grow = 1, gap = 10, center = true,
            look.glyph{ name = m.emptySymbol, size = 30, color = "secondaryForeground" },
            look.text{ text = m.emptyText, size = 13, color = "secondaryForeground", maxWidth = width - 40, lines = 2 } }
    end
    local list = { key = "results", w = width, grow = 1, pad = OUTER, gap = 0, scroll = true }
    if (m.before or 0) > 0 then
        list[#list + 1] = ui.box{ key = "results-before", w = 1, h = m.before }
    end
    for _, item in m.rows do
        local node = if item.kind == "heading" then section(ctx, item, width - 2 * OUTER)
            else row(ctx, item, width - 2 * OUTER)
        node.key = item.id
        node.onClick = if item.enabled then "palette activate " .. item.id else nil
        list[#list + 1] = node
    end
    if (m.after or 0) > 0 then
        list[#list + 1] = ui.box{ key = "results-after", w = 1, h = m.after }
    end
    return ui.column(list)
end

function popout(ctx)
    local m = ctx.data.commandPalette or { width = DEFAULT_WIDTH, height = SEARCH, expanded = false, query = "",
        placeholder = "", modes = {}, rows = {}, actions = {}, state = "results", mode = "" }
    local width = m.width
    local content = { w = width, h = m.height, pad = 0, gap = 0 }
    if not m.expanded then
        content[1] = ui.row{ w = width, h = SEARCH, gap = 10,
            field(ctx, m, width - (#m.modes * (TAB + 8)) - 10),
            tabs(ctx, m) }
    else
        content[#content + 1] = field(ctx, m, width)
        content[#content + 1] = ui.box{ w = width, h = 1, fill = "foreground/0.10" }
        if #m.actions > 0 then
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
            content[#content + 1] = ui.row{ w = width, pad = 8,
                look.text{ text = m.feedback, size = 12, color = "secondaryForeground", maxWidth = width - 32 } }
        end
        content[#content + 1] = results(ctx, m, width)
    end
    return hook("commandPalettePanel", ctx, content) or look.panel(ctx, content)
end
