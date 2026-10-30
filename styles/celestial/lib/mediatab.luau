-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local geometry = require("./geometry")
local motion = require("./motion")
local shapes = require("./shapes")
local surface = require("./surface")
local tokens = require("./tokens")

local WIDTH = tokens.dashboard.mediaTab.w
local HEIGHT = tokens.dashboard.mediaTab.h
local SECTION = tokens.dashboard.mediaTab.section
local PAD = tokens.padding.large
local GAP = tokens.spacing.extraLarge
local INNER = HEIGHT - 2 * PAD
local DETAILS = WIDTH - 2 * PAD - 2 * SECTION - 2 * GAP
local COVER = tokens.dashboard.cover
local LINE = math.ceil(tokens.body.medium * 1.35) + tokens.spacing.small
local POOL = {
    "Circle", "Cookie4Sided", "Cookie6Sided", "Cookie7Sided", "Cookie9Sided", "Cookie12Sided", "Sunny", "VerySunny",
    "SoftBurst", "Pentagon", "Gem", "Arch", "Arrow", "Pill", "Triangle", "Fan", "Oval",
}
local TINTS = { "accentContainer", "secondaryContainer", "tertiaryContainer", "border" }
local LIGHT = { 0.34, 0.34, 0.08, 0.2 }
local DARK = { 0.16, 0.16, 0.04, 0.16 }

local function random(low: number, high: number): number
    return low + math.random() * (high - low)
end

local function drifters(ctx: Context)
    local state = ctx.state
    if not state.drifters then
        local list = {}
        for index = 1, 14 do
            local size = 36 + (index - 1) / 14 * (124 - 36)
            local x, y = random(0, WIDTH - size), random(0, HEIGHT - size)
            local function travel(span: number, rest: number): { number }
                local speed = random(4, 18) * (math.random() < 0.5 and -1 or 1)
                local phase = math.random()
                local length = 2 * (span + size)
                local start = -size - phase * (span + size) - rest
                if speed < 0 then
                    return { start + length, start, length / -speed }
                end
                return { start, start + length, length / speed }
            end
            local spin = random(-12, 12)
            local rotation = random(0, 360)
            list[index] = { size = size, shape = POOL[math.random(#POOL)], tint = math.random(4), x = x, y = y,
                dx = travel(WIDTH, x), dy = travel(HEIGHT, y),
                rotate = { rotation, rotation + (spin >= 0 and 360 or -360), 360 / math.max(math.abs(spin), 1) } }
        end
        state.drifters = list
    end
    return state.drifters
end

local function backdrop(ctx: Context, playing: boolean)
    local light = ctx.data.appearance == "light"
    local layers = { w = WIDTH, h = HEIGHT,
        ui.path{ d = string.format("M 0 0 H %d V %d H 0 Z", WIDTH, HEIGHT), w = WIDTH, h = HEIGHT, mask = true } }
    for index, drifter in drifters(ctx) do
        layers[#layers + 1] = ui.path{ key = "drift" .. index, d = shapes.path(drifter.shape), viewBox = shapes.viewBox,
            align = "topLeading", dx = drifter.x, dy = drifter.y, w = drifter.size, h = drifter.size,
            rotate = drifter.rotate[1], fill = TINTS[drifter.tint],
            opacity = (light and LIGHT or DARK)[drifter.tint],
            loop = { dx = drifter.dx, dy = drifter.dy, rotate = drifter.rotate, paused = not playing } }
    end
    return ui.stack(layers)
end

local function cover(ctx: Context, media)
    local playing = media ~= nil and media.playing
    local base = COVER * 0.515 + tokens.spacing.medium + 2
    local art = { w = COVER, h = COVER,
        ui.path{ d = shapes.path("Cookie9Sided"), viewBox = shapes.viewBox, w = COVER, h = COVER, mask = true,
            loop = { rotate = { 360, 0, 23.5 }, paused = not playing } },
        ui.box{ w = COVER, h = COVER, fill = "highestSurface" } }
    art[#art + 1] = media and media.artwork and ui.image{ image = media.artwork, w = COVER, h = COVER }
        or surface.icon("art_track", { size = COVER * 0.35, color = "secondaryForeground" })
    return ui.stack{ w = SECTION, h = INNER,
        ui.shader{ source = "visualizer.metal", audio = true, w = SECTION, h = INNER,
            values = { base, (SECTION - COVER) / 2 - tokens.spacing.medium, 360 / 60 - tokens.spacing.small / 4 } },
        ui.stack(art) }
end

local function slider(media, width: number)
    local fraction = media.fraction or 0
    local height = 24
    local filled = math.max(width * fraction, 1)
    local layers = { w = width, h = height }
    if width - filled > 8 then
        layers[#layers + 1] = ui.box{ align = "trailing", w = width - filled - 6, h = 4, radius = 2, fill = "secondaryContainer" }
    end
    layers[#layers + 1] = ui.stack{ align = "leading", w = filled, h = height,
        ui.path{ d = string.format("M 0 0 H %.2f V %d H 0 Z", filled, height), w = filled, h = height, mask = true },
        ui.path{ align = "leading", d = geometry.wavyLine(width + 30, height, 30, 3), w = width + 30, h = height,
            border = "accent", borderWidth = 4, loop = { dx = { -30, 0, 2 }, paused = not media.playing } } }
    layers[#layers + 1] = ui.box{ align = "leading", dx = filled - 2, w = 4, h = height, radius = 2, fill = "accent" }
    layers[#layers + 1] = ui.slider{ w = width, h = height, value = fraction, opacity = 0.02,
        onChange = media.seek }
    return ui.stack(layers)
end

local function details(media)
    local width = DETAILS
    local function line(text: string, size: number, color: string)
        return ui.text{ text = text, font = "sans", size = size, color = color, maxWidth = width }
    end
    local function toggle(icon: string, on: boolean?, command: string)
        return surface.button(icon, "tonal", { onClick = command, fill = on and "secondaryAccent" or "secondaryContainer",
            color = on and "background" or "secondaryContainerForeground", radius = on and tokens.rounding.medium or nil,
            glyph = tokens.icon.medium })
    end
    return ui.column{ w = width, gap = tokens.spacing.extraSmall, center = false,
        line(media.title, tokens.title.large, "foreground"),
        line(media.artist, tokens.title.medium, "secondaryForeground"),
        line(media.album, tokens.title.medium, "secondaryAccent"),
        ui.box{ w = 1, h = tokens.spacing.extraLargeIncreased },
        ui.row{ w = width, gap = tokens.spacing.small,
            ui.text{ text = media.elapsedText or "0:00", font = "sans", size = tokens.label.medium, color = "secondaryForeground",
                reserve = "00:00" },
            slider(media, width - 2 * 48 - 2 * tokens.spacing.small),
            ui.text{ text = media.durationText or "--:--", font = "sans", size = tokens.label.medium,
                color = "secondaryForeground", reserve = "00:00" } },
        ui.box{ w = 1, h = tokens.spacing.largeIncreased },
        ui.row{ w = width, gap = tokens.spacing.extraSmall,
            media.shuffle ~= nil and toggle("shuffle", media.shuffle, media.shuffleCommand) or nil,
            surface.button("skip_previous", "tonal", { onClick = media.previous, glyph = tokens.icon.large }),
            surface.button(media.playing and "pause" or "play_arrow", "filled", { grow = 1, w = 0,
                radius = media.playing and tokens.rounding.medium or nil, onClick = media.toggle,
                glyph = tokens.icon.large }),
            surface.button("skip_next", "tonal", { onClick = media.next, glyph = tokens.icon.large }),
            media.repeatMode ~= nil and toggle(media.repeatMode == "one" and "repeat_one" or "repeat", media.repeating,
                media.repeatCommand) or nil } }
end

local function state(icon: string, text: string, tint: string)
    return ui.column{ gap = tokens.spacing.small,
        surface.icon(icon, { size = tokens.icon.large * 2, color = tint }),
        ui.text{ text = text, font = "sans", size = tokens.title.medium, color = tint } }
end

local function lyrics(media)
    local data = media.lyrics
    local height = INNER - 40 - tokens.spacing.medium
    local body
    if data and data.lines then
        local current = data.current
        local column = { gap = 0, center = false, align = "top", dy = height / 2 - LINE / 2 - (current - 1) * LINE,
            animate = motion.large }
        for index, entry in data.lines do
            local distance = math.abs(index - current)
            local shown = distance <= 8
            column[#column + 1] = ui.stack{ key = "line" .. index, w = SECTION - tokens.padding.medium, h = LINE,
                hover = shown and "foreground/0.06" or nil, radius = tokens.rounding.small,
                onClick = shown and data.seek(entry.time) or nil,
                shown and ui.text{ align = "leading", text = entry.text ~= "" and entry.text or ". . .", font = "sans",
                    size = tokens.body.medium, maxWidth = SECTION - tokens.padding.medium,
                    color = index == current and "accent" or "mutedForeground",
                    shadow = index == current and "accent/0.5" or nil, shadowRadius = 6,
                    opacity = math.clamp(1 - distance * 0.12, 0.25, 1), animate = "slowEffects" } or nil }
        end
        body = ui.stack{ w = SECTION - tokens.padding.medium, h = height,
            ui.path{ d = string.format("M 0 0 H %d V %d H 0 Z", SECTION, height), w = SECTION - tokens.padding.medium,
                h = height, mask = true },
            ui.column(column) }
    elseif data and (data.access == "off" or data.access == "blocked") then
        body = ui.stack{ w = SECTION, h = height, state("lyrics", data.message, "secondaryForeground") }
    elseif data and data.status == "loading" then
        body = ui.stack{ w = SECTION, h = height, state("lyrics", omniwm.l10n("Loading lyrics…"), "secondaryForeground") }
    else
        body = ui.stack{ w = SECTION, h = height, state("sentiment_sad", omniwm.l10n("No lyrics found"), "mutedForeground") }
    end
    return ui.column{ w = SECTION, gap = tokens.spacing.medium, center = false,
        ui.row{ gap = tokens.spacing.medium,
            surface.icon("lyrics", { size = tokens.icon.medium }),
            ui.text{ text = omniwm.l10n("Lyrics"), font = "sans", size = tokens.title.medium } },
        body,
        ui.row{ h = 40, gap = tokens.spacing.small, pad = tokens.padding.medium, radius = 20, fill = "secondaryContainer",
            hover = "secondaryContainerForeground/0.08", onClick = media.open,
            ui.icon{ app = media.bundle, w = 20, h = 20, placeholder = "music.note" },
            ui.text{ text = media.app, font = "sans", size = tokens.label.large,
                color = "secondaryContainerForeground", maxWidth = SECTION - 80 } } }
end

local function empty()
    return ui.column{ w = DETAILS + GAP + SECTION, h = INNER, gap = tokens.spacing.small,
        ui.stack{ w = tokens.icon.large * 2 + 2 * tokens.padding.extraLarge,
            h = tokens.icon.large * 2 + 2 * tokens.padding.extraLarge,
            ui.path{ d = shapes.path("ClamShell"), viewBox = shapes.viewBox, w = tokens.icon.large * 2 + 2 * tokens.padding.extraLarge,
                h = tokens.icon.large * 2 + 2 * tokens.padding.extraLarge, fill = "accentContainer" },
            surface.icon("queue_music", { size = tokens.icon.large * 2, color = "accentContainerForeground" }) },
        ui.text{ text = omniwm.l10n("Nothing is playing"), font = "sans", size = tokens.headline.medium },
        ui.text{ text = omniwm.l10n("Play something to see it here"), font = "sans", size = tokens.body.large,
            color = "secondaryForeground" } }
end

local function tab(ctx: Context, media)
    media = media or require("./media").model(ctx)
    local playing = media ~= nil and media.playing
    local content = media and ui.row{ gap = GAP, center = false, details(media), lyrics(media) } or empty()
    return ui.stack{ w = WIDTH, h = HEIGHT,
        backdrop(ctx, playing),
        ui.row{ w = WIDTH, h = HEIGHT, pad = PAD, gap = GAP, cover(ctx, media), content } }
end

return table.freeze({
    size = table.freeze({ w = WIDTH, h = HEIGHT }),
    tab = tab,
})
