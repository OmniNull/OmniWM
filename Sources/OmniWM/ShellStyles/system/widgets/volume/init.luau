-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")
local audio = require("../lib/audio")
local PRECISE_POINTS_PER_STEP = 12

local function scroll(ctx, event)
    local delta = if event.precise then event.dy / PRECISE_POINTS_PER_STEP else event.dy
    local total = ctx.state.scroll or 0
    if total * delta < 0 then
        total = 0
    end
    total += delta
    local steps = if total >= 0 then math.floor(total) else math.ceil(total)
    ctx.state.scroll = total - steps
    if steps ~= 0 then
        local step = tonumber((ctx.data.settings or {}).step) or 6.25
        omniwm.run(string.format("volume %s %g", if steps > 0 then "up" else "down", math.abs(steps) * step))
    end
end

function render(ctx)
    local volume = ctx.data.volume
    local scale = style.scale(ctx)
    local vertical = ctx.data.bar.style.vertical
    local row = { onClick = ui.popout, onScroll = scroll, gap = if vertical then 1 else 5 * scale,
        ui.symbol{ name = audio.symbol(volume, ctx.data.muted), size = 14 * scale } }
    if volume then
        row[#row + 1] = ui.text{ text = if vertical then tostring(volume) else ctx.format.percent(volume / 100),
            size = (if vertical then 10 else 13) * scale,
            reserve = if vertical then "100" else ctx.format.percent(1) }
    end
    return style.bar(ctx, row)
end

function popout(ctx)
    return style.panel{ w = style.width + 28, audio.content(ctx) }
end
