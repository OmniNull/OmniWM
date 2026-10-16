-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local icons = require("../lib/icons")
local status = require("../lib/status")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

function render(ctx: Context)
    local volume = ctx.data.volume
    if not volume then
        return ui.box{ w = 0, h = 0 }
    end
    local tint = if ctx.data.muted then "mutedForeground" else "secondaryAccent"
    local style = ctx.data.bar.style
    local vertical = style.vertical
    local scale = style.height / 60
    return surface.pill(style, {
        surface.icon(icons.volume(volume / 100, ctx.data.muted), { size = tokens.icon.medium * scale, color = tint, filled = true, animate = "effects" }),
        ui.text{ text = if vertical then tostring(volume) else ctx.format.percent(volume / 100), font = "sans",
            size = (if vertical then tokens.label.small else tokens.label.large) * scale, weight = "medium", color = tint,
            reserve = if vertical then nil else ctx.format.percent(1) },
    }, { hover = status.hover, onClick = ui.popout, onScroll = status.scroll, help = omniwm.l10n("Volume") })
end

function popout(ctx: Context)
    return status.audio(ctx)
end
