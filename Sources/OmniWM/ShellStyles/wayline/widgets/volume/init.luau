-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HUE = "red"
local HOVER = "foreground/0.07"
local WELL = "foreground/0.06"
local PRECISE_POINTS_PER_STEP = 12
local WIDTH = 360
local INNER = WIDTH - 32
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

local function block(size: number, radius: number, vertical: boolean, name: string)
    return ui.stack{ w = size, h = size,
        ui.box{ w = size, h = size, radius = radius, fill = HUE },
        ui.box{ align = vertical and "bottom" or "trailing", w = vertical and size or radius,
            h = vertical and radius or size, fill = HUE },
        ui.symbol{ name = name, size = math.floor(size * 0.52), weight = "semibold", color = "accentForeground" } }
end

local function well(size: number, selected: boolean, child)
    return ui.stack{ w = size, h = size, radius = 7, fill = selected and "accent/0.16" or WELL, child }
end

local function muteButton(name: string, command: string, muted: boolean)
    return ui.stack{ w = 28, h = 28, radius = 7, fill = muted and "error/0.16" or WELL, hover = HOVER, onClick = command,
        ui.symbol{ name = name, size = 12, weight = "semibold", color = muted and "error" or "secondaryForeground" } }
end

local function caps(text: string): string
    return if string.find(text, "[\128-\255]") then text else string.upper(text)
end

local function section(text: string)
    return ui.row{ w = INNER, h = 18,
        ui.box{ w = 2, h = 1 },
        ui.text{ text = caps(text), size = 12, weight = "bold", color = "mutedForeground" } }
end

local function divider()
    return ui.box{ w = CARD, h = 1, fill = "foreground/0.07" }
end

local function card(rows)
    local column = { w = INNER, gap = 0, pad = 0, radius = 9, fill = "elevatedSurface", center = true }
    for index, row in rows do
        if index > 1 then
            column[#column + 1] = divider()
        end
        column[#column + 1] = row
    end
    return ui.column(column)
end

local function audioApp(ctx, entry)
    local value = math.round(entry.volume)
    return ui.column{ w = CARD, gap = 6, pad = 0, center = false,
        ui.box{ w = 1, h = 4 },
        ui.row{ w = CARD, gap = 10,
            well(28, false, ui.icon{ app = entry.id, w = 18, h = 18, opacity = if entry.playing then 1 else 0.55 }),
            ui.text{ text = entry.name, size = 14, weight = "semibold",
                color = if entry.muted then "mutedForeground" else "foreground", maxWidth = 150 },
            ui.box{ grow = 1, h = 1 },
            ui.row{ w = 40, ui.box{ grow = 1, h = 1 },
                ui.text{ text = ctx.format.percent(value / 100), style = "mono", size = 12, weight = "semibold",
                    color = "mutedForeground" } },
            muteButton(if entry.muted then "speaker.slash.fill" else "speaker.wave.2.fill",
                "volume app " .. entry.id .. " mute", entry.muted) },
        ui.row{ w = CARD, gap = 0,
            ui.box{ w = 38, h = 1 },
            ui.slider{ value = entry.volume / 100, w = CARD - 38, h = 14,
                color = if entry.muted then "mutedForeground" else "accent",
                onChange = function(_, event)
                    if event.value then
                        omniwm.run(string.format("volume app %s set %d", entry.id, math.round(event.value * 100)))
                    end
                end } },
        ui.box{ w = 1, h = 6 } }
end

local function output(device)
    return ui.row{ w = CARD, h = 44, gap = 10, radius = 7, hover = HOVER, onClick = "volume output " .. device.id,
        well(30, device.default, ui.symbol{ name = TRANSPORT_SYMBOLS[device.transport] or "hifispeaker.fill",
            size = 13, weight = "semibold", color = device.default and "accent" or "secondaryForeground" }),
        ui.text{ text = device.name, size = 14, weight = device.default and "semibold" or "medium",
            color = "foreground", maxWidth = CARD - 70 },
        ui.box{ grow = 1, h = 1 },
        ui.symbol{ name = "checkmark", size = 11, weight = "bold", color = "accent",
            opacity = if device.default then 1 else 0 } }
end

local function defaultOutput(outputs)
    for _, device in outputs or {} do
        if device.default then
            return device
        end
    end
    return nil
end

function render(ctx)
    local volume = ctx.data.volume
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local radius = math.floor(size * 0.24)
    local glyph = block(size, radius, style.vertical, symbol(volume, ctx.data.muted))
    local hue = ctx.data.muted and "mutedForeground" or HUE
    local row = { gap = 0, radius = radius, fill = "elevatedSurface", hoverOpacity = 0.9, onClick = ui.popout,
        onScroll = scroll, glyph }
    if style.vertical then
        row.w = size
        row.gap = 2
        if volume then
            row[#row + 1] = ui.text{ text = tostring(volume), style = "mono", size = 14 * scale, weight = "semibold", color = hue }
            row[#row + 1] = ui.box{ w = 1, h = 3 }
        end
        return ui.column(row)
    end
    row.h = size
    if volume then
        row[#row + 1] = ui.box{ w = 8, h = 1 }
        row[#row + 1] = ui.text{ text = ctx.format.percent(volume / 100), style = "mono", size = 14 * scale, weight = "semibold",
            color = hue, reserve = ctx.format.percent(1) }
        row[#row + 1] = ui.box{ w = 9, h = 1 }
    end
    return ui.row(row)
end

function popout(ctx)
    local volume = ctx.data.volume
    local muted = ctx.data.muted
    local outputs = ctx.data.outputs
    local current = defaultOutput(outputs)
    local frame = { w = WIDTH, gap = 0, material = "clear", attach = true, radius = 12, fill = "surface",
        border = "border", borderWidth = 1, center = false }
    local headerRow = { w = INNER, gap = 8,
        ui.symbol{ name = "speaker.wave.2.fill", size = 13, weight = "semibold", color = "accent" },
        ui.text{ text = omniwm.l10n("Sound"), size = 14, weight = "bold", color = "foreground" },
        ui.box{ grow = 1, h = 1 } }
    if volume then
        headerRow[#headerRow + 1] = muteButton(if muted then "speaker.slash.fill" else "speaker.wave.2.fill",
            "volume mute", muted == true)
    end
    frame[#frame + 1] = ui.stack{ w = WIDTH, h = 44,
        ui.box{ w = WIDTH, h = 44, radius = 12, fill = "elevatedSurface" },
        ui.box{ align = "bottom", w = WIDTH, h = 12, fill = "elevatedSurface" },
        ui.row(headerRow) }
    frame[#frame + 1] = ui.box{ w = WIDTH, h = 1, fill = "border" }
    local body = { w = WIDTH, pad = 16, gap = 8, center = false }
    local outputRows = {}
    if volume then
        outputRows[#outputRows + 1] = ui.column{ w = CARD, gap = 8, center = false,
            ui.box{ w = 1, h = 4 },
            ui.row{ w = CARD, gap = 10,
                well(30, false, ui.symbol{ name = symbol(volume, muted), size = 13, weight = "semibold",
                    color = muted and "mutedForeground" or "secondaryForeground" }),
                ui.column{ gap = 1, center = false,
                    ui.text{ text = caps(omniwm.l10n("Output")), size = 12, weight = "bold",
                        color = "mutedForeground" },
                    ui.text{ text = current and current.name or omniwm.l10n("Output"), size = 14, weight = "semibold",
                        color = "foreground", maxWidth = CARD - 90 } },
                ui.box{ grow = 1, h = 1 },
                ui.text{ text = ctx.format.percent(volume / 100), style = "mono", size = 14, weight = "bold",
                    color = muted and "mutedForeground" or "foreground", reserve = ctx.format.percent(1) } },
            ui.slider{ value = volume / 100, w = CARD, h = 16, color = if muted then "mutedForeground" else "accent",
                onChange = slide },
            ui.box{ w = 1, h = 4 } }
    end
    local devices = {}
    for _, device in outputs or {} do
        devices[#devices + 1] = output(device)
    end
    if #outputRows > 0 then
        body[#body + 1] = card(outputRows)
    end
    if #devices > 0 then
        local list = { w = INNER, gap = 2, pad = 4, radius = 9, fill = "elevatedSurface", center = true }
        for _, row in devices do
            list[#list + 1] = row
        end
        body[#body + 1] = ui.column(list)
    end
    local audio = ctx.data.audioApps
    local apps = {}
    if audio and audio.access == "denied" then
        apps[#apps + 1] = ui.row{ w = CARD, h = 44, gap = 10, radius = 7, hover = HOVER, onClick = "volume permission",
            well(28, false, ui.symbol{ name = "lock.fill", size = 12, color = "warning" }),
            ui.text{ text = omniwm.l10n("Allow System Audio Recording to set app volumes"), size = 12,
                weight = "medium", color = "foreground", maxWidth = CARD - 40, lines = 2 } }
    end
    for _, entry in if audio then audio.apps else {} do
        if entry.playing or entry.muted or entry.volume < 100 then
            apps[#apps + 1] = audioApp(ctx, entry)
        end
    end
    if #apps > 0 then
        body[#body + 1] = ui.box{ w = 1, h = 2 }
        body[#body + 1] = section(omniwm.l10n("Applications"))
        body[#body + 1] = card(apps)
    end
    frame[#frame + 1] = ui.column(body)
    return ui.column(frame)
end
