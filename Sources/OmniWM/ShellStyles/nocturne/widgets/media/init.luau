-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local panel = require("../lib/panel")

local HOVER = "focus/0.14"
local WIDTH = 360
local INNER = WIDTH - 2 - 24
local CARD = INNER - 24

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
    return ui.stack{ w = size + 16, h = size + 16, radius = 10, hover = HOVER, onClick = command,
        ui.symbol{ name = name, size = size, weight = "semibold", color = "foreground" } }
end

local function cover(artwork: string?, bundle: string, size: number, radius: number)
    if artwork then
        return ui.image{ image = artwork, w = size, h = size, radius = radius }
    end
    return ui.stack{ w = size, h = size, radius = radius, fill = "elevatedSurface",
        ui.icon{ app = bundle, w = size * 0.6, h = size * 0.6, placeholder = "music.note" } }
end

function render(ctx)
    local title = ctx.select("media", "title")
    if not title or title == "" then
        return ui.box{ w = 0, h = 0 }
    end
    local artist = ctx.select("media", "artist")
    local playing = ctx.select("media", "playing")
    local vertical = ctx.select("bar", "style", "vertical")
    local backgrounds = ctx.select("bar", "style", "backgrounds")
    local scale = ctx.select("bar", "style", "height") / 40
    local size = 32 * scale
    local fill = backgrounds and "surface" or nil
    local edge = backgrounds and "border/0.6" or nil
    local art = 24 * scale
    local item = { gap = 6, radius = size / 2 - 1, fill = fill, border = edge, borderWidth = 1, hover = HOVER,
        onClick = ui.popout, onRightClick = "media toggle",
        help = if artist ~= "" then title .. " — " .. artist else title }
    local disc = ui.stack{ w = art, h = art,
        cover(ctx.select("media", "artwork"), ctx.select("media", "bundle"), art, art / 2),
        ui.stack{ align = "bottomTrailing", dx = 3, dy = 3, w = 11, h = 11, radius = 5.5, fill = "accent",
            border = "surface", borderWidth = 1,
            ui.symbol{ name = if playing then "play.fill" else "pause.fill", size = 5, weight = "black",
                color = "accentForeground" } } }
    if vertical then
        item.w = size
        item.h = size
        item[1] = disc
        return ui.stack(item)
    end
    item.h = size
    item[1] = ui.box{ w = 0, h = 1 }
    item[2] = disc
    item[3] = ui.text{ text = title, size = 14 * scale, weight = "medium", maxWidth = 130 }
    item[4] = ui.box{ w = 3, h = 1 }
    return ui.row(item)
end

function popout(ctx)
    local media = ctx.data.media
    local style = ctx.data.bar.style
    if not media or media.title == "" then
        return panel(style, WIDTH, ui.column{ w = WIDTH - 2, pad = 16,
            ui.text{ text = omniwm.l10n("Nothing is playing"), color = "secondaryForeground" } })
    end
    local controls = ui.row{ w = CARD, gap = 6,
        ui.stack{ w = 30, h = 30, radius = 10, hover = HOVER, onClick = "media open", help = media.app,
            ui.icon{ app = media.bundle, w = 18, h = 18, placeholder = "arrow.up.forward.app" } },
        ui.box{ grow = 1, h = 1 },
        button("backward.fill", "media previous", 14),
        ui.stack{ w = 44, h = 44, radius = 14, fill = "accent", hoverScale = 1.05, onClick = "media toggle",
            ui.symbol{ name = if media.playing then "pause.fill" else "play.fill", size = 18, weight = "bold",
                color = "accentForeground" } },
        button("forward.fill", "media next", 14),
        ui.box{ grow = 1, h = 1 },
        ui.box{ w = 30, h = 30 } }
    local card = { w = INNER, pad = 12, gap = 12, radius = 14, fill = "surface", border = "border", borderWidth = 1,
        center = false,
        ui.row{ w = CARD, gap = 12,
            cover(media.artwork, media.bundle, 76, 12),
            ui.column{ gap = 3, center = false,
                ui.text{ text = media.title, size = 15, weight = "bold", color = "accent", maxWidth = CARD - 88 },
                ui.text{ text = media.artist, size = 14, color = "foreground", maxWidth = CARD - 88 },
                ui.text{ text = media.album, size = 12, color = "blue", maxWidth = CARD - 88 } } } }
    local current = position(ctx, media)
    if current and media.duration and media.duration > 0 then
        local duration = media.duration
        card[#card + 1] = ui.column{ gap = 3,
            ui.slider{ value = current / duration, w = CARD, h = 12, color = "accent", onChange = function(_, event)
                if event.value and event.phase == "ended" then
                    omniwm.run(string.format("media seek %.1f", event.value * duration))
                end
            end },
            ui.row{ w = CARD,
                ui.text{ text = clock(current), style = "mono", size = 12, color = "secondaryForeground" },
                ui.box{ grow = 1 },
                ui.text{ text = clock(duration), style = "mono", size = 12, color = "secondaryForeground" } } }
    end
    card[#card + 1] = controls
    return panel(style, WIDTH, ui.column{ w = WIDTH - 2, pad = 12, gap = 8, center = false,
        ui.row{ w = INNER, gap = 6,
            ui.box{ w = 2, h = 1 },
            ui.text{ text = omniwm.l10n("Now Playing"), size = 15, weight = "bold" },
            ui.box{ grow = 1, h = 1 },
            ui.text{ text = media.app, size = 12, weight = "semibold", color = "secondaryForeground", maxWidth = 120 },
            ui.box{ w = 2, h = 1 } },
        ui.column(card) })
end
