-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local icons = require("../lib/icons")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

function render(ctx: Context)
    local level = ctx.data.battery
    if not level then
        return ui.box{ w = 0, h = 0 }
    end
    local charging = ctx.data.charging
    local tint = if level <= 20 and not charging then "error" else "secondaryAccent"
    local style = ctx.data.bar.style
    local vertical = style.vertical
    local scale = style.height / 60
    return surface.pill(style, {
        surface.icon(icons.battery(level / 100, charging), { size = tokens.icon.medium * scale, color = tint, filled = true, animate = "effects" }),
        ui.text{ text = if vertical then tostring(level) else ctx.format.percent(level / 100), font = "sans",
            size = (if vertical then tokens.label.small else tokens.label.large) * scale, weight = "medium", color = tint,
            reserve = if vertical then nil else ctx.format.percent(1) },
    }, { help = omniwm.l10n("Battery") })
end
