-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local mediatab = require("../lib/mediatab")
local status = require("../lib/status")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

function render(ctx: Context)
    local title = ctx.select("media", "title")
    if not title or title == "" then
        return ui.box{ w = 0, h = 0 }
    end
    local artist = ctx.select("media", "artist")
    local playing = ctx.select("media", "playing")
    local style = ctx.data.bar.style
    local vertical = style.vertical
    local scale = style.height / 60
    local items = { surface.icon(if playing then "music_note" else "pause", { color = "secondaryAccent",
        size = tokens.icon.medium * scale, filled = true, animate = "effects" }) }
    if not vertical then
        items[2] = ui.text{ text = title, font = "sans", size = tokens.label.large * scale, weight = "medium",
            maxWidth = 160 }
    end
    return surface.pill(style, items, { hover = status.hover, onClick = ui.popout, onRightClick = "media toggle",
        help = if artist ~= "" then title .. " — " .. artist else title })
end

function popout(ctx: Context)
    return status.pane(mediatab, ctx)
end
