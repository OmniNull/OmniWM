-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

function render(ctx: Context)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local locked = style.secureInput
    return ui.stack{ w = size, h = size, radius = math.floor(size * 0.24), fill = locked and "warning" or "accent",
        hoverOpacity = 0.85, onClick = "shell menu", onRightClick = "shell menu",
        help = locked and omniwm.l10n("Secure Input is on: Option shortcuts are paused")
            or omniwm.l10n("Window manager controls"),
        ui.symbol{ name = locked and "omniwm.lock" or "omniwm", size = math.floor(size * 0.6), weight = "semibold",
            color = "accentForeground" } }
end
