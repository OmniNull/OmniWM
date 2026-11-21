-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local FONT = "Space Grotesk"
local ICON = 28
local TRAILING = 200
local INNER = 8
local TILE = 75
local ROW_SYMBOL = 19
local TILE_SYMBOL = 36

local function text(props)
    props.font = FONT
    return ui.text(props)
end

local function tone(name)
    return if name == "accent" then "accent"
        elseif name == "danger" then "error"
        elseif name == "warning" then "warning"
        else "secondaryForeground"
end

local function badge(item)
    return ui.row{ pad = 4, radius = 8, fill = if item.tone == "accent" then "accent/0.16" else "secondaryContainer/0.55",
        opacity = if item.tone == "shortcutMuted" then 0.6 else nil,
        text{ text = item.text, size = 10.5, weight = "semibold", color = tone(item.tone) } }
end

local function icon(item, size, glyph, color)
    return if item.icon.bitmap then ui.image{ image = item.icon.bitmap, w = size, h = size }
        elseif item.icon.symbol then ui.stack{ w = size, h = size,
            ui.symbol{ name = item.icon.symbol, size = glyph, color = color } }
        else ui.icon{ app = item.icon.app, pid = item.icon.pid, w = size, h = size, placeholder = "app.fill" }
end

return require("./skin")({
    capsules = true,
    commandPalettePanel = function(_, props)
        props.radius = 26
        props.material = "glass"
        props.border = "accent/0.30"
        props.borderWidth = 1
        props.center = false
        return ui.column(props)
    end,
    commandPaletteSearch = function(_, m, input, width)
        input.font = FONT
        input.size = 21
        input.weight = "medium"
        local row = { w = width, h = 56, gap = 12, pad = 20,
            ui.symbol{ name = "magnifyingglass", size = 17, weight = "semibold", color = "accent" },
            ui.input(input) }
        if m.browseModes then
            row[#row + 1] = ui.stack{ w = 28, h = 28, radius = 14, hover = "accent/0.14",
                onClick = "palette menu modes", help = omniwm.l10n("Browse modes"),
                ui.symbol{ name = "ellipsis", size = 14, weight = "semibold", color = "secondaryForeground" } }
        end
        if m.query ~= "" then
            row[#row + 1] = ui.stack{ w = 22, h = 22, radius = 11, fill = "secondaryContainer/0.6", hover = "accent/0.2",
                onClick = "palette clear", help = omniwm.l10n("Clear"),
                ui.symbol{ name = "xmark", size = 10, weight = "bold", color = "secondaryForeground" } }
        end
        return ui.row(row)
    end,
    commandPaletteTabs = function(_, m)
        local row = { gap = 4, h = 56, pad = 4 }
        for _, mode in m.modes do
            row[#row + 1] = ui.stack{ key = "mode-" .. mode.id, w = 34, h = 34, radius = 17,
                fill = if mode.selected then "accent" else nil,
                opacity = if mode.enabled then 1 else 0.38,
                hover = if mode.enabled and not mode.selected then "accent/0.14" else nil,
                onClick = if mode.enabled then "palette mode " .. mode.id else nil,
                help = mode.title .. " (" .. mode.shortcut .. ")",
                ui.symbol{ name = mode.symbol, size = 14, weight = "semibold",
                    color = if mode.selected then "accentForeground" else "secondaryForeground" } }
        end
        return ui.row(row)
    end,
    commandPaletteBadge = function(_, item)
        return badge(item)
    end,
    commandPaletteAction = function(_, item)
        local node = { gap = 6, pad = 6, radius = 14, fill = "secondaryContainer/0.55", hover = "accent/0.16",
            ui.symbol{ name = item.symbol, size = 12, weight = "semibold", color = "accent" },
            text{ text = item.title, size = 12, weight = "medium" } }
        if item.shortcut ~= "" then
            node[#node + 1] = text{ text = item.shortcut, size = 10.5, color = "secondaryForeground" }
        end
        return ui.row(node)
    end,
    commandPaletteRow = function(_, item, width)
        local trailing = { gap = 6 }
        if item.hint then
            trailing[#trailing + 1] = text{ text = item.hint, size = 11, weight = "medium", color = "accent" }
            trailing[#trailing + 1] = badge({ text = item.hintShortcut or "", tone = "accent" })
        end
        for _, entry in item.badges do
            trailing[#trailing + 1] = badge(entry)
        end
        for _, mark in item.marks do
            trailing[#trailing + 1] = badge({ text = mark.text, tone = "accent" })
        end
        if item.pinned then
            trailing[#trailing + 1] = ui.symbol{ name = "pin.fill", size = 10, color = "accent" }
        end
        local hasIcon = item.kind ~= "menu"
        local reserved = if item.kind == "window" or item.kind == "command" or #trailing > 0 then TRAILING else 0
        local textWidth = math.max(width - 2 * INNER - (if hasIcon then ICON + 10 else 0) - reserved, 1)
        local label = { grow = 1, gap = 2, center = false,
            text{ text = item.title, size = 13.5, weight = "medium", maxWidth = textWidth } }
        if item.subtitle ~= "" then
            label[#label + 1] = text{ text = item.subtitle, size = 11, color = "secondaryForeground",
                maxWidth = textWidth }
        end
        local body = { w = width, gap = 10, pad = INNER, radius = 14,
            fill = if item.selected then "accent/0.16" else nil,
            border = if item.selected then "accent/0.55" else nil,
            borderWidth = if item.selected then 1 else nil,
            hover = if item.enabled and not item.selected then "accent/0.08" else nil,
            opacity = if item.enabled then nil else 0.55 }
        if hasIcon then
            body[#body + 1] = icon(item, ICON, ROW_SYMBOL, if item.selected then "accent" else "secondaryForeground")
        end
        body[#body + 1] = ui.column(label)
        if #trailing > 0 then
            body[#body + 1] = ui.row(trailing)
        end
        return ui.row(body)
    end,
    commandPaletteSection = function(_, item, width)
        return ui.column{ w = width, gap = 0, center = false,
            ui.box{ w = 1, h = 12 },
            ui.row{ gap = 6,
                ui.box{ w = 10, h = 1 },
                ui.box{ w = 6, h = 6, radius = 3, fill = "accent" },
                text{ text = string.upper(item.title), size = 10.5, weight = "semibold", color = "secondaryForeground",
                    maxWidth = width - 28 } },
            ui.box{ w = 1, h = 4 } }
    end,
    commandPaletteEmpty = function(_, m, width)
        return ui.column{ w = width, grow = 1, gap = 10, center = true,
            ui.stack{ w = 56, h = 56, radius = 28, fill = "accent/0.14",
                ui.symbol{ name = if m.emptySymbol ~= "" then m.emptySymbol else "sparkles", size = 22,
                    weight = "semibold", color = "accent" } },
            text{ text = m.emptyText, size = 13, color = "secondaryForeground", maxWidth = width - 40, lines = 2 } }
    end,
    commandPalettePreview = function(_, _, props)
        props.radius = 18
        props.fill = "secondaryContainer/0.35"
        return ui.column(props)
    end,
    commandPaletteToolbar = function(_, _, props)
        return ui.row(props)
    end,
    commandPaletteChip = function(_, item, kind)
        if item.symbol ~= "" then
            return ui.stack{ w = 26, h = 26, radius = 13, fill = if item.selected then "accent" else nil,
                hover = if item.selected then nil else "accent/0.14",
                ui.symbol{ name = item.symbol, size = 12, weight = "semibold",
                    color = if item.selected then "accentForeground" else "secondaryForeground" } }
        end
        return ui.row{ pad = 6, radius = 13,
            fill = if item.selected then "accent" elseif kind == "chip" then "secondaryContainer/0.55" else nil,
            hover = if item.selected then nil else "accent/0.14",
            text{ text = item.title, size = 11.5, weight = "semibold",
                color = if item.selected then "accentForeground" else "foreground" } }
    end,
    commandPaletteCell = function(_, item, width, height)
        return ui.column{ w = width, h = height, gap = 7, pad = 6, radius = 18,
            fill = if item.selected then "accent/0.16" else nil,
            border = if item.selected then "accent/0.55" else nil,
            borderWidth = if item.selected then 1 else nil,
            hover = if item.selected then nil else "accent/0.08",
            ui.stack{ w = TILE, h = TILE, radius = 20, fill = "secondaryContainer/0.45",
                icon(item, TILE, TILE_SYMBOL, if item.selected then "accent" else "secondaryForeground") },
            text{ text = item.title, size = 12, weight = "medium", maxWidth = width - 12,
                lines = if item.kind == "file" then 2 else 1 } }
    end,
})
