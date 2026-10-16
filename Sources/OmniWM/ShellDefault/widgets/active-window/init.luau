-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local function chip(style: BarStyle, props, square: boolean)
    local size = math.max(16, style.height - 4)
    local capsule = style.transparent and style.backgrounds
    props.hover = if props.onClick then "foreground/0.12" else nil
    props.radius = if capsule then size / 2 else 4
    if capsule then
        props.fill = "surface"
        props.border = "border"
        props.borderWidth = 0.5
    end
    if square then
        props.w = size
        props.h = size
        return ui.stack(props)
    end
    if not capsule then
        props.pad = 2
        return ui.row(props)
    end
    local edge = math.round(size * 0.3)
    props.h = size
    table.insert(props, 1, ui.box{ w = edge - 4, h = 1 })
    props[#props + 1] = ui.box{ w = edge, h = 1 }
    return ui.row(props)
end

function render(ctx: Context)
    local data = ctx.data
    if data.app == "" then
        return ui.box{ w = 0, h = 0 }
    end
    local style = data.bar.style
    local settings = data.settings or {}
    local display = settings.display or "icon_and_text"
    local size = math.max(16, style.height - 4)
    local icon = math.max(14, size - 8)
    local text = display ~= "icon_only" and not style.vertical
    local item = { gap = 7, onClick = "open-command-palette windows",
        help = if data.title ~= "" then data.app .. " — " .. data.title else data.app }
    if display ~= "text_only" or not text then
        item[#item + 1] = ui.icon{ app = data.bundle, w = icon, h = icon, placeholder = "app.dashed" }
    end
    if text then
        item[#item + 1] = ui.text{ text = if data.title ~= "" then data.title else data.app,
            weight = "medium", maxWidth = tonumber(settings.maxWidth) or 260 }
    end
    return chip(style, item, not text)
end
