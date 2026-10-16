-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local performance = require("../lib/performance")
local status = require("../lib/status")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

local function meter(ctx: Context, icon: string, value: number?, tint: string, vertical: boolean)
    local scale = ctx.data.bar.style.height / 60
    local text = if value then ctx.format.percent(value / 100) else "--"
    local parts = {
        surface.icon(icon, { size = tokens.icon.small * scale, color = tint }),
        ui.text{ text = if vertical and value then tostring(math.round(value)) else text, font = "sans",
            size = (if vertical then tokens.label.small else tokens.label.large) * scale, weight = "medium",
            color = ctx.data.bar.style.textColor ~= nil and "foreground" or tint,
            reserve = if vertical then nil else ctx.format.percent(1) },
    }
    parts.gap = tokens.spacing.extraSmall * scale
    return if vertical then ui.column(parts) else ui.row(parts)
end

function render(ctx: Context)
    local style = ctx.data.bar.style
    local vertical = style.vertical
    return surface.pill(style, {
        meter(ctx, "memory", ctx.data.cpu, "accent", vertical),
        meter(ctx, "memory_alt", ctx.data.memory, "tertiaryAccent", vertical),
    }, { gap = tokens.spacing.medium * style.height / 60, hover = status.hover, onClick = ui.popout,
        help = omniwm.l10n("Performance") })
end

function popout(ctx: Context)
    return status.pane(performance, ctx)
end
