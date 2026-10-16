-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local system = require("../lib/style")

spanIslands = true

local WHITE = "#FFFFFFFF"
local SHOWN_ICONS = 3

local function line(vertical: boolean, props)
    return vertical and ui.column(props) or ui.row(props)
end

local function spacer(vertical: boolean, length: number)
    return vertical and ui.box{ w = 1, h = length } or ui.box{ w = length, h = 1 }
end

local function countBadge(text: string, icon: number)
    local size = math.max(12, icon * 0.55)
    return ui.row{ h = size, radius = size / 2, fill = "surface",
        ui.box{ w = 3, h = 1 },
        ui.text{ text = text, style = "mono", size = 10, weight = "semibold",
            color = "foreground" },
        ui.box{ w = 3, h = 1 } }
end

local function notificationBadge(item: BarItem, mode: string, icon: number)
    if mode == "off" or item.badge == "" then
        return nil
    end
    local dy = -math.max(2, icon * 0.12)
    if mode == "dot" then
        local size = math.max(6, icon * 0.35)
        return ui.box{ align = "topLeading", dy = dy, w = size, h = size, radius = size / 2, fill = "badge" }
    end
    local inset = icon < 20 and 1 or 3
    local height = math.max(12, icon * 0.55)
    return ui.row{ align = "topLeading", dy = dy, h = height, radius = height / 2, fill = "badge",
        ui.box{ w = inset, h = 1 },
        ui.text{ text = item.badge, style = "mono", size = math.max(10, icon * 0.35), weight = "semibold",
            color = WHITE, maxWidth = icon - inset * 2 },
        ui.box{ w = inset, h = 1 } }
end

local function initial(name: string): string
    local next = utf8.offset(name, 2)
    return if next then string.sub(name, 1, next - 1) else name
end

local function windowCount(scratchpad: BarScratchpad): number
    local count = 0
    for _, item in ipairs(scratchpad.windows) do
        count += item.count
    end
    return count
end

local function help(scratchpad: BarScratchpad, bar: Bar): string
    local count = windowCount(scratchpad)
    local summary = count == 1 and scratchpad.windows[1].name or omniwm.l10n("%lld windows", count)
    local text = scratchpad.visible and omniwm.l10n("Scratchpad %@: %@, visible", scratchpad.name, summary)
        or omniwm.l10n("Scratchpad %@: %@, hidden", scratchpad.name, summary)
    if bar.badges ~= "off" and not scratchpad.compact then
        for index, item in ipairs(scratchpad.windows) do
            if index > SHOWN_ICONS then
                break
            end
            if item.badge ~= "" then
                text ..= ", " .. omniwm.l10n("%@ notification badge: %@", item.name, item.badge)
            end
        end
    end
    return text
end

local function pill(scratchpad: BarScratchpad, bar: Bar)
    local style = bar.style
    local vertical = style.vertical
    local item = math.max(16, style.height - 4)
    local icon = 18 * style.height / 40
    local compact = scratchpad.compact
    local accent = (scratchpad.revealed or scratchpad.focused) and style.accents
    local color = accent and "accent" or (style.textColor ~= nil and "foreground" or "secondaryForeground")
    local gap = compact and 3 or 5
    local padding = compact and 5 or 8
    local node = { key = "scratchpad " .. scratchpad.id, gap = gap, radius = 6 * style.height / 40,
        animate = 0.15, hoverAnimate = 0.12, hover = system.hover,
        w = if vertical then item else nil, h = if vertical then nil else item,
        scale = scratchpad.focused and 1.04 or 1, hoverScale = scratchpad.focused and 1.04 or 1.03,
        fill = scratchpad.focused and "foreground/0.1" or (style.backgrounds and "foreground/0.04" or nil),
        onClick = "scratchpad toggle " .. scratchpad.id,
        target = "scratchpad " .. scratchpad.id, menu = true,
        help = help(scratchpad, bar),
        spacer(vertical, padding - gap) }
    if not compact then
        node[#node + 1] = ui.symbol{ name = "tray.fill", size = math.max(10, icon * 0.64), weight = "semibold", color = color }
    end
    local short = compact or vertical
    node[#node + 1] = ui.text{ text = if short then initial(scratchpad.name) else scratchpad.name,
        size = 13 * style.height / 40, weight = "medium", color = color }
    if compact then
        node[#node + 1] = countBadge(tostring(windowCount(scratchpad)), icon)
    else
        for index, member in ipairs(scratchpad.windows) do
            if index > SHOWN_ICONS then
                node[#node + 1] = countBadge("+" .. tostring(#scratchpad.windows - SHOWN_ICONS), icon)
                break
            end
            node[#node + 1] = ui.stack{ w = icon, h = icon,
                ui.icon{ window = member.id, placeholder = "app.dashed", w = icon, h = icon,
                    opacity = member.focused and 1 or (style.inactive >= 0 and style.inactive or 0.82) },
                notificationBadge(member, bar.badges, icon) }
        end
    end
    node[#node + 1] = spacer(vertical, padding - gap)
    return line(vertical, node)
end

function render(ctx: Context)
    local bar = ctx.data.bar
    if bar.island == "active" then
        return ui.row{}
    end
    local items = { gap = 8 }
    for _, scratchpad in ipairs(bar.scratchpads) do
        items[#items + 1] = pill(scratchpad, bar)
    end
    return line(bar.style.vertical, items)
end
