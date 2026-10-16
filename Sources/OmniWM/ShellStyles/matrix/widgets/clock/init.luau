-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")

function render(ctx)
    local scale = style.scale(ctx)
    if ctx.data.bar.style.vertical then
        return style.bar(ctx, { gap = 0, pad = 2 * scale,
            ui.text{ style = "caption", text = os.date("%H"), size = 11 * scale, weight = "medium" },
            ui.text{ style = "caption", text = os.date("%M"), size = 11 * scale } })
    end
    local row = { gap = 8 * scale }
    if ctx.select("settings", "date") ~= false then
        row[#row + 1] = ui.text{ style = "caption", text = string.upper(ctx.data.date), size = 12 * scale,
            color = "secondaryForeground" }
        row[#row + 1] = ui.text{ style = "caption", text = "//", size = 12 * scale, color = "accent" }
    end
    row[#row + 1] = ui.text{ style = "caption", text = ctx.data.clock, size = 12 * scale, weight = "medium", reserve = "00:00 PM" }
    return style.bar(ctx, row)
end
