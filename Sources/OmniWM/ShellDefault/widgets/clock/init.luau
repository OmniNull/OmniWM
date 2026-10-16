-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

function render(ctx)
    if ctx.select("bar", "style", "vertical") then
        return ui.column{ gap = 0, pad = 2,
            ui.text{ text = os.date("%H"), style = "bold", size = 11 },
            ui.text{ text = os.date("%M"), size = 11 } }
    end
    local row = { gap = 6, pad = 2 }
    if ctx.select("settings", "date") ~= false then
        row[#row + 1] = ui.text{ text = ctx.data.date, color = "secondaryForeground" }
    end
    row[#row + 1] = ui.text{ text = ctx.data.clock, style = "bold", reserve = "00:00 PM" }
    return ui.row(row)
end
