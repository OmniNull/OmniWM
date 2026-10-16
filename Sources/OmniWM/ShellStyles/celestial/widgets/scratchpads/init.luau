-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

spanIslands = true

local tokens = require("../lib/tokens")

local WHITE = "#FFFFFFFF"
local SHOWN_ICONS = 3

local function line(vertical: boolean, props)
    return vertical and ui.column(props) or ui.row(props)
end

local function spacer(vertical: boolean, length: number)
    return vertical and ui.box{ w = 1, h = length } or ui.box{ w = length, h = 1 }
end

local function countBadge(text: string, height: number, tint: string, fill: string)
    return ui.row{ h = height, radius = height / 2, fill = fill,
        ui.box{ w = 4, h = 1 },
        ui.text{ text = text, font = "sans", size = 10, weight = "bold", color = tint },
        ui.box{ w = 4, h = 1 } }
end

local function notificationBadge(item: BarItem, mode: string, icon: number)
    if mode == "off" or item.badge == "" then
        return nil
    end
    local dy = -math.max(3, icon * 0.16)
    if mode == "dot" then
        local size = math.max(6, icon * 0.36)
        return ui.box{ align = "topLeading", dx = -2, dy = dy, w = size, h = size, radius = size / 2 - 1, fill = "badge",
            border = "surface", borderWidth = 1 }
    end
    local height = math.max(10, icon * 0.6)
    return ui.row{ align = "topLeading", dx = -2, dy = dy, h = height, radius = height / 2 - 1, fill = "badge",
        border = "surface", borderWidth = 1,
        ui.box{ w = 3, h = 1 },
        ui.text{ text = item.badge, font = "sans", size = math.max(8, icon * 0.4), weight = "bold", color = WHITE,
            maxWidth = icon },
        ui.box{ w = 3, h = 1 } }
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

local function pill(scratchpad: BarScratchpad, bar: Bar, inner: number)
    local style = bar.style
    local vertical = style.vertical
    local scale = style.height / 60
    local icon = 24 * scale
    local compact = scratchpad.compact
    local active = (scratchpad.revealed or scratchpad.focused) and style.accents
    local short = compact or vertical
    local hue = style.accentColor ~= nil and "accent" or "tertiaryAccent"
    local container = style.accentColor ~= nil and "accent/0.22" or "tertiaryContainer"
    local onContainer = style.accentColor ~= nil and "accent" or "tertiaryContainerForeground"
    local tint = style.textColor ~= nil and "foreground" or active and onContainer or "secondaryForeground"
    local chip = active and hue .. "/0.3" or "foreground/0.1"
    local node = { key = "scratchpad " .. scratchpad.id, gap = 1, radius = inner / 2, animate = "effects",
        hoverAnimate = 0.12, w = if vertical then inner else nil, h = if vertical then nil else inner,
        fill = style.backgrounds and (active and container or (scratchpad.visible and "highestSurface" or nil)) or nil,
        hover = hue .. "/0.12",
        onClick = "scratchpad toggle " .. scratchpad.id,
        target = "scratchpad " .. scratchpad.id, menu = true,
        help = help(scratchpad, bar),
        spacer(vertical, short and 3 or 7) }
    node[#node + 1] = ui.stack{ w = if short then inner - 6 else nil, h = inner - 6,
        ui.text{ text = if short then initial(scratchpad.name) else scratchpad.name, font = "sans",
            size = tokens.label.medium * scale, weight = "medium", color = tint } }
    node[#node + 1] = spacer(vertical, short and 2 or 4)
    if compact then
        node[#node + 1] = countBadge(tostring(windowCount(scratchpad)), inner - 8, tint, chip)
        node[#node + 1] = spacer(vertical, 2)
    else
        for index, member in ipairs(scratchpad.windows) do
            if index > SHOWN_ICONS then
                node[#node + 1] = countBadge("+" .. tostring(#scratchpad.windows - SHOWN_ICONS), inner - 8, tint, chip)
                break
            end
            node[#node + 1] = ui.stack{ w = icon, h = icon,
                ui.icon{ window = member.id, placeholder = "app.dashed", w = icon, h = icon,
                    opacity = member.focused and 1 or (style.inactive >= 0 and style.inactive or 0.85) },
                notificationBadge(member, bar.badges, icon) }
        end
        node[#node + 1] = spacer(vertical, 3)
    end
    return line(vertical, node)
end

function render(ctx: Context)
    local bar = ctx.data.bar
    local style = bar.style
    if bar.island == "active" or #bar.scratchpads == 0 then
        return ui.row{}
    end
    local scale = style.height / 60
    local capsule = tokens.bar.inner * scale
    local inner = capsule - tokens.padding.small * scale
    local group = { gap = tokens.spacing.extraSmall * scale, radius = capsule / 2, pad = tokens.padding.extraSmall * scale,
        w = if style.vertical then capsule else nil, h = if style.vertical then nil else capsule,
        fill = style.backgrounds and "surface" or nil }
    for _, scratchpad in ipairs(bar.scratchpads) do
        group[#group + 1] = pill(scratchpad, bar, inner)
    end
    return line(style.vertical, group)
end
