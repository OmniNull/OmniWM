-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local panel = require("./panel")
local presentation = require("./notification-presentation")

return presentation({
    scale = function(ctx) return ctx.data.bar.style.height / 40 end,
    hover = "focus/0.14",
    buttonRadius = 13,
    bar = function(ctx, props)
        local style = ctx.data.bar.style
        local size = style.height * 0.8
        props.radius = size / 2 - 1
        props.fill = if style.backgrounds then "surface" else nil
        props.border = if style.backgrounds then "border/0.6" else nil
        props.borderWidth = 1
        props.hover = "focus/0.14"
        props.pad = 5
        if style.vertical then
            props.w = size
            return ui.column(props)
        end
        props.h = size
        return ui.row(props)
    end,
    group = function(props)
        props.radius = 14
        props.fill = "surface"
        props.border = "border"
        props.borderWidth = 1
        return ui.column(props)
    end,
    panel = function(ctx, props)
        return panel(ctx.data.bar.style, props.w + 2, ui.column(props))
    end,
})
