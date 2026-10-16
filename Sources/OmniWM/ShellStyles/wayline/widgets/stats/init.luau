-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local WIDTH = 340
local INNER = WIDTH - 24

local function block(size: number, radius: number, vertical: boolean, hue: string, name: string)
    return ui.stack{ w = size, h = size,
        ui.box{ w = size, h = size, radius = radius, fill = hue },
        ui.box{ align = vertical and "bottom" or "trailing", w = vertical and size or radius,
            h = vertical and radius or size, fill = hue },
        ui.symbol{ name = name, size = math.floor(size * 0.52), weight = "semibold", color = "accentForeground" } }
end

local function meter(ctx, symbol: string, value: number, hue: string)
    local style = ctx.data.bar.style
    local scale = style.height / 40
    local size = 32 * scale
    local radius = math.floor(size * 0.24)
    local color = value >= 90 and "red" or hue
    local foreground = style.textColor ~= nil and "foreground" or color
    if style.vertical then
        return ui.column{ w = size, gap = 2, radius = radius, fill = style.backgrounds and "elevatedSurface" or nil,
            block(size, radius, true, color, symbol),
            ui.text{ text = tostring(value), style = "mono", size = 14 * scale, weight = "semibold", color = foreground },
            ui.box{ w = 1, h = 3 } }
    end
    return ui.row{ h = size, gap = 0, radius = radius, fill = style.backgrounds and "elevatedSurface" or nil,
        block(size, radius, false, color, symbol),
        ui.box{ w = 8, h = 1 },
        ui.text{ text = ctx.format.percent(value / 100), style = "mono", size = 14 * scale, weight = "semibold", color = foreground,
            reserve = ctx.format.percent(1) },
        ui.box{ w = 9, h = 1 } }
end

local function rate(ctx, bytes: number): string
    return ctx.format.bytes(bytes, "file") .. "/s"
end

local function line(symbol: string, label: string, text: string, hue: string, first: boolean)
    local row = ui.row{ w = INNER, h = 38, gap = 10, pad = 0,
        ui.box{ w = 2, h = 1 },
        ui.stack{ w = 26, h = 26, radius = 6, fill = hue .. "/0.16",
            ui.symbol{ name = symbol, size = 12, weight = "semibold", color = hue } },
        ui.text{ text = label, size = 14, weight = "semibold", color = "foreground" },
        ui.box{ grow = 1, h = 1 },
        ui.text{ text = text, style = "mono", size = 14, weight = "semibold", color = "secondaryForeground" },
        ui.box{ w = 2, h = 1 } }
    if first then
        return row
    end
    return ui.column{ gap = 0, ui.box{ w = INNER - 16, h = 1, fill = "foreground/0.07" }, row }
end

function render(ctx)
    local vertical = ctx.data.bar.style.vertical
    local item = { gap = 6, onClick = ui.popout,
        meter(ctx, "cpu", ctx.data.cpu or 0, "blue"),
        meter(ctx, "memorychip", ctx.data.memory, "green") }
    return if vertical then ui.column(item) else ui.row(item)
end

function popout(ctx)
    local data = ctx.data
    local percent = ctx.format.percent
    local entries = {
        { "cpu", omniwm.l10n("CPU"), data.cpu and percent(data.cpu / 100) or "—", "blue" },
        { "memorychip", omniwm.l10n("Memory"), percent(data.memory / 100), "green" },
    }
    if data.gpu then
        entries[#entries + 1] = { "cube", omniwm.l10n("GPU"), percent(data.gpu / 100), "purple" }
    end
    if data.disk then
        entries[#entries + 1] = { "internaldrive", omniwm.l10n("Disk"), percent(data.disk / 100), "yellow" }
    end
    if data.network then
        entries[#entries + 1] = { "arrow.down", omniwm.l10n("Download"), rate(ctx, data.network.down), "accent" }
        entries[#entries + 1] = { "arrow.up", omniwm.l10n("Upload"), rate(ctx, data.network.up), "red" }
    end
    local card = { w = INNER, gap = 0, pad = 0, radius = 8, fill = "elevatedSurface", center = true }
    for index, entry in entries do
        card[#card + 1] = line(entry[1], entry[2], entry[3], entry[4], index == 1)
    end
    return ui.column{ w = WIDTH, pad = 12, gap = 0, material = "clear", radius = 12, fill = "surface",
        border = "border", borderWidth = 1, center = false,
        ui.column(card) }
end
