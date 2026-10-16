-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("./style")
local audio = {}
local INNER = style.width - 24
local TRANSPORT = {
    builtin = "laptopcomputer", usb = "cable.connector", bluetooth = "headphones", hdmi = "display",
    displayport = "display", airplay = "airplayaudio", thunderbolt = "bolt.horizontal",
}

function audio.symbol(volume: number?, muted: boolean?): string
    if not volume then
        return "speaker.fill"
    end
    if muted or volume == 0 then
        return "speaker.slash.fill"
    end
    return if volume < 34 then "speaker.wave.1.fill" elseif volume < 67 then "speaker.wave.2.fill"
        else "speaker.wave.3.fill"
end

function audio.level(ctx)
    local volume = ctx.data.volume
    if not volume then
        return style.group{ w = style.width,
            ui.text{ text = omniwm.l10n("Unavailable"), size = 13, color = "secondaryForeground" } }
    end
    local muted = ctx.data.muted
    return style.group{ w = style.width,
        style.heading(omniwm.l10n("Sound")),
        ui.row{ w = INNER, gap = 8,
            ui.symbol{ name = audio.symbol(volume, muted), w = 18, h = 18 },
            ui.slider{ value = volume / 100, w = INNER - 112, h = 16,
                color = if muted then "mutedForeground" else "accent",
                onChange = function(_, event)
                    if event.value then
                        omniwm.run(string.format("volume set %d", math.round(event.value * 100)))
                    end
                end },
            ui.text{ text = ctx.format.percent(volume / 100), size = 12, w = 42,
                reserve = ctx.format.percent(1) },
            style.button(if muted then "speaker.wave.2" else "speaker.slash", "volume mute") } }
end

function audio.content(ctx)
    local rows = { w = style.width, gap = 12, center = false, audio.level(ctx) }
    local outputs = { w = style.width, gap = 4, style.heading(omniwm.l10n("Output")) }
    for _, device in ctx.data.outputs or {} do
        outputs[#outputs + 1] = ui.row{ w = INNER, gap = 8, pad = 6, radius = 7, hover = style.hover,
            onClick = "volume output " .. device.id,
            ui.symbol{ name = TRANSPORT[device.transport] or "hifispeaker.fill", w = 18, h = 18 },
            ui.text{ text = device.name, size = 13, grow = 1, maxWidth = INNER - 62,
                weight = if device.default then "semibold" else nil },
            ui.symbol{ name = "checkmark", w = 14, h = 14, color = "accent",
                opacity = if device.default then 1 else 0 } }
    end
    if #outputs > 1 then
        rows[#rows + 1] = style.group(outputs)
    end
    local apps = ctx.data.audioApps
    if apps and apps.access == "denied" then
        rows[#rows + 1] = style.group{ w = style.width, hover = style.hover, onClick = "volume permission",
            ui.row{ w = INNER, gap = 8,
                ui.symbol{ name = "lock.fill", w = 16, h = 16, color = "secondaryForeground" },
                ui.text{ text = omniwm.l10n("Allow System Audio Recording to set app volumes"), size = 13,
                    maxWidth = INNER - 24, lines = 2 } } }
    end
    local mixer = { w = style.width, style.heading(omniwm.l10n("Applications")) }
    for _, entry in if apps then apps.apps else {} do
        if entry.playing or entry.muted or entry.volume < 100 then
            mixer[#mixer + 1] = ui.row{ w = INNER, gap = 8,
                ui.icon{ app = entry.id, w = 18, h = 18, opacity = if entry.playing then 1 else 0.6 },
                ui.text{ text = entry.name, size = 13, w = 92, maxWidth = 92 },
                ui.slider{ value = entry.volume / 100, w = INNER - 162, h = 14,
                    color = if entry.muted then "mutedForeground" else "accent",
                    onChange = function(_, event)
                        if event.value then
                            omniwm.run(string.format("volume app %s set %d", entry.id, math.round(event.value * 100)))
                        end
                    end },
                style.button(if entry.muted then "speaker.slash.fill" else "speaker.wave.2.fill",
                    "volume app " .. entry.id .. " mute") }
        end
    end
    if #mixer > 1 then
        rows[#rows + 1] = style.group(mixer)
    end
    return ui.column(rows)
end

return audio
