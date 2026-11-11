-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local legacy = require("./style")

local ICON = 28
local TRAILING = 200
local INNER = 8
local TILE = 75
local ROW_SYMBOL = 19
local TILE_SYMBOL = 34

local function petal(item)
    return ui.row{ pad = 4, radius = 9,
        fill = if item.tone == "accent" then "accent/0.14" else "accent/0.06",
        opacity = if item.tone == "shortcutMuted" then 0.6 else nil,
        ui.text{ text = item.text, size = 10.5, weight = "medium",
            color = if item.tone == "accent" then "accent" elseif item.tone == "danger" then "error"
                elseif item.tone == "warning" then "warning" else "secondaryForeground" } }
end

local function icon(item, size, glyph, color)
    return if item.icon.bitmap then ui.image{ image = item.icon.bitmap, w = size, h = size }
        elseif item.icon.symbol then ui.stack{ w = size, h = size,
            ui.symbol{ name = item.icon.symbol, size = glyph, color = color } }
        else ui.icon{ app = item.icon.app, pid = item.icon.pid, w = size, h = size, placeholder = "app.fill" }
end

return require("./skin")({
    base = 40,
    hover = legacy.hover,
    width = legacy.width,
    bar = legacy.bar,
    panel = function(_, props)
        return legacy.panel(props)
    end,
    group = legacy.group,
    heading = legacy.heading,
    button = legacy.button,
    primaryButton = { w = 36, h = 36, radius = 18, fill = "accent", color = "accentForeground" },
    commandPalettePanel = function(_, props)
        props.radius = 22
        props.fill = "background"
        props.border = "border/0.8"
        props.borderWidth = 1
        props.center = false
        return ui.column(props)
    end,
    commandPaletteSearch = function(_, m, input, width)
        local row = { w = width, h = 56, gap = 10, pad = 20, legacy.blossom(18), ui.input(input) }
        if m.browseModes then
            row[#row + 1] = legacy.button("ellipsis", "palette menu modes", { help = omniwm.l10n("Browse modes") })
        end
        if m.query ~= "" then
            row[#row + 1] = legacy.button("xmark", "palette clear", { w = 22, h = 22, radius = 11,
                help = omniwm.l10n("Clear") })
        end
        return ui.row(row)
    end,
    commandPaletteTabs = function(_, m)
        local row = { gap = 6, h = 56 }
        for _, mode in m.modes do
            row[#row + 1] = ui.stack{ key = "mode-" .. mode.id, w = 34, h = 34, radius = 12,
                fill = if mode.selected then "accent/0.16" else "surface/0.72",
                border = if mode.selected then "accent/0.45" else "border/0.45", borderWidth = 1,
                opacity = if mode.enabled then 1 else 0.38,
                hover = if mode.enabled then legacy.hover else nil,
                onClick = if mode.enabled then "palette mode " .. mode.id else nil,
                help = mode.title .. " (" .. mode.shortcut .. ")",
                ui.symbol{ name = mode.symbol, size = 14, weight = "medium",
                    color = if mode.selected then "accent" else "secondaryForeground" } }
        end
        return ui.row(row)
    end,
    commandPaletteBadge = function(_, item)
        return petal(item)
    end,
    commandPaletteAction = function(_, item)
        local node = { gap = 6, pad = 6, radius = 12, fill = "surface/0.72", border = "border/0.45", borderWidth = 1,
            hover = legacy.hover,
            ui.symbol{ name = item.symbol, size = 12, weight = "medium", color = "accent" },
            ui.text{ text = item.title, size = 12, weight = "medium" } }
        if item.shortcut ~= "" then
            node[#node + 1] = ui.text{ text = item.shortcut, size = 10.5, color = "secondaryForeground" }
        end
        return ui.row(node)
    end,
    commandPaletteRow = function(_, item, width)
        local trailing = { gap = 6 }
        if item.hint then
            trailing[#trailing + 1] = ui.text{ text = item.hint, size = 11, weight = "medium", color = "accent" }
            trailing[#trailing + 1] = petal({ text = item.hintShortcut or "", tone = "accent" })
        end
        for _, entry in item.badges do
            trailing[#trailing + 1] = petal(entry)
        end
        for _, mark in item.marks do
            trailing[#trailing + 1] = petal({ text = mark.text, tone = "accent" })
        end
        if item.pinned then
            trailing[#trailing + 1] = legacy.blossom(11)
        end
        local hasIcon = item.kind ~= "menu"
        local reserved = if item.kind == "window" or item.kind == "command" or #trailing > 0 then TRAILING else 0
        local textWidth = math.max(width - 2 * INNER - (if hasIcon then ICON + 10 else 0) - reserved, 1)
        local label = { grow = 1, gap = 2, center = false,
            ui.text{ text = item.title, size = 13, weight = "medium", maxWidth = textWidth } }
        if item.subtitle ~= "" then
            label[#label + 1] = ui.text{ text = item.subtitle, size = 11, color = "secondaryForeground",
                maxWidth = textWidth }
        end
        local body = { w = width, gap = 10, pad = INNER, radius = 12,
            fill = if item.selected then "accent/0.12" else nil,
            border = if item.selected then "accent/0.35" else nil,
            borderWidth = if item.selected then 1 else nil,
            hover = if item.enabled and not item.selected then legacy.hover else nil,
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
                ui.box{ w = 8, h = 1 },
                legacy.blossom(12),
                ui.text{ text = item.title, size = 11, weight = "semibold", color = "accent", maxWidth = width - 34 } },
            ui.box{ w = 1, h = 4 } }
    end,
    commandPaletteEmpty = function(_, m, width)
        return ui.column{ w = width, grow = 1, gap = 10, center = true,
            legacy.blossom(34),
            ui.text{ text = m.emptyText, size = 13, color = "secondaryForeground", maxWidth = width - 40, lines = 2 } }
    end,
    commandPalettePreview = function(_, _, props)
        props.radius = 16
        props.fill = "surface/0.72"
        props.border = "border/0.45"
        props.borderWidth = 1
        return ui.column(props)
    end,
    commandPaletteToolbar = function(_, _, props)
        return ui.row(props)
    end,
    commandPaletteChip = function(_, item, kind)
        if item.symbol ~= "" then
            return ui.stack{ w = 26, h = 26, radius = 9, fill = if item.selected then "accent/0.16" else nil,
                hover = legacy.hover,
                ui.symbol{ name = item.symbol, size = 12,
                    color = if item.selected then "accent" else "secondaryForeground" } }
        end
        return ui.row{ pad = 6, radius = 12, hover = legacy.hover,
            fill = if item.selected then "accent" elseif kind == "chip" then "surface/0.72" else nil,
            border = if kind == "chip" and not item.selected then "border/0.45" else nil,
            borderWidth = if kind == "chip" and not item.selected then 1 else nil,
            ui.text{ text = item.title, size = 11.5, weight = "medium",
                color = if item.selected then "accentForeground" else "foreground" } }
    end,
    commandPaletteCell = function(_, item, width, height)
        return ui.column{ w = width, h = height, gap = 7, pad = 6, radius = 16,
            fill = if item.selected then "accent/0.12" else nil,
            border = if item.selected then "accent/0.35" else nil,
            borderWidth = if item.selected then 1 else nil,
            hover = if item.selected then nil else legacy.hover,
            ui.stack{ w = TILE, h = TILE, radius = 18, fill = "surface/0.72", border = "border/0.45", borderWidth = 1,
                icon(item, TILE, TILE_SYMBOL, if item.selected then "accent" else "secondaryForeground") },
            ui.text{ text = item.title, size = 12, weight = "medium", maxWidth = width - 12,
                lines = if item.kind == "file" then 2 else 1 } }
    end,
    workspaceMarker = function(_, workspace, style, m)
        if m.indicator ~= "numbers" or (m.compact and not style.labels) then
            return nil
        end
        local size = math.max(16, math.round(m.icon * 0.95))
        local pad = if utf8.len(workspace.name) <= 1 then size * 0.32 else 5
        return ui.row{ h = size + 8, radius = (size + 8) / 2,
            fill = if workspace.focused then "accent" else "accent/0.07",
            ui.box{ w = pad, h = 1 },
            ui.text{ text = workspace.name, size = 13 * style.height / 40, weight = "medium",
                color = if workspace.focused then "accentForeground" else "secondaryForeground",
                maxWidth = if m.vertical then m.item - 10 else nil },
            ui.box{ w = pad, h = 1 } }
    end,
})
