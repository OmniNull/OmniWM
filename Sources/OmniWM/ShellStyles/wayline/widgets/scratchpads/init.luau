-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

spanIslands = true

local HUE = "purple"
local SHOWN_ICONS = 3

local function line(vertical: boolean, props)
    return vertical and ui.column(props) or ui.row(props)
end

local function spacer(vertical: boolean, length: number)
    return vertical and ui.box{ w = 1, h = length } or ui.box{ w = length, h = 1 }
end

local function countBadge(text: string)
    return ui.row{ h = 14, radius = 7, fill = "foreground/0.08",
        ui.box{ w = 4, h = 1 },
        ui.text{ text = text, style = "mono", size = 9, weight = "bold", color = "secondaryForeground" },
        ui.box{ w = 4, h = 1 } }
end

local function notificationBadge(item: BarItem, mode: string)
    if mode == "off" or item.badge == "" then
        return nil
    end
    if mode == "dot" then
        return ui.box{ align = "topTrailing", dx = 1, dy = -1, w = 7, h = 7, radius = 3.5, fill = "badge",
            border = "elevatedSurface", borderWidth = 1 }
    end
    return ui.row{ align = "topTrailing", dx = 2, dy = -3, h = 11, radius = 5.5, fill = "badge",
        ui.box{ w = 2.5, h = 1 },
        ui.text{ text = item.badge, style = "mono", size = 8, weight = "bold", color = "background", maxWidth = 16 },
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

local function block(size: number, radius: number, vertical: boolean)
    return ui.stack{ w = size, h = size,
        ui.box{ w = size, h = size, radius = radius, fill = HUE },
        ui.box{ align = vertical and "bottom" or "trailing", w = vertical and size or radius,
            h = vertical and radius or size, fill = HUE },
        ui.symbol{ name = "tray.fill", size = math.floor(size * 0.5), weight = "semibold", color = "accentForeground" } }
end

local function segment(scratchpad: BarScratchpad, bar: Bar, size: number, radius: number)
    local style = bar.style
    local vertical = style.vertical
    local scale = style.height / 40
    local item = 30 * scale
    local icon = 24 * scale
    local compact = scratchpad.compact
    local active = (scratchpad.revealed or scratchpad.focused) and style.accents
    local hue = style.accentColor ~= nil and "accent" or HUE
    local color = style.textColor ~= nil and "foreground" or active and hue
        or (scratchpad.visible and "foreground" or "secondaryForeground")
    local node = { key = "scratchpad " .. scratchpad.id, gap = 2, radius = radius - 1, animate = 0.15, hoverAnimate = 0.12,
        w = if vertical then item else nil, h = if vertical then nil else item,
        fill = (active and style.backgrounds) and (hue .. "/0.22") or nil,
        hover = (not active) and (hue .. "/0.15") or nil,
        border = (scratchpad.focused and not style.accents) and "foreground/0.4" or nil, borderWidth = 1,
        onClick = "scratchpad toggle " .. scratchpad.id,
        target = "scratchpad " .. scratchpad.id, menu = true,
        help = help(scratchpad, bar),
        spacer(vertical, 4) }
    local short = compact or vertical
    node[#node + 1] = ui.text{ text = if short then initial(scratchpad.name) else scratchpad.name,
        size = 14 * scale, weight = "bold", color = color }
    if not scratchpad.visible and not active then
        node[#node + 1] = ui.symbol{ name = "eye.slash", size = 8, weight = "bold", color = "mutedForeground" }
    end
    if compact then
        node[#node + 1] = countBadge(tostring(windowCount(scratchpad)))
    else
        node[#node + 1] = spacer(vertical, 0)
        for index, member in ipairs(scratchpad.windows) do
            if index > SHOWN_ICONS then
                node[#node + 1] = countBadge("+" .. tostring(#scratchpad.windows - SHOWN_ICONS))
                break
            end
            node[#node + 1] = ui.stack{ w = icon, h = icon,
                ui.icon{ window = member.id, placeholder = "app.dashed", w = icon, h = icon,
                    opacity = member.focused and 1 or (style.inactive >= 0 and style.inactive
                        or (scratchpad.visible and 0.9 or 0.6)) },
                notificationBadge(member, bar.badges) }
        end
    end
    node[#node + 1] = spacer(vertical, 4)
    return line(vertical, node)
end

function render(ctx: Context)
    local bar = ctx.data.bar
    if bar.island == "active" or #bar.scratchpads == 0 then
        return ui.row{}
    end
    local style = bar.style
    local size = 32 * style.height / 40
    local radius = math.floor(size * 0.24)
    local vertical = style.vertical
    local items = { gap = 2, radius = radius, fill = style.backgrounds and "elevatedSurface" or nil,
        w = if vertical then size else nil, h = if vertical then nil else size,
        block(size, radius, vertical), spacer(vertical, 0) }
    for _, scratchpad in ipairs(bar.scratchpads) do
        items[#items + 1] = segment(scratchpad, bar, size, radius)
    end
    items[#items + 1] = spacer(vertical, 0)
    return line(vertical, items)
end
