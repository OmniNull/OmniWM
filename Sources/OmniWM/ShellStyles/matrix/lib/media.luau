-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("./style")
local media = {}
local INNER = style.width - 24

local function clock(seconds: number): string
    local whole = math.max(0, math.floor(seconds))
    return string.format("%d:%02d", whole // 60, whole % 60)
end

function media.content(ctx, compact: boolean?)
    local playing = ctx.data.media
    if not playing or playing.title == "" then
        return style.group{ w = style.width,
            ui.text{ style = "caption", text = omniwm.l10n("Nothing is playing"), size = 13, color = "secondaryForeground" } }
    end
    local cover = if playing.artwork
        then ui.image{ image = playing.artwork, w = 64, h = 64, radius = 2 }
        else ui.stack{ w = 64, h = 64, radius = 2, fill = "foreground/0.06",
            ui.icon{ app = playing.bundle, w = 36, h = 36, placeholder = "music.note" } }
    local rows = { w = style.width, gap = 12,
        ui.row{ w = INNER, gap = 12,
            cover,
            ui.column{ gap = 3, center = false,
                ui.text{ style = "caption", text = playing.title, size = 14, weight = "semibold", maxWidth = INNER - 76, lines = 2 },
                ui.text{ style = "caption", text = playing.artist, size = 13, color = "secondaryForeground", maxWidth = INNER - 76 },
                if not compact then ui.text{ style = "caption", text = playing.album, size = 11, color = "secondaryForeground",
                    maxWidth = INNER - 76 } else nil } } }
    if not compact and playing.duration and playing.elapsed and playing.duration > 0 then
        local duration = playing.duration
        local elapsed = playing.elapsed
        if playing.playing then
            elapsed += (ctx.data.seconds - playing.sampledAt) * playing.rate
        end
        elapsed = math.clamp(elapsed, 0, duration)
        rows[#rows + 1] = ui.column{ gap = 4,
            ui.slider{ value = elapsed / duration, w = INNER, h = 12, onChange = function(_, event)
                if event.value and event.phase == "ended" then
                    omniwm.run(string.format("media seek %.1f", event.value * duration))
                end
            end },
            ui.row{ w = INNER,
                ui.text{ style = "caption", text = clock(elapsed), size = 11, color = "secondaryForeground" },
                ui.box{ grow = 1 },
                ui.text{ style = "caption", text = clock(duration), size = 11, color = "secondaryForeground" } } }
    end
    rows[#rows + 1] = ui.row{ w = INNER, gap = 8,
        ui.box{ grow = 1 },
        style.button("backward.fill", "media previous"),
        style.button(if playing.playing then "pause.fill" else "play.fill", "media toggle",
            { w = 36, h = 36, radius = 2, fill = "accent", color = "accentForeground" }),
        style.button("forward.fill", "media next"),
        ui.box{ grow = 1 },
        style.button("arrow.up.forward.app", "media open") }
    return style.group(rows)
end

return media
