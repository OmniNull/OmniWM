-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local INDICATORS = {
    { key = "microphone", symbol = "mic.fill", color = "orange", help = omniwm.l10n("Microphone in use") },
    { key = "camera", symbol = "video.fill", color = "green", help = omniwm.l10n("Camera in use") },
}

function render(ctx: Context)
    local privacy = ctx.data.privacy or {}
    local style = ctx.data.bar.style
    local icons = (ctx.data.settings or {}).icons == true
    local capsule = style.transparent and style.backgrounds
    local size = math.max(16, style.height - 4)
    local item = { gap = if icons then 6 else 5 }
    local help = {}
    for _, indicator in INDICATORS do
        if privacy[indicator.key] then
            help[#help + 1] = indicator.help
            item[#item + 1] = if icons
                then ui.symbol{ name = indicator.symbol, size = 11, weight = "semibold", color = indicator.color }
                else ui.box{ w = 7, h = 7, radius = 3.5, fill = indicator.color }
        end
    end
    if #help == 0 then
        return ui.box{ w = 0, h = 0 }
    end
    item.help = table.concat(help, ", ")
    item.radius = size / 2
    item[style.vertical and "w" or "h"] = size
    if capsule then
        item.fill = "surface"
        item.border = "border"
        item.borderWidth = 0.5
    end
    local edge = if capsule then math.round(size * 0.32) else 2
    local spacer = if style.vertical then { w = 1, h = edge } else { w = edge, h = 1 }
    table.insert(item, 1, ui.box(table.clone(spacer)))
    item[#item + 1] = ui.box(spacer)
    return if style.vertical then ui.column(item) else ui.row(item)
end
