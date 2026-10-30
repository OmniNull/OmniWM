-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local surface = require("./surface")
local status = require("./status")
local tokens = require("./tokens")
local presentation = require("./notification-presentation")

return presentation({
    scale = function(ctx) return ctx.data.bar.style.height / 60 end,
    icon = function(issue, size)
        return surface.icon(if issue then "notifications_active" else "notifications", {
            size = size * tokens.icon.medium / 14, color = "secondaryAccent", filled = true })
    end,
    text = function(props)
        props.font = "sans"
        props.size = props.size or (if props.style == "small" then tokens.label.small
            elseif props.style == "bold" then tokens.title.small else tokens.body.small)
        props.weight = props.weight or (if props.style == "bold" then "medium" else nil)
        props.style = nil
        return ui.text(props)
    end,
    bar = function(ctx, props)
        local children = {}
        for index = 1, #props do children[#children + 1] = props[index] end
        return surface.pill(ctx.data.bar.style, children, { onClick = props.onClick, help = props.help, hover = status.hover })
    end,
    hover = "secondaryContainerForeground/0.08",
    buttonRadius = 20,
    buttonFill = "secondaryContainer",
    buttonForeground = "secondaryContainerForeground",
    group = function(props)
        props.radius = tokens.rounding.large
        props.fill = "surface"
        return ui.column(props)
    end,
    panel = function(_, props)
        return status.panel(props.w + 2 * tokens.padding.large, { ui.column(props) })
    end,
})
