-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")

function render(ctx)
    local level = ctx.data.battery
    if not level then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = style.scale(ctx)
    local low = level <= 20 and not ctx.data.charging
    local glyph = ui.symbol{ name = style.batterySymbol(level, ctx.data.charging), size = 14 * scale,
        color = if low then "error" else "foreground" }
    if ctx.data.bar.style.vertical then
        return style.bar(ctx, { gap = scale, pad = 2 * scale, glyph,
            ui.text{ style = "caption", text = tostring(level), size = 10 * scale } })
    end
    return style.bar(ctx, { glyph,
        ui.text{ style = "caption", text = ctx.format.percent(level / 100), size = 13 * scale, reserve = ctx.format.percent(1) } })
end
