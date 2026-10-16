-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local tokens = require("../lib/tokens")

function render(ctx: Context)
    local style = ctx.data.bar.style
    local locked = style.secureInput
    local scale = style.height / 60
    local glyph = tokens.body.large * 1.2 * scale
    local size = glyph + tokens.padding.small * scale
    local tint = locked and "warning" or "tertiaryAccent"
    return ui.stack{ w = size, h = size, radius = size / 2, hover = tint .. "/0.12",
        onClick = "shell menu", onRightClick = "shell menu",
        help = locked and omniwm.l10n("Secure Input is on: Option shortcuts are paused")
            or omniwm.l10n("Window manager controls"),
        ui.symbol{ name = locked and "omniwm.lock" or "omniwm", size = glyph, w = glyph, h = glyph, weight = "semibold",
            color = tint } }
end
