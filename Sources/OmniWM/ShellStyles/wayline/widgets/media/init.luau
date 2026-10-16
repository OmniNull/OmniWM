-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HUE = "blue"
local WIDTH = 360
local INNER = WIDTH - 32

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

local function block(size: number, radius: number, vertical: boolean, name: string)
    return ui.stack{ w = size, h = size,
        ui.box{ w = size, h = size, radius = radius, fill = HUE },
        ui.box{ align = vertical and "bottom" or "trailing", w = vertical and size or radius,
            h = vertical and radius or size, fill = HUE },
        ui.symbol{ name = name, size = math.floor(size * 0.46), weight = "bold", color = "accentForeground" } }
end

local function button(name: string, command: string, size: number)
    return ui.stack{ w = size + 18, h = size + 18, radius = (size + 18) / 2, hover = "foreground/0.08",
        onClick = command, ui.symbol{ name = name, size = size, weight = "semibold", color = "secondaryForeground" } }
end

function render(ctx)
    local title = ctx.select("media", "title")
    if not title or title == "" then
        return ui.box{ w = 0, h = 0 }
    end
    local artist = ctx.select("media", "artist")
    local playing = ctx.select("media", "playing")
    local vertical = ctx.select("bar", "style", "vertical")
    local scale = ctx.select("bar", "style", "height") / 40
    local size = 32 * scale
    local radius = math.floor(size * 0.24)
    local item = { h = size, gap = 0, radius = radius, fill = "elevatedSurface", hoverOpacity = 0.9,
        onClick = ui.popout, onRightClick = "media toggle",
        help = if artist ~= "" then title .. " — " .. artist else title,
        block(size, radius, vertical, if playing then "play.fill" else "pause.fill") }
    if vertical then
        item.h = nil
        item.w = size
        return ui.column(item)
    end
    item[#item + 1] = ui.box{ w = 8, h = 1 }
    item[#item + 1] = ui.text{ text = title, size = 14 * scale, weight = "semibold", color = HUE, maxWidth = 150 }
    item[#item + 1] = ui.box{ w = 9, h = 1 }
    return ui.row(item)
end

function popout(ctx)
    local media = ctx.data.media
    local frame = { w = WIDTH, gap = 0, material = "clear", radius = 12, fill = "surface", border = "border",
        borderWidth = 1, center = false }
    if not media or media.title == "" then
        frame[#frame + 1] = ui.box{ w = WIDTH, pad = 16,
            ui.text{ text = omniwm.l10n("Nothing is playing"), color = "secondaryForeground" } }
        return ui.column(frame)
    end
    local cover = if media.artwork
        then ui.image{ image = media.artwork, w = 72, h = 72, radius = 8 }
        else ui.stack{ w = 72, h = 72, radius = 8, fill = "elevatedSurface",
            ui.icon{ app = media.bundle, w = 40, h = 40, placeholder = "music.note" } }
    frame[#frame + 1] = ui.stack{ w = WIDTH, h = 44,
        ui.box{ w = WIDTH, h = 44, radius = 12, fill = "elevatedSurface" },
        ui.box{ align = "bottom", w = WIDTH, h = 12, fill = "elevatedSurface" },
        ui.row{ w = INNER, gap = 8,
            ui.icon{ app = media.bundle, w = 16, h = 16, placeholder = "music.note" },
            ui.text{ text = media.app, size = 14, weight = "bold", color = "foreground", maxWidth = INNER - 60 },
            ui.box{ grow = 1, h = 1 },
            ui.stack{ w = 26, h = 26, radius = 6, hover = "foreground/0.08", onClick = "media open",
                ui.symbol{ name = "arrow.up.forward.app", size = 12, color = "secondaryForeground" } } } }
    frame[#frame + 1] = ui.box{ w = WIDTH, h = 1, fill = "border" }
    local body = { w = WIDTH, pad = 16, gap = 14, center = false,
        ui.row{ w = INNER, gap = 14,
            cover,
            ui.column{ gap = 3, center = false,
                ui.text{ text = media.title, size = 14, weight = "bold", color = "foreground", maxWidth = INNER - 86 },
                ui.text{ text = media.artist, size = 14, weight = "semibold", color = "secondaryForeground",
                    maxWidth = INNER - 86 },
                ui.text{ text = media.album, size = 12, weight = "medium", color = "mutedForeground",
                    maxWidth = INNER - 86 } } } }
    local current = position(ctx, media)
    if current and media.duration and media.duration > 0 then
        local duration = media.duration
        body[#body + 1] = ui.column{ gap = 5, center = false,
            ui.slider{ value = current / duration, w = INNER, h = 12, color = "accent", onChange = function(_, event)
                if event.value and event.phase == "ended" then
                    omniwm.run(string.format("media seek %.1f", event.value * duration))
                end
            end },
            ui.row{ w = INNER,
                ui.text{ text = clock(current), style = "mono", size = 12, weight = "semibold", color = "mutedForeground" },
                ui.box{ grow = 1, h = 1 },
                ui.text{ text = clock(duration), style = "mono", size = 12, weight = "semibold",
                    color = "mutedForeground" } } }
    end
    body[#body + 1] = ui.row{ w = INNER, gap = 10,
        ui.box{ grow = 1, h = 1 },
        button("backward.fill", "media previous", 15),
        ui.stack{ w = 48, h = 48, radius = 24, fill = "accent", hoverOpacity = 0.85, onClick = "media toggle",
            ui.symbol{ name = if media.playing then "pause.fill" else "play.fill", size = 20, weight = "bold",
                color = "accentForeground" } },
        button("forward.fill", "media next", 15),
        ui.box{ grow = 1, h = 1 } }
    frame[#frame + 1] = ui.column(body)
    return ui.column(frame)
end
