-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local panel = require("../lib/panel")

local HOVER = "focus/0.14"
local PRECISE_POINTS_PER_STEP = 12
local WIDTH = 360
local INNER = WIDTH - 2 - 24
local CARD = INNER - 20

local TRANSPORT_SYMBOLS = {
    builtin = "laptopcomputer",
    usb = "cable.connector",
    bluetooth = "headphones",
    hdmi = "display",
    displayport = "display",
    airplay = "airplayaudio",
    thunderbolt = "bolt.horizontal",
}

local function symbol(volume: number?, muted: boolean?): string
    if not volume then
        return "speaker.fill"
    end
    if muted or volume == 0 then
        return "speaker.slash.fill"
    end
    if volume < 34 then
        return "speaker.wave.1.fill"
    end
    if volume < 67 then
        return "speaker.wave.2.fill"
    end
    return "speaker.wave.3.fill"
end

local function step(ctx): number
    local settings = ctx.data.settings or {}
    return tonumber(settings.step) or 6.25
end

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
        omniwm.run(string.format("volume %s %g", if steps > 0 then "up" else "down", math.abs(steps) * step(ctx)))
    end
end

local function slide(ctx, event)
    if event.value then
        omniwm.run(string.format("volume set %d", math.round(event.value * 100)))
    end
end

local function round(name: string, command: string, active: boolean, size: number)
    return ui.stack{ w = size, h = size, radius = size / 2, hover = HOVER, onClick = command,
        fill = active and "error/0.18" or "elevatedSurface",
        ui.symbol{ name = name, size = size * 0.42, weight = "semibold", color = active and "error" or "foreground" } }
end

local function card(props)
    props.w = INNER
    props.pad = 10
    props.radius = 14
    props.fill = "surface"
    props.border = "border"
    props.borderWidth = 1
    props.center = false
    return ui.column(props)
end

local function section(text: string)
    return ui.row{ w = INNER, ui.box{ w = 4, h = 1 },
        ui.text{ text = text, size = 12, weight = "semibold", color = "secondaryForeground" } }
end

local function audioApp(entry)
    return ui.row{ w = CARD, gap = 8,
        ui.icon{ app = entry.id, w = 20, h = 20, opacity = if entry.playing then 1 else 0.55 },
        ui.text{ text = entry.name, size = 14, w = 72, maxWidth = 72,
            color = if entry.playing then "foreground" else "secondaryForeground" },
        ui.slider{ value = entry.volume / 100, w = CARD - 136, h = 14,
            color = if entry.muted then "mutedForeground" else "accent",
            onChange = function(ctx, event)
                if event.value then
                    omniwm.run(string.format("volume app %s set %d", entry.id, math.round(event.value * 100)))
                end
            end },
        round(if entry.muted then "speaker.slash.fill" else "speaker.wave.2.fill", "volume app " .. entry.id .. " mute",
            entry.muted, 24) }
end

local function output(device)
    local chosen = device.default
    return ui.row{ w = CARD, gap = 10, pad = 3, radius = 10, hover = HOVER, onClick = "volume output " .. device.id,
        ui.stack{ w = 26, h = 26, radius = 13, fill = chosen and "accent" or "elevatedSurface",
            ui.symbol{ name = TRANSPORT_SYMBOLS[device.transport] or "hifispeaker.fill", size = 12, weight = "semibold",
                color = chosen and "accentForeground" or "secondaryForeground" } },
        ui.text{ text = device.name, size = 14, grow = 1, maxWidth = CARD - 70,
            weight = chosen and "semibold" or nil, color = chosen and "foreground" or "secondaryForeground" },
        ui.stack{ w = 16, h = 16,
            ui.path{ w = 16, h = 16, d = "M8 0.75 A7.25 7.25 0 1 1 8 15.25 A7.25 7.25 0 1 1 8 0.75 Z",
                border = chosen and "accent" or "mutedForeground/0.6", borderWidth = 1.5 },
            ui.box{ w = 8, h = 8, radius = 4, fill = chosen and "accent" or nil } },
        ui.box{ w = 2, h = 1 } }
end

function render(ctx)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local fill = style.backgrounds and "surface" or nil
    local edge = style.backgrounds and "border/0.6" or nil
    local volume = ctx.data.volume
    local muted = ctx.data.muted or volume == 0
    local glyph = ui.symbol{ name = symbol(volume, ctx.data.muted), w = 20 * scale, h = 20 * scale,
        size = 18 * scale, weight = "semibold",
        color = muted and "mutedForeground" or "foreground" }
    local node = { gap = 5, radius = size / 2 - 1, fill = fill, border = edge, borderWidth = 1, hover = HOVER,
        onClick = ui.popout, onScroll = scroll }
    if style.vertical then
        node.w = size
        node[1] = ui.box{ w = 1, h = 4 }
        node[2] = glyph
        if volume then
            node[3] = ui.text{ text = tostring(volume), style = "mono", size = 14 * scale, weight = "semibold" }
        end
        node[#node + 1] = ui.box{ w = 1, h = 4 }
        node.gap = 2
        return ui.column(node)
    end
    node.h = size
    node[1] = ui.box{ w = 2, h = 1 }
    node[2] = glyph
    if volume then
        node[3] = ui.text{ text = ctx.format.percent(volume / 100), size = 14 * scale, weight = "semibold",
            color = muted and "mutedForeground" or "foreground", reserve = ctx.format.percent(1) }
    end
    node[#node + 1] = ui.box{ w = 3, h = 1 }
    return ui.row(node)
end

function popout(ctx)
    local volume = ctx.data.volume
    local muted = ctx.data.muted
    local rows = { w = WIDTH - 2, pad = 12, gap = 8, center = false }
    rows[#rows + 1] = ui.row{ w = INNER, gap = 8,
        ui.box{ w = 2, h = 1 },
        ui.text{ text = omniwm.l10n("Volume"), size = 15, weight = "bold" },
        ui.box{ grow = 1, h = 1 },
        ui.text{ text = volume and ctx.format.percent(volume / 100) or "—", size = 15, weight = "bold",
            color = muted and "mutedForeground" or "accent", reserve = ctx.format.percent(1) },
        ui.box{ w = 2, h = 1 } }
    if volume then
        rows[#rows + 1] = card{ gap = 0,
            ui.row{ w = CARD, gap = 10,
                ui.symbol{ name = symbol(volume, muted), w = 20, h = 18, size = 14, weight = "semibold",
                    color = muted and "mutedForeground" or "foreground" },
                ui.slider{ value = volume / 100, w = CARD - 64, h = 18,
                    color = if muted then "mutedForeground" else "accent", onChange = slide },
                round(if muted then "speaker.wave.2" else "speaker.slash", "volume mute", muted == true, 26) } }
    end
    local devices = ctx.data.outputs or {}
    if #devices > 0 then
        rows[#rows + 1] = section(omniwm.l10n("Output"))
        local list = { gap = 4 }
        for _, device in devices do
            list[#list + 1] = output(device)
        end
        rows[#rows + 1] = card(list)
    end
    local audio = ctx.data.audioApps
    local apps = { gap = 8 }
    if audio and audio.access == "denied" then
        apps[#apps + 1] = ui.row{ w = CARD, gap = 8, pad = 4, radius = 10, hover = HOVER, onClick = "volume permission",
            ui.stack{ w = 26, h = 26, radius = 13, fill = "warning/0.18",
                ui.symbol{ name = "lock.fill", size = 11, color = "warning" } },
            ui.text{ text = omniwm.l10n("Allow System Audio Recording to set app volumes"), size = 14,
                maxWidth = CARD - 46, lines = 2 } }
    end
    for _, entry in if audio then audio.apps else {} do
        if entry.playing or entry.muted or entry.volume < 100 then
            apps[#apps + 1] = audioApp(entry)
        end
    end
    if #apps > 0 then
        rows[#rows + 1] = section(omniwm.l10n("Applications"))
        rows[#rows + 1] = card(apps)
    end
    return panel(ctx.data.bar.style, WIDTH, ui.column(rows))
end
