-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")
local WIDTH = style.width
local RUNE = "M7 7.5 L17 16.5 L12 21 L12 3 L17 7.5 L7 16.5"
local KINDS = {
    headphones = "headphones",
    keyboard = "keyboard",
    mouse = "magicmouse",
    gamepad = "gamecontroller",
    phone = "iphone",
    computer = "laptopcomputer",
}

local function rune(size: number, color: string)
    return ui.path{ w = size, h = size, viewBox = { 0, 0, 24, 24 }, d = RUNE, border = color, borderWidth = 2.2 }
end

local function cell(level: number)
    local color = if level <= 20 then "error" else "foreground/0.75"
    return ui.row{ gap = 1,
        ui.stack{ w = 20, h = 10, radius = 3, border = "foreground/0.45", borderWidth = 1,
            ui.box{ align = "leading", dx = 2, w = math.max(1.5, 16 * level / 100), h = 6, radius = 1.5, fill = color } },
        ui.box{ w = 1.5, h = 4, radius = 0.75, fill = "foreground/0.45" } }
end

local function device(ctx: Context, entry)
    local row = { w = WIDTH - 24, gap = 8, pad = 4,
        ui.stack{ w = 32, h = 32, radius = 16, fill = if entry.connected then "accent" else "foreground/0.08",
            ui.symbol{ name = KINDS[entry.kind] or "dot.radiowaves.left.and.right", w = 16, h = 16,
                color = if entry.connected then "accentForeground" else "secondaryForeground" } },
        ui.column{ gap = 3, center = false, grow = 1,
            ui.text{ text = entry.name, size = 13, weight = if entry.connected then "medium" else nil, maxWidth = 156 },
            ui.text{ text = if entry.connected then omniwm.l10n("Connected") else omniwm.l10n("Not Connected"),
                size = 11, color = "secondaryForeground", maxWidth = 156 } } }
    if entry.connected and entry.battery then
        row[#row + 1] = ui.text{ text = ctx.format.percent(entry.battery / 100), size = 11,
            color = "secondaryForeground", maxWidth = 42 }
        row[#row + 1] = cell(entry.battery)
    end
    return ui.row(row)
end

function render(ctx: Context)
    local state = ctx.data.bluetooth
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local scale = style.scale(ctx)
    local connected = 0
    for _, entry in state.devices or {} do
        if entry.connected then
            connected += 1
        end
    end
    local color = if state.power then "foreground" else "secondaryForeground"
    local glyph = { w = 16 * scale, h = 16 * scale, rune(16 * scale, color) }
    if state.power and connected > 0 then
        glyph[#glyph + 1] = ui.box{ align = "bottomTrailing", w = 4 * scale, h = 4 * scale,
            radius = 2 * scale, fill = "accent" }
    end
    return style.bar(ctx, { onClick = ui.popout,
        help = if state.access ~= "granted" then omniwm.l10n("Bluetooth")
            elseif not state.power then omniwm.l10n("Bluetooth: Off")
            else omniwm.l10n("Bluetooth: %lld connected", connected), ui.stack(glyph) })
end

function popout(ctx: Context)
    local state = ctx.data.bluetooth
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local on = state.power
    local granted = state.access == "granted"
    local rows = {
        ui.row{ w = WIDTH,
            ui.text{ text = omniwm.l10n("Bluetooth"), size = 14, weight = "semibold", grow = 1 },
            if granted then ui.text{ text = if on then omniwm.l10n("On") else omniwm.l10n("Off"), size = 13,
                color = "secondaryForeground" } else nil } }
    if on then
        local devices = { w = WIDTH,
            ui.text{ text = omniwm.l10n("Devices"), size = 11, weight = "medium", color = "secondaryForeground" } }
        for _, entry in state.devices or {} do
            devices[#devices + 1] = device(ctx, entry)
        end
        rows[#rows + 1] = style.group(devices)
    end
    if not granted then
        rows[#rows + 1] = ui.row{ w = WIDTH, gap = 8, pad = 6, radius = 8, hover = style.hover,
            onClick = "bluetooth authorize",
            ui.symbol{ name = "lock.fill", w = 16, h = 16, color = "secondaryForeground" },
            ui.text{ text = omniwm.l10n("Allow Bluetooth access to list devices"), size = 13,
                maxWidth = WIDTH - 40, lines = 2 } }
    end
    rows[#rows + 1] = ui.row{ w = WIDTH, gap = 8, pad = 6, radius = 8, hover = style.hover,
        onClick = "bluetooth settings",
        ui.symbol{ name = "gearshape", w = 16, h = 16, color = "secondaryForeground" },
        ui.text{ text = omniwm.l10n("Bluetooth Settings…"), size = 13 } }
    return style.panel(rows)
end
