-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")
local WIDTH = style.width
local SPREAD = math.rad(45)
local BANDS = { { 0, 2.8 }, { 5.2, 7.8 }, { 10, 12.6 }, { 14.8, 17.4 } }

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

local function glyph(state, size: number)
    if not state.power then
        return ui.symbol{ name = "wifi.slash", size = size, color = "secondaryForeground" }
    end
    return fan(if state.connected then bars(state.rssi) else -1, size, "foreground")
end

local function detail(symbol: string, label: string, value: string)
    return ui.row{ w = WIDTH - 24, gap = 8,
        ui.symbol{ name = symbol, w = 16, h = 16, color = "secondaryForeground" },
        ui.text{ text = label, size = 13, color = "secondaryForeground", grow = 1, maxWidth = 88 },
        ui.text{ text = value, size = 12, maxWidth = WIDTH - 152 } }
end

local function action(symbol: string, text: string, command: string)
    return ui.row{ w = WIDTH, gap = 8, pad = 6, radius = 8, hover = style.hover, onClick = command,
        ui.symbol{ name = symbol, w = 16, h = 16, color = "secondaryForeground" },
        ui.text{ text = text, size = 13, maxWidth = WIDTH - 40, lines = 2 } }
end

function render(ctx: Context)
    local state = ctx.data.wifi
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = style.scale(ctx)
    local help = if not state.power then omniwm.l10n("Wi-Fi: Off")
        elseif state.ssid then state.ssid
        elseif state.connected then omniwm.l10n("Wi-Fi: Connected")
        else omniwm.l10n("Wi-Fi: Not Connected")
    return style.bar(ctx, { onClick = ui.popout, help = help, glyph(state, 16 * scale) })
end

function popout(ctx: Context)
    local state = ctx.data.wifi
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local on = state.power
    local rows = {
        ui.row{ w = WIDTH,
            ui.text{ text = omniwm.l10n("Wi-Fi"), size = 14, weight = "semibold", grow = 1 },
            ui.text{ text = if on then omniwm.l10n("On") else omniwm.l10n("Off"), size = 13,
                color = "secondaryForeground" } } }
    if on and state.connected then
        local card = { w = WIDTH,
            ui.row{ w = WIDTH - 24, gap = 12,
                ui.stack{ w = 36, h = 36, radius = 18, fill = "accent", fan(bars(state.rssi), 20, "accentForeground") },
                ui.column{ gap = 3, center = false,
                    ui.text{ text = state.ssid or omniwm.l10n("Network name hidden"), size = 13, weight = "medium",
                        maxWidth = WIDTH - 72 },
                    ui.text{ text = omniwm.l10n("Connected"), size = 11, color = "secondaryForeground" } } } }
        if state.rssi then
            card[#card + 1] = detail("cellularbars", omniwm.l10n("Signal"),
                string.format("%d dBm · %s", state.rssi, quality(state.rssi)))
        end
        if state.band then
            card[#card + 1] = detail("antenna.radiowaves.left.and.right", omniwm.l10n("Band"),
                if state.channel then string.format("%s · %d", state.band, state.channel) else state.band)
        end
        if state.security then
            card[#card + 1] = detail("lock", omniwm.l10n("Security"), state.security)
        end
        rows[#rows + 1] = style.group(card)
    elseif on then
        rows[#rows + 1] = style.group{ w = WIDTH,
            ui.text{ text = omniwm.l10n("Not Connected"), size = 13, color = "secondaryForeground" } }
    end
    if on and state.location ~= "authorized" then
        rows[#rows + 1] = action("location.fill", omniwm.l10n("Allow Location Access to show the network name"),
            "wifi authorize")
    end
    rows[#rows + 1] = action("gearshape", omniwm.l10n("Wi-Fi Settings…"), "wifi settings")
    return style.panel(rows)
end
