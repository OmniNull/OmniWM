-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HOVER = "foreground/0.12"
local WIDTH = 272
local SPREAD = math.rad(45)
local BANDS = { { 0, 2.8 }, { 5.2, 7.8 }, { 10, 12.6 }, { 14.8, 17.4 } }

local function wifi(ctx: Context)
    return ctx.data.wifi
end

local function bars(rssi: number?): number
    if not rssi then
        return 0
    end
    if rssi >= -60 then
        return 3
    end
    if rssi >= -70 then
        return 2
    end
    return if rssi >= -80 then 1 else 0
end

local function quality(rssi: number): string
    if rssi >= -60 then
        return omniwm.l10n("Excellent")
    end
    if rssi >= -70 then
        return omniwm.l10n("Good")
    end
    return if rssi >= -80 then omniwm.l10n("Fair") else omniwm.l10n("Weak")
end

local function sector(inner: number, outer: number): string
    local x, y = math.sin(SPREAD), math.cos(SPREAD)
    return string.format("M%.2f %.2f A%.2f %.2f 0 0 1 %.2f %.2f L%.2f %.2f A%.2f %.2f 0 0 0 %.2f %.2f Z",
        12 - outer * x, 20.5 - outer * y, outer, outer, 12 + outer * x, 20.5 - outer * y,
        12 + inner * x, 20.5 - inner * y, inner, inner, 12 - inner * x, 20.5 - inner * y)
end

local function fan(level: number, size: number, color: string)
    local stack = { w = size, h = size }
    for index, band in BANDS do
        stack[#stack + 1] = ui.path{ w = size, h = size, viewBox = { 0, 0, 24, 24 }, d = sector(band[1], band[2]),
            fill = if index - 1 <= level then color else "foreground/0.2" }
    end
    return ui.stack(stack)
end

local function glyph(state, size: number, color: string)
    if not state or not state.power then
        return ui.symbol{ name = "wifi.slash", size = size * 0.8, color = "mutedForeground" }
    end
    if not state.connected then
        return fan(-1, size, color)
    end
    return fan(bars(state.rssi), size, color)
end

local function panel(style: BarStyle, props)
    if style.transparent and style.backgrounds then
        props.material = "clear"
        props.fill = "background"
        props.border = "border"
        props.borderWidth = 1
        props.radius = 14
    end
    return ui.column(props)
end

local function detail(symbol: string, label: string, value: string)
    return ui.row{ w = WIDTH - 44, gap = 8,
        ui.symbol{ name = symbol, w = 14, h = 14, color = "secondaryForeground" },
        ui.text{ text = label, color = "secondaryForeground", grow = 1 },
        ui.text{ text = value, style = "mono", size = 11, maxWidth = 150 } }
end

local function action(symbol: string, text: string, command: string)
    return ui.row{ w = WIDTH - 20, gap = 10, pad = 6, radius = 8, hover = HOVER, onClick = command,
        ui.symbol{ name = symbol, w = 14, h = 14, color = "secondaryForeground" },
        ui.text{ text = text, maxWidth = WIDTH - 60, lines = 2 } }
end

function render(ctx: Context)
    local state = wifi(ctx)
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local size = math.max(16, style.height - 4)
    local capsule = style.transparent and style.backgrounds
    local help = if not state.power then omniwm.l10n("Wi-Fi: Off")
        elseif state.ssid then state.ssid
        elseif state.connected then omniwm.l10n("Wi-Fi: Connected")
        else omniwm.l10n("Wi-Fi: Not Connected")
    return ui.stack{ w = size, h = size, radius = if capsule then size / 2 else 4,
        fill = if capsule then "surface" else nil, border = if capsule then "border" else nil, borderWidth = 0.5,
        hover = HOVER, onClick = ui.popout, help = help,
        glyph(state, math.round(size * 0.62), if capsule then "accent" else "foreground") }
end

function popout(ctx: Context)
    local state = wifi(ctx)
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local on = state.power
    local rows = { w = WIDTH, gap = 8, pad = 10, center = false,
        ui.row{ w = WIDTH - 20, gap = 10, pad = 4,
            ui.text{ text = omniwm.l10n("Wi-Fi"), style = "bold", grow = 1 },
            ui.row{ h = 20, radius = 10, fill = if on then "accent/0.16" else "foreground/0.08",
                ui.box{ w = 9, h = 1 },
                ui.text{ text = if on then omniwm.l10n("On") else omniwm.l10n("Off"), size = 11, weight = "semibold",
                    color = if on then "accent" else "secondaryForeground" },
                ui.box{ w = 9, h = 1 } } } }
    if on and state.connected then
        local card = { w = WIDTH - 20, gap = 8, pad = 12, radius = 12, fill = "surface", center = false,
            ui.row{ gap = 10,
                ui.stack{ w = 32, h = 32, radius = 16, fill = "accent",
                    fan(bars(state.rssi), 18, "accentForeground") },
                ui.column{ gap = 1, center = false,
                    ui.text{ text = state.ssid or omniwm.l10n("Network name hidden"), style = "bold",
                        maxWidth = WIDTH - 90 },
                    ui.text{ text = omniwm.l10n("Connected"), style = "small", color = "secondaryForeground" } } } }
        if state.rssi then
            card[#card + 1] = detail("cellularbars", omniwm.l10n("Signal"),
                string.format("%d dBm · %s", state.rssi, quality(state.rssi)))
        end
        if state.band then
            card[#card + 1] = detail("antenna.radiowaves.left.and.right", omniwm.l10n("Band"),
                if state.channel then string.format("%s · %d", state.band, state.channel)
                    else state.band)
        end
        if state.security then
            card[#card + 1] = detail("lock", omniwm.l10n("Security"), state.security)
        end
        rows[#rows + 1] = ui.column(card)
    elseif on then
        rows[#rows + 1] = ui.text{ text = omniwm.l10n("Not Connected"), color = "secondaryForeground" }
    end
    if on and state.location ~= "authorized" then
        rows[#rows + 1] = action("location.fill", omniwm.l10n("Allow Location Access to show the network name"),
            "wifi authorize")
    end
    rows[#rows + 1] = action("gearshape", omniwm.l10n("Wi-Fi Settings…"), "wifi settings")
    return panel(ctx.data.bar.style, rows)
end
