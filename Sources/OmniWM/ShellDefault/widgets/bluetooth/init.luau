-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HOVER = "foreground/0.12"
local WIDTH = 272
local RUNE = "M7 7.5 L17 16.5 L12 21 L12 3 L17 7.5 L7 16.5"
local KINDS = {
    headphones = "headphones",
    keyboard = "keyboard",
    mouse = "magicmouse",
    gamepad = "gamecontroller",
    phone = "iphone",
    computer = "laptopcomputer",
}

local function bluetooth(ctx: Context)
    return ctx.data.bluetooth
end

local function rune(size: number, color: string)
    return ui.path{ w = size, h = size, viewBox = { 0, 0, 24, 24 }, d = RUNE, border = color, borderWidth = 2.2 }
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

local function cell(level: number)
    local color = if level <= 20 then "error" else "foreground/0.75"
    return ui.row{ gap = 1,
        ui.stack{ w = 20, h = 10, radius = 3, border = "foreground/0.45", borderWidth = 1,
            ui.box{ align = "leading", dx = 2, w = math.max(1.5, 16 * level / 100), h = 6, radius = 1.5, fill = color } },
        ui.box{ w = 1.5, h = 4, radius = 0.75, fill = "foreground/0.45" } }
end

local function device(ctx: Context, entry)
    local row = { w = WIDTH - 16, gap = 10, pad = 6, radius = 8,
        ui.stack{ w = 30, h = 30, radius = 15, fill = if entry.connected then "accent" else "foreground/0.08",
            ui.symbol{ name = KINDS[entry.kind] or "dot.radiowaves.left.and.right", w = 16, h = 16,
                color = if entry.connected then "accentForeground" else "secondaryForeground" } },
        ui.column{ gap = 1, center = false, grow = 1,
            ui.text{ text = entry.name, maxWidth = 140, weight = if entry.connected then "semibold" else nil },
            ui.text{ text = if entry.connected then omniwm.l10n("Connected") else omniwm.l10n("Not Connected"),
                style = "small", color = "secondaryForeground" } } }
    if entry.connected and entry.battery then
        row[#row + 1] = ui.text{ text = ctx.format.percent(entry.battery / 100), style = "mono", size = 11,
            color = "secondaryForeground" }
        row[#row + 1] = cell(entry.battery)
    end
    return ui.row(row)
end

function render(ctx: Context)
    local state = bluetooth(ctx)
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local style = ctx.data.bar.style
    local size = math.max(16, style.height - 4)
    local capsule = style.transparent and style.backgrounds
    local connected = 0
    for _, entry in state.devices or {} do
        if entry.connected then
            connected += 1
        end
    end
    local color = if not state.power then "mutedForeground" elseif capsule then "accent" else "foreground"
    local item = { w = size, h = size, radius = if capsule then size / 2 else 4,
        fill = if capsule then "surface" else nil, border = if capsule then "border" else nil, borderWidth = 0.5,
        hover = HOVER, onClick = ui.popout,
        help = if state.access ~= "granted" then omniwm.l10n("Bluetooth")
            elseif not state.power then omniwm.l10n("Bluetooth: Off")
            else omniwm.l10n("Bluetooth: %lld connected", connected),
        rune(math.round(size * 0.58), color) }
    if state.power and connected > 0 then
        local dot = math.max(5, math.round(size * 0.2))
        item[#item + 1] = ui.box{ align = "bottomTrailing", dx = -math.round(size * 0.14), dy = -math.round(size * 0.14),
            w = dot, h = dot, radius = dot / 2, fill = "accent", border = "surface", borderWidth = 1 }
    end
    return ui.stack(item)
end

function popout(ctx: Context)
    local state = bluetooth(ctx)
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local on = state.power
    local granted = state.access == "granted"
    local rows = { w = WIDTH, gap = 4, pad = 8, center = false,
        ui.row{ w = WIDTH - 16, gap = 10, pad = 6,
            ui.text{ text = omniwm.l10n("Bluetooth"), style = "bold", grow = 1 },
            if granted then ui.row{ h = 20, radius = 10, fill = if on then "accent/0.16" else "foreground/0.08",
                ui.box{ w = 9, h = 1 },
                ui.text{ text = if on then omniwm.l10n("On") else omniwm.l10n("Off"), size = 11, weight = "semibold",
                    color = if on then "accent" else "secondaryForeground" },
                ui.box{ w = 9, h = 1 } } else nil } }
    if on then
        rows[#rows + 1] = ui.row{ pad = 6, ui.text{ text = omniwm.l10n("Devices"), size = 11, weight = "semibold",
            color = "secondaryForeground" } }
        for _, entry in state.devices or {} do
            rows[#rows + 1] = device(ctx, entry)
        end
    end
    if state.access ~= "granted" then
        rows[#rows + 1] = ui.row{ w = WIDTH - 16, gap = 10, pad = 6, radius = 8, hover = HOVER,
            onClick = "bluetooth authorize",
            ui.symbol{ name = "lock.fill", w = 14, h = 14 },
            ui.text{ text = omniwm.l10n("Allow Bluetooth access to list devices"), maxWidth = WIDTH - 60, lines = 2 } }
    end
    rows[#rows + 1] = ui.box{ w = WIDTH - 28, h = 1, fill = "border" }
    rows[#rows + 1] = ui.row{ w = WIDTH - 16, gap = 10, pad = 6, radius = 8, hover = HOVER,
        onClick = "bluetooth settings",
        ui.symbol{ name = "gearshape", w = 14, h = 14, color = "secondaryForeground" },
        ui.text{ text = omniwm.l10n("Bluetooth Settings…") } }
    return panel(ctx.data.bar.style, rows)
end
