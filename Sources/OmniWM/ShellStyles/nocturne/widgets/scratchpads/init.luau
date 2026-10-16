-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

spanIslands = true

local SHOWN_ICONS = 2

local function line(vertical: boolean, props)
    return vertical and ui.column(props) or ui.row(props)
end

local function spacer(vertical: boolean, length: number)
    return vertical and ui.box{ w = 1, h = length } or ui.box{ w = length, h = 1 }
end

local function countPill(text: string, size: number)
    return ui.row{ h = size, radius = size / 2, fill = "elevatedSurface",
        ui.box{ w = 4, h = 1 },
        ui.text{ text = text, style = "mono", size = size - 6, weight = "bold", color = "foreground" },
        ui.box{ w = 4, h = 1 } }
end

local function notificationBadge(item: BarItem, mode: string, icon: number)
    if mode == "off" or item.badge == "" then
        return nil
    end
    if mode == "dot" then
        return ui.box{ align = "topTrailing", dx = 1, dy = -1, w = 7, h = 7, radius = 3.5, fill = "badge",
            border = "surface", borderWidth = 1 }
    end
    local size = math.max(11, icon * 0.55)
    return ui.row{ align = "topTrailing", dx = 3, dy = -2, h = size, radius = size / 2, fill = "badge",
        border = "surface", borderWidth = 1,
        ui.box{ w = 2.5, h = 1 },
        ui.text{ text = item.badge, style = "mono", size = size - 3, weight = "bold", color = "background",
            maxWidth = icon },
        ui.box{ w = 2.5, h = 1 } }
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

local function chip(scratchpad: BarScratchpad, style: BarStyle, size: number, short: boolean)
    local active = (scratchpad.revealed or scratchpad.focused) and style.accents
    local fill, color
    if active then
        fill, color = "accent", "accentForeground"
    elseif scratchpad.visible then
        fill, color = "blue/0.2", style.textColor ~= nil and "foreground" or "blue"
    else
        fill, color = "foreground/0.07", style.textColor ~= nil and "foreground" or "mutedForeground"
    end
    if not style.backgrounds and not active then
        fill = nil
    end
    local label = ui.text{ text = short and initial(scratchpad.name) or scratchpad.name,
        size = 14 * style.height / 40, weight = "bold", color = style.textColor ~= nil and "foreground" or color }
    if short then
        return ui.stack{ w = size, h = size, radius = size / 2, fill = fill, label }
    end
    return ui.row{ h = size, gap = 4, radius = size / 2, fill = fill,
        ui.box{ w = 5, h = 1 },
        ui.symbol{ name = "tray.fill", size = 9, weight = "bold", color = color },
        label,
        ui.box{ w = 6, h = 1 } }
end

local function capsule(scratchpad: BarScratchpad, bar: Bar)
    local style = bar.style
    local vertical = style.vertical
    local scale = style.height / 40
    local size = 32 * scale
    local icon = 24 * scale
    local compact = scratchpad.compact
    local node = { key = "scratchpad " .. scratchpad.id, gap = 3, radius = size / 2 - 1, animate = 0.15,
        hoverAnimate = 0.12, w = if vertical then size else nil, h = if vertical then nil else size,
        hoverScale = 1.03, fill = style.backgrounds and "surface" or nil, hover = "focus/0.14",
        border = style.backgrounds and "border/0.6" or nil, borderWidth = 1,
        onClick = "scratchpad toggle " .. scratchpad.id,
        target = "scratchpad " .. scratchpad.id, menu = true,
        help = help(scratchpad, bar),
        spacer(vertical, 1),
        chip(scratchpad, style, 24 * scale, compact or vertical) }
    if compact then
        node[#node + 1] = countPill(tostring(windowCount(scratchpad)), size - 10)
    else
        for index, member in ipairs(scratchpad.windows) do
            if index > SHOWN_ICONS then
                node[#node + 1] = countPill("+" .. tostring(#scratchpad.windows - SHOWN_ICONS), size - 10)
                break
            end
            node[#node + 1] = ui.stack{ w = icon + 3 * scale, h = icon + 3 * scale,
                ui.icon{ window = member.id, placeholder = "app.dashed", w = icon, h = icon,
                    opacity = member.focused and 1 or (style.inactive >= 0 and style.inactive or 0.82) },
                notificationBadge(member, bar.badges, icon) }
        end
    end
    node[#node + 1] = spacer(vertical, compact and 3 or 1)
    return line(vertical, node)
end

function render(ctx: Context)
    local bar = ctx.data.bar
    if bar.island == "active" then
        return ui.row{}
    end
    local items = { gap = 6 }
    for _, scratchpad in ipairs(bar.scratchpads) do
        items[#items + 1] = capsule(scratchpad, bar)
    end
    return line(bar.style.vertical, items)
end
