-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HOVER = "foreground/0.12"
local WIDTH = 276

local function clock(seconds: number): string
    local whole = math.max(0, math.floor(seconds))
    return string.format("%d:%02d", whole // 60, whole % 60)
end

local function position(ctx, media): number?
    if not media.duration or not media.elapsed then
        return nil
    end
    local elapsed = media.elapsed
    if media.playing then
        elapsed += (ctx.data.seconds - media.sampledAt) * media.rate
    end
    return math.clamp(elapsed, 0, media.duration)
end

local function button(name: string, command: string, size: number)
    return ui.box{ pad = 5, radius = 6, hover = HOVER, onClick = command,
        ui.symbol{ name = name, w = size, h = size } }
end

function render(ctx)
    local title = ctx.select("media", "title")
    if not title or title == "" then
        return ui.box{ w = 0, h = 0 }
    end
    local artist = ctx.select("media", "artist")
    local playing = ctx.select("media", "playing")
    local item = { gap = 5, pad = 2, radius = 4, hover = HOVER, onClick = ui.popout, onRightClick = "media toggle",
        help = if artist ~= "" then title .. " — " .. artist else title,
        ui.symbol{ name = if playing then "play.fill" else "pause.fill" } }
    if ctx.select("bar", "style", "vertical") then
        return ui.box(item)
    end
    item[#item + 1] = ui.text{ text = title, maxWidth = 160 }
    return ui.row(item)
end

function popout(ctx)
    local media = ctx.data.media
    if not media or media.title == "" then
        return ui.box{ pad = 12, ui.text{ text = omniwm.l10n("Nothing is playing"), color = "secondaryForeground" } }
    end
    local cover = if media.artwork
        then ui.image{ image = media.artwork, w = 64, h = 64, radius = 6 }
        else ui.box{ w = 64, h = 64, radius = 6, fill = "foreground/0.08", center = true,
            ui.icon{ app = media.bundle, w = 36, h = 36, placeholder = "music.note" } }
    local rows = { gap = 10, pad = 12, center = false,
        ui.row{ gap = 12,
            cover,
            ui.column{ gap = 2, center = false,
                ui.text{ text = media.title, style = "bold", maxWidth = 200 },
                ui.text{ text = media.artist, color = "secondaryForeground", maxWidth = 200 },
                ui.text{ text = media.album, style = "small", color = "secondaryForeground", maxWidth = 200 } } } }
    local current = position(ctx, media)
    if current and media.duration and media.duration > 0 then
        local duration = media.duration
        rows[#rows + 1] = ui.column{ gap = 4,
            ui.slider{ value = current / duration, w = WIDTH, h = 12, onChange = function(_, event)
                if event.value and event.phase == "ended" then
                    omniwm.run(string.format("media seek %.1f", event.value * duration))
                end
            end },
            ui.row{ w = WIDTH,
                ui.text{ text = clock(current), style = "small", color = "secondaryForeground" },
                ui.box{ grow = 1 },
                ui.text{ text = clock(duration), style = "small", color = "secondaryForeground" } } }
    end
    rows[#rows + 1] = ui.row{ w = WIDTH, gap = 8, center = true,
        ui.box{ grow = 1 },
        button("backward.fill", "media previous", 16),
        button(if media.playing then "pause.fill" else "play.fill", "media toggle", 20),
        button("forward.fill", "media next", 16),
        ui.box{ grow = 1 },
        button("arrow.up.forward.app", "media open", 14) }
    return ui.column(rows)
end
