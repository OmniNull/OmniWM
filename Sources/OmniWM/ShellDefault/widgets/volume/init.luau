-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HOVER = "foreground/0.12"
local PRECISE_POINTS_PER_STEP = 12
local WIDTH = 304

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

local function button(name: string, command: string)
    return ui.box{ pad = 5, radius = 6, hover = HOVER, onClick = command, ui.symbol{ name = name } }
end

local function audioApp(entry)
    return ui.row{ gap = 8, pad = 4,
        ui.icon{ app = entry.id, w = 18, h = 18, opacity = if entry.playing then 1 else 0.6 },
        ui.text{ text = entry.name, w = 110, maxWidth = 110 },
        ui.slider{ value = entry.volume / 100, w = 120, h = 14,
            color = if entry.muted then "mutedForeground" else "accent",
            onChange = function(ctx, event)
                if event.value then
                    omniwm.run(string.format("volume app %s set %d", entry.id, math.round(event.value * 100)))
                end
            end },
        button(if entry.muted then "speaker.slash.fill" else "speaker.wave.2.fill", "volume app " .. entry.id .. " mute") }
end

local function output(device)
    return ui.row{ w = WIDTH, gap = 8, pad = 5, radius = 6, hover = HOVER, onClick = "volume output " .. device.id,
        ui.symbol{ name = TRANSPORT_SYMBOLS[device.transport] or "hifispeaker.fill", w = 16, h = 16 },
        ui.text{ text = device.name, grow = 1, maxWidth = 180, weight = if device.default then "semibold" else nil },
        ui.symbol{ name = "checkmark", w = 12, h = 12, opacity = if device.default then 1 else 0 } }
end

function render(ctx)
    local volume = ctx.data.volume
    local row = { gap = 4, pad = 2, radius = 4, hover = HOVER, onClick = ui.popout, onScroll = scroll,
        ui.symbol{ name = symbol(volume, ctx.data.muted) } }
    if ctx.data.bar.style.vertical then
        row.gap = 1
        if volume then
            row[#row + 1] = ui.text{ text = tostring(volume), style = "mono", size = 9 }
        end
        return ui.column(row)
    end
    if volume then
        row[#row + 1] = ui.text{ text = ctx.format.percent(volume / 100), style = "mono",
            reserve = ctx.format.percent(1) }
    end
    return ui.row(row)
end

function popout(ctx)
    local volume = ctx.data.volume
    local muted = ctx.data.muted
    local rows = { gap = 6, pad = 10, center = false }
    if volume then
        rows[#rows + 1] = ui.row{ gap = 8,
            ui.symbol{ name = symbol(volume, muted), w = 18, h = 18 },
            ui.slider{ value = volume / 100, w = 160, h = 16, color = if muted then "mutedForeground" else "accent",
                onChange = slide },
            ui.text{ text = ctx.format.percent(volume / 100), style = "mono", reserve = ctx.format.percent(1) },
            button(if muted then "speaker.wave.2" else "speaker.slash", "volume mute") }
    end
    for _, device in ctx.data.outputs or {} do
        rows[#rows + 1] = output(device)
    end
    local audio = ctx.data.audioApps
    if audio and audio.access == "denied" then
        rows[#rows + 1] = ui.row{ w = WIDTH, gap = 6, pad = 5, radius = 6, hover = HOVER, onClick = "volume permission",
            ui.symbol{ name = "lock.fill", w = 14, h = 14 },
            ui.text{ text = omniwm.l10n("Allow System Audio Recording to set app volumes"), maxWidth = 240,
                lines = 2 } }
    end
    for _, entry in if audio then audio.apps else {} do
        if entry.playing or entry.muted or entry.volume < 100 then
            rows[#rows + 1] = audioApp(entry)
        end
    end
    return ui.column(rows)
end
