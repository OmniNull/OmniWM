-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local tokens = require("../lib/tokens")

local TINT = "accent"

function render(ctx: Context)
    local data = ctx.data
    if data.app == "" then
        return ui.box{ w = 0, h = 0 }
    end
    local style = data.bar.style
    local scale = style.height / 60
    local settings = data.settings or {}
    local length = tonumber(settings.maxWidth) or 320
    local title = data.title ~= "" and data.title or data.app
    local icon = ui.icon{ app = data.bundle, w = tokens.icon.medium * scale, h = tokens.icon.medium * scale, placeholder = "app.dashed" }
    local label = ui.text{ text = title, font = "sans", size = tokens.body.small * scale,
        color = style.textColor ~= nil and "foreground" or TINT, maxWidth = length,
        rotate = if style.vertical then 90 else nil, animate = "effects" }
    local props = { gap = tokens.spacing.small * scale, onClick = "open-command-palette windows", hover = TINT .. "/0.08",
        radius = tokens.rounding.large * scale, pad = tokens.padding.extraSmall * scale,
        help = if data.title ~= "" then data.app .. " — " .. data.title else data.app, icon, label }
    if style.vertical then
        props.w = tokens.bar.inner * scale
        return ui.column(props)
    end
    return ui.row(props)
end
