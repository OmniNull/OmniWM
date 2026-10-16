-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local tokens = require("./tokens")

local function icon(name: string, props: { [string]: any }?)
    local element = props or {}
    element.text = name
    element.font = "symbols"
    element.size = element.size or tokens.icon.medium
    element.color = element.color or "foreground"
    return ui.text(element)
end

local function text(value: string, scale: { [string]: number }, size: string, props: { [string]: any }?)
    local element = props or {}
    element.text = value
    element.font = element.font or "sans"
    element.size = scale[size]
    element.color = element.color or "foreground"
    return ui.text(element)
end

local function card(props: { [string]: any })
    props.fill = props.fill or "surface"
    props.radius = props.radius or tokens.rounding.large
    return ui.stack(props)
end

export type ButtonKind = "filled" | "tonal" | "text"

local colors = {
    filled = { fill = "accent", text = "accentForeground" },
    tonal = { fill = "secondaryContainer", text = "secondaryContainerForeground" },
    text = { fill = nil, text = "secondaryForeground" },
}

local function button(name: string, kind: ButtonKind, props: { [string]: any })
    local palette = colors[kind]
    local glyph = props.glyph or tokens.icon.medium
    local size = props.size or glyph + 2 * (kind == "text" and tokens.padding.extraSmall / 2 or tokens.padding.small)
    props.glyph = nil
    props.size = nil
    props.w = props.w or size
    props.h = size
    props.radius = props.radius or size / 2
    props.fill = props.fill or palette.fill
    props.hover = props.hover or palette.text .. "/0.08"
    props.animate = props.animate or "effects"
    props[#props + 1] = icon(name, { size = glyph, color = props.color or palette.text, filled = props.filled ~= false })
    props.color = nil
    props.filled = nil
    return ui.stack(props)
end

local function pill(style: BarStyle, children: { any }, props: { [string]: any }?)
    local element = props or {}
    local vertical = style.vertical
    local scale = style.height / 60
    element.gap = element.gap or tokens.spacing.medium / 2 * scale
    element.radius = tokens.bar.inner / 2 * scale
    element.fill = style.backgrounds and (element.fill or "surface") or nil
    local edge = tokens.padding.medium * scale - element.gap
    local function spacer()
        return if vertical then ui.box{ w = 1, h = edge } else ui.box{ w = edge, h = 1 }
    end
    element[1] = spacer()
    for _, child in children do
        element[#element + 1] = child
    end
    element[#element + 1] = spacer()
    if vertical then
        element.w = tokens.bar.inner * scale
        return ui.column(element)
    end
    element.h = tokens.bar.inner * scale
    return ui.row(element)
end

return table.freeze({
    icon = icon,
    text = text,
    card = card,
    button = button,
    pill = pill,
})
