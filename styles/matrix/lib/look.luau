-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local legacy = require("./style")

local function text(props)
    if props.color == nil and props.role == "secondary" then
        props.color = "secondaryForeground"
    end
    props.role = nil
    props.style = "caption"
    return ui.text(props)
end

local function toneColor(tone, fallback)
    return if tone == "accent" then "accent"
        elseif tone == "danger" then "error"
        elseif tone == "warning" then "warning"
        else fallback
end

local function tag(badge, color)
    return text{ text = "[" .. string.upper(badge.text) .. "]", size = 10, color = color,
        opacity = if badge.tone == "shortcutMuted" then 0.6 else nil }
end

return require("./skin")({
    base = 40,
    hover = legacy.hover,
    width = legacy.width,
    radius = function()
        return 2
    end,
    text = text,
    bar = legacy.bar,
    panel = function(_, props)
        return legacy.panel(props)
    end,
    group = legacy.group,
    heading = legacy.heading,
    button = legacy.button,
    primaryButton = { w = 36, h = 36, radius = 2, fill = "accent", color = "accentForeground" },
    controlCenterBar = function(ctx)
        local scale = legacy.scale(ctx)
        local item = { hover = legacy.hover,
            ui.symbol{ name = "slider.horizontal.3", size = 14 * scale, color = "accent" } }
        if not ctx.data.bar.style.vertical then
            item[#item + 1] = text{ text = "SYS", size = 12 * scale, color = "accent" }
        end
        return legacy.bar(ctx, item)
    end,
    controlCenterPanel = function(_, props)
        table.insert(props, 1, ui.row{ w = props.w - 28,
            text{ text = "matrix://", size = 11, color = "secondaryForeground", grow = 1 },
            legacy.button("xmark", ui.popout, { help = omniwm.l10n("Close") }) })
        return legacy.panel(props)
    end,
    activeWindowBar = function(ctx, m)
        local scale = legacy.scale(ctx)
        local item = { hover = legacy.hover }
        if m.showIcon then
            item[#item + 1] = ui.icon{ app = m.bundle, w = 18 * scale, h = 18 * scale, placeholder = "app.dashed" }
        end
        if m.showText then
            item[#item + 1] = text{ text = "~/" .. m.app, size = 11 * scale,
                color = "secondaryForeground", maxWidth = m.maxWidth }
        end
        return legacy.bar(ctx, item)
    end,
    clockBar = function(ctx, m)
        if ctx.data.bar.style.vertical then
            return nil
        end
        local scale = legacy.scale(ctx)
        local row = { gap = 8 * scale, hover = legacy.hover }
        if m.showIcon then
            row[#row + 1] = ui.symbol{ name = "calendar", size = 12 * scale }
        end
        if m.showDate then
            row[#row + 1] = text{ text = string.upper(m.date), size = 12 * scale, color = "secondaryForeground" }
            row[#row + 1] = text{ text = "//", size = 12 * scale, color = "accent" }
        end
        row[#row + 1] = text{ text = m.time, size = 12 * scale, weight = "medium", reserve = "00:00 PM" }
        return legacy.bar(ctx, row)
    end,
    commandPaletteSearch = function(_, m, input, width)
        input.style = "caption"
        input.size = 16
        local row = { w = width, h = 56, gap = 8, pad = 18,
            text{ text = ">", size = 16, weight = "semibold", color = "accent" },
            ui.input(input) }
        for _, mode in m.modes do
            if m.expanded and mode.selected then
                row[#row + 1] = text{ text = string.upper(mode.title) .. " //", size = 11, color = "secondaryForeground" }
            end
        end
        return ui.row(row)
    end,
    commandPaletteTabs = function(_, m)
        local row = { gap = 4, h = 56 }
        for index, mode in m.modes do
            row[#row + 1] = ui.stack{ key = "mode-" .. mode.id, w = 24, h = 24, radius = 2,
                fill = if mode.selected then "accent" else nil, border = "border", borderWidth = 1,
                opacity = if mode.enabled then 1 else 0.38,
                hover = if mode.enabled then legacy.hover else nil,
                onClick = if mode.enabled then "palette mode " .. mode.id else nil,
                help = mode.title .. " (" .. mode.shortcut .. ")",
                text{ text = tostring(index), size = 11,
                    color = if mode.selected then "accentForeground" else "secondaryForeground" } }
        end
        return ui.row(row)
    end,
    commandPaletteBadge = function(_, badge)
        return tag(badge, toneColor(badge.tone, "secondaryForeground"))
    end,
    commandPaletteAction = function(_, action)
        return ui.row{ gap = 6, pad = 5, radius = 2, border = "border", borderWidth = 1, hover = legacy.hover,
            text{ text = "$ " .. string.lower(action.title), size = 11, color = "accent" },
            text{ text = action.shortcut, size = 10, color = "secondaryForeground" } }
    end,
    commandPaletteRow = function(_, item, width)
        local selected = item.selected
        local primary = if selected then "accentForeground" else "foreground"
        local secondary = if selected then "accentForeground" else "secondaryForeground"
        local tags = { gap = 6 }
        if item.hint then
            tags[#tags + 1] = text{ text = "[" .. (item.hintShortcut or "") .. "] " .. string.upper(item.hint),
                size = 10, color = secondary }
        end
        for _, badge in item.badges do
            tags[#tags + 1] = tag(badge, if selected then secondary else toneColor(badge.tone, secondary))
        end
        for _, mark in item.marks do
            tags[#tags + 1] = text{ text = "#" .. mark.text, size = 10, color = if selected then primary else "accent" }
        end
        local textWidth = width - 280
        local label = { grow = 1, gap = 1, center = false,
            text{ text = item.title, size = 12, weight = "medium", color = primary, maxWidth = textWidth } }
        if item.subtitle ~= "" then
            label[#label + 1] = text{ text = "~/" .. item.subtitle, size = 10, color = secondary,
                maxWidth = textWidth }
        end
        return ui.row{ w = width, gap = 10, pad = 7, radius = 2,
            fill = if selected then "accent" else nil,
            hover = if selected or not item.enabled then nil else legacy.hover,
            opacity = if item.enabled then nil else 0.55,
            text{ text = if selected then ">" else " ", w = 10, size = 13, weight = "semibold", color = primary },
            if item.icon.symbol then ui.symbol{ name = item.icon.symbol, w = 20, h = 20, size = 14, color = primary }
                else ui.icon{ app = item.icon.app, pid = item.icon.pid, w = 20, h = 20, placeholder = "app.dashed" },
            ui.column(label),
            ui.row(tags) }
    end,
    commandPaletteSection = function(_, item, width)
        return ui.column{ w = width, gap = 0, center = false,
            ui.box{ w = 1, h = 10 },
            ui.row{ gap = 0,
                ui.box{ w = 7, h = 1 },
                text{ text = "// " .. string.upper(item.title), size = 10, weight = "semibold", color = "accent",
                    maxWidth = width - 14 } },
            ui.box{ w = 1, h = 2 } }
    end,
    commandPaletteEmpty = function(_, m, width)
        return ui.column{ w = width, grow = 1, gap = 6, center = true,
            text{ text = "> no match", size = 13, color = "accent" },
            text{ text = m.emptyText, size = 11, color = "secondaryForeground", maxWidth = width - 40, lines = 2 } }
    end,
    workspaceMarker = function(ctx, workspace, style, m)
        if m.indicator ~= "numbers" or (m.compact and not style.labels) then
            return nil
        end
        local size = math.max(16, math.round(m.icon * 0.95))
        local pad = if utf8.len(workspace.name) <= 1 then size * 0.32 else 5
        return ui.row{ h = size + 8, radius = 2,
            fill = if workspace.focused then "accent" else "surface/0.65",
            ui.box{ w = pad, h = 1 },
            text{ text = workspace.name, size = 13 * style.height / 40, weight = "medium",
                color = if workspace.focused then "accentForeground" else "secondaryForeground",
                maxWidth = if m.vertical then m.item - 10 else nil },
            ui.box{ w = pad, h = 1 } }
    end,
})
