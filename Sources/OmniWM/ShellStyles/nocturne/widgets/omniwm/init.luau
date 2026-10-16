-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

function render(ctx: Context)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local icon = 24 * scale
    local locked = style.secureInput
    local filled = style.backgrounds
    return ui.stack{ w = size, h = size, radius = size / 2, fill = filled and "accent" or nil, hoverScale = 1.06,
        onClick = "shell menu", onRightClick = "shell menu",
        help = locked and omniwm.l10n("Secure Input is on: Option shortcuts are paused")
            or omniwm.l10n("Window manager controls"),
        ui.symbol{ name = locked and "omniwm.lock" or "omniwm", size = icon, w = icon, h = icon,
            color = filled and "accentForeground" or "accent" } }
end
