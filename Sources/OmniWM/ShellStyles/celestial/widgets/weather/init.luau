-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local icons = require("../lib/icons")
local status = require("../lib/status")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")
local weathertab = require("../lib/weathertab")

function render(ctx: Context)
    local weather = ctx.data.weather
    if not weather then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local vertical = style.vertical
    local scale = style.height / 60
    return surface.pill(style, {
        surface.icon(icons.weather(weather.code, weather.day), { size = tokens.icon.medium * scale, color = "secondaryAccent" }),
        ui.text{ text = string.format("%d°", math.round(weather.temp)), font = "sans",
            size = (if vertical then tokens.label.medium else tokens.label.large) * scale, weight = "medium", color = "accent" },
    }, { hover = status.hover, onClick = ui.popout, help = weather.condition })
end

function popout(ctx: Context)
    return status.pane(weathertab, ctx)
end
