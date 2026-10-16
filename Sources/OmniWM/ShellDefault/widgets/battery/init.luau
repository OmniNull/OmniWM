-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local function symbol(level: number, charging: boolean): string
    if charging then
        return "battery.100percent.bolt"
    end
    if level > 85 then
        return "battery.100percent"
    end
    if level > 60 then
        return "battery.75percent"
    end
    if level > 35 then
        return "battery.50percent"
    end
    if level > 10 then
        return "battery.25percent"
    end
    return "battery.0percent"
end

function render(ctx)
    local level = ctx.data.battery
    if not level then
        return ui.box{ w = 0, h = 0 }
    end
    local low = level <= 20 and not ctx.data.charging
    local glyph = ui.symbol{ name = symbol(level, ctx.data.charging), color = low and "error" or "foreground" }
    if ctx.data.bar.style.vertical then
        return ui.column{ gap = 1, pad = 2, glyph, ui.text{ text = tostring(level), style = "mono", size = 9 } }
    end
    return ui.row{ gap = 4, pad = 2, glyph,
        ui.text{ text = ctx.format.percent(level / 100), style = "mono", reserve = ctx.format.percent(1) } }
end
