-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local ICON = 28
local TRAILING = 200
local INNER = 8
local TILE = 75
local ROW_SYMBOL = 18
local TILE_SYMBOL = 34
local PILL = 20
local HOVER = "foreground/0.06"
local SELECTED = "foreground/0.09"
local QUIET = "foreground/0.05"

local function capsule(item)
    return ui.row{ pad = 4, radius = 9, fill = if item.tone == "accent" then "accent/0.14" else QUIET,
        opacity = if item.tone == "shortcutMuted" then 0.6 else nil,
        ui.text{ text = item.text, size = 10.5, weight = "medium",
            color = if item.tone == "accent" then "accent" elseif item.tone == "danger" then "error"
                elseif item.tone == "warning" then "warning" else "secondaryForeground" } }
end

local function icon(item, size, glyph)
    return if item.icon.bitmap then ui.image{ image = item.icon.bitmap, w = size, h = size }
        elseif item.icon.symbol then ui.stack{ w = size, h = size,
            ui.symbol{ name = item.icon.symbol, size = glyph, color = "secondaryForeground" } }
        else ui.icon{ app = item.icon.app, pid = item.icon.pid, w = size, h = size, placeholder = "app.fill" }
end

return require("./skin")({
    capsules = true,
    commandPalettePanel = function(_, props)
        props.radius = 30
        props.fill = "surface"
        props.center = false
        return ui.column(props)
    end,
    commandPaletteSearch = function(_, m, input, width)
        input.size = 19
        local field = { grow = 1, h = 38, gap = 8, pad = 10, radius = 19, fill = QUIET,
            ui.symbol{ name = "magnifyingglass", size = 14, weight = "semibold", color = "secondaryForeground" },
            ui.input(input) }
        if m.query ~= "" then
            field[#field + 1] = ui.stack{ w = 20, h = 20, radius = 10, hover = HOVER,
                onClick = "palette clear", help = omniwm.l10n("Clear"),
                ui.symbol{ name = "xmark.circle.fill", size = 13, color = "secondaryForeground" } }
        end
        local row = { w = width, h = 56, gap = 8, pad = 9, ui.row(field) }
        if m.browseModes then
            row[#row + 1] = ui.stack{ w = 30, h = 30, radius = 15, fill = QUIET, hover = HOVER,
                onClick = "palette menu modes", help = omniwm.l10n("Browse modes"),
                ui.symbol{ name = "ellipsis", size = 13, weight = "semibold", color = "secondaryForeground" } }
        end
        return ui.row(row)
    end,
    commandPaletteTabs = function(_, m)
        local row = { gap = 2, pad = 3, radius = 19, fill = QUIET }
        for _, mode in m.modes do
            row[#row + 1] = ui.stack{ key = "mode-" .. mode.id, w = 32, h = 32, radius = 16,
                fill = if mode.selected then "surface" else nil,
                border = if mode.selected then "foreground/0.08" else nil,
                borderWidth = if mode.selected then 1 else nil,
                opacity = if mode.enabled then 1 else 0.38,
                hover = if mode.enabled and not mode.selected then HOVER else nil,
                onClick = if mode.enabled then "palette mode " .. mode.id else nil,
                help = mode.title .. " (" .. mode.shortcut .. ")",
                ui.symbol{ name = mode.symbol, size = 13, weight = "medium",
                    color = if mode.selected then "foreground" else "secondaryForeground" } }
        end
        return ui.row{ h = 56, ui.row(row) }
    end,
    commandPaletteBadge = function(_, item)
        return capsule(item)
    end,
    commandPaletteAction = function(_, item)
        local node = { gap = 6, pad = 7, radius = 16, fill = QUIET, hover = HOVER,
            ui.symbol{ name = item.symbol, size = 12, weight = "medium" },
            ui.text{ text = item.title, size = 12, weight = "medium" } }
        if item.shortcut ~= "" then
            node[#node + 1] = ui.text{ text = item.shortcut, size = 10.5, color = "secondaryForeground" }
        end
        return ui.row(node)
    end,
    commandPaletteRow = function(_, item, width)
        local trailing = { gap = 6 }
        if item.hint then
            trailing[#trailing + 1] = ui.text{ text = item.hint, size = 11, color = "secondaryForeground" }
            trailing[#trailing + 1] = capsule({ text = item.hintShortcut or "", tone = "shortcut" })
        end
        for _, entry in item.badges do
            trailing[#trailing + 1] = capsule(entry)
        end
        for _, mark in item.marks do
            trailing[#trailing + 1] = capsule({ text = mark.text, tone = "accent" })
        end
        if item.pinned then
            trailing[#trailing + 1] = ui.symbol{ name = "pin.fill", size = 10, color = "secondaryForeground" }
        end
        local hasIcon = item.kind ~= "menu"
        local reserved = if item.kind == "window" or item.kind == "command" or #trailing > 0 then TRAILING else 0
        local textWidth = math.max(width - 2 * INNER - (if hasIcon then ICON + 10 else 0) - reserved - 8, 1)
        local label = { grow = 1, gap = 1, center = false,
            ui.text{ text = item.title, size = 13, weight = "medium", maxWidth = textWidth } }
        if item.subtitle ~= "" then
            label[#label + 1] = ui.text{ text = item.subtitle, size = 11, color = "secondaryForeground",
                maxWidth = textWidth }
        end
        local body = { w = width, gap = 10, pad = INNER, radius = PILL,
            fill = if item.selected then SELECTED else nil,
            hover = if item.enabled and not item.selected then HOVER else nil,
            opacity = if item.enabled then nil else 0.55,
            ui.box{ w = 4, h = 4, radius = 2, fill = if item.selected then "accent" else nil } }
        if hasIcon then
            body[#body + 1] = icon(item, ICON, ROW_SYMBOL)
        end
        body[#body + 1] = ui.column(label)
        if #trailing > 0 then
            body[#body + 1] = ui.row(trailing)
        end
        return ui.row(body)
    end,
    commandPaletteSection = function(_, item, width)
        return ui.column{ w = width, gap = 0, center = false,
            ui.box{ w = 1, h = 10 },
            ui.row{ gap = 0,
                ui.box{ w = 16, h = 1 },
                ui.text{ text = item.title, size = 11, weight = "medium", color = "secondaryForeground",
                    maxWidth = width - 16 } },
            ui.box{ w = 1, h = 4 } }
    end,
    commandPaletteEmpty = function(_, m, width)
        local pill = { gap = 8, pad = 10, radius = 18, fill = QUIET,
            ui.text{ text = m.emptyText, size = 12.5, color = "secondaryForeground", maxWidth = width - 80, lines = 2 } }
        if m.emptySymbol ~= "" then
            table.insert(pill, 1, ui.symbol{ name = m.emptySymbol, size = 14, color = "secondaryForeground" })
        end
        return ui.column{ w = width, grow = 1, center = true, ui.row(pill) }
    end,
    commandPalettePreview = function(_, _, props)
        props.radius = 24
        props.fill = QUIET
        return ui.column(props)
    end,
    commandPaletteToolbar = function(_, _, props)
        return ui.row(props)
    end,
    commandPaletteChip = function(_, item, kind)
        if item.symbol ~= "" then
            return ui.stack{ w = 26, h = 26, radius = 13, fill = if item.selected then "surface" else nil,
                hover = if item.selected then nil else HOVER,
                ui.symbol{ name = item.symbol, size = 12,
                    color = if item.selected then "foreground" else "secondaryForeground" } }
        end
        return ui.row{ pad = 6, radius = 14,
            fill = if item.selected then (if kind == "chip" then "accent" else "surface") elseif kind == "chip" then QUIET
                else nil,
            hover = if item.selected then nil else HOVER,
            ui.text{ text = item.title, size = 11.5, weight = "medium",
                color = if item.selected and kind == "chip" then "accentForeground" else "foreground" } }
    end,
    commandPaletteCell = function(_, item, width, height)
        return ui.column{ w = width, h = height, gap = 7, pad = 6, radius = 24,
            fill = if item.selected then SELECTED else nil,
            hover = if item.selected then nil else HOVER,
            ui.stack{ w = TILE, h = TILE, radius = 22, fill = QUIET, icon(item, TILE, TILE_SYMBOL) },
            ui.text{ text = item.title, size = 12, weight = "medium", maxWidth = width - 12,
                lines = if item.kind == "file" then 2 else 1 } }
    end,
})
