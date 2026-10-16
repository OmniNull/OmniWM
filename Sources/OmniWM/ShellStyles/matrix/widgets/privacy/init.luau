-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")

local INDICATORS = {
    { key = "microphone", symbol = "mic.fill", color = "orange", help = omniwm.l10n("Microphone in use") },
    { key = "camera", symbol = "video.fill", color = "green", help = omniwm.l10n("Camera in use") },
}

function render(ctx: Context)
    local privacy = ctx.data.privacy or {}
    local icons = (ctx.data.settings or {}).icons == true
    local scale = style.scale(ctx)
    local item = { gap = 5 * scale }
    local help = {}
    for _, indicator in INDICATORS do
        if privacy[indicator.key] then
            help[#help + 1] = indicator.help
            item[#item + 1] = if icons
                then ui.symbol{ name = indicator.symbol, size = 14 * scale, weight = "medium", color = indicator.color }
                else ui.box{ w = 6 * scale, h = 6 * scale, radius = 3 * scale, fill = indicator.color }
        end
    end
    if #help == 0 then
        return ui.box{ w = 0, h = 0 }
    end
    item.help = table.concat(help, ", ")
    return style.bar(ctx, item)
end
