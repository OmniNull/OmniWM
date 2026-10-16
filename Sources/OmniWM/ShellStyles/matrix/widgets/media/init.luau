-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")
local media = require("../lib/media")

function render(ctx)
    local title = ctx.select("media", "title")
    if not title or title == "" then
        return ui.box{ w = 0, h = 0 }
    end
    local artist = ctx.select("media", "artist")
    local scale = style.scale(ctx)
    local row = { onClick = ui.popout, onRightClick = "media toggle",
        help = if artist ~= "" then title .. " — " .. artist else title,
        ui.symbol{ name = if ctx.select("media", "playing") then "play.fill" else "pause.fill", size = 14 * scale } }
    if not ctx.data.bar.style.vertical then
        row[#row + 1] = ui.text{ style = "caption", text = title, size = 13 * scale, maxWidth = 160 * scale }
    end
    return style.bar(ctx, row)
end

function popout(ctx)
    return style.panel{ w = style.width + 28, style.heading(omniwm.l10n("Media")), media.content(ctx) }
end
