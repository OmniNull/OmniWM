-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local panel = require("../lib/panel")

local HOVER = "focus/0.14"
local WIDTH = 340
local INNER = WIDTH - 2 - 24
local CARD = INNER - 20

local function arc(size: number, stroke: number, value: number): string?
    local fraction = math.clamp(value, 0, 1)
    if fraction <= 0.001 then
        return nil
    end
    local c = size / 2
    local r = c - stroke / 2
    if fraction >= 0.999 then
        return string.format("M%g %g A%g %g 0 1 1 %g %g A%g %g 0 1 1 %g %g", c, c - r, r, r, c, c + r, r, r, c, c - r)
    end
    local angle = (fraction * 2 - 0.5) * math.pi
    return string.format("M%g %g A%g %g 0 %d 1 %.2f %.2f", c, c - r, r, r, fraction > 0.5 and 1 or 0,
        c + r * math.cos(angle), c + r * math.sin(angle))
end

local function ring(size: number, stroke: number, value: number, tint: string)
    local c = size / 2
    local r = c - stroke / 2
    local track = string.format("M%g %g A%g %g 0 1 1 %g %g A%g %g 0 1 1 %g %g",
        c, c - r, r, r, c, c + r, r, r, c, c - r)
    local d = arc(size, stroke, value)
    return ui.stack{ w = size, h = size,
        ui.path{ w = size, h = size, d = track, border = "foreground/0.14", borderWidth = stroke },
        if d then ui.path{ w = size, h = size, d = d, border = tint, borderWidth = stroke } else nil }
end

local function meter(ctx, value: number, tint: string, vertical: boolean)
    local scale = ctx.data.bar.style.height / 40
    local color = value >= 90 and "warning" or tint
    if vertical then
        return ui.column{ gap = 2 * scale, ring(18 * scale, 2.5 * scale, value / 100, color),
            ui.text{ text = tostring(value), style = "mono", size = 14 * scale, weight = "semibold" } }
    end
    return ui.row{ gap = 5 * scale, ring(18 * scale, 2.5 * scale, value / 100, color),
        ui.text{ text = ctx.format.percent(value / 100), size = 14 * scale, weight = "semibold",
            reserve = ctx.format.percent(1) } }
end

local function rate(ctx, bytes: number): string
    return ctx.format.bytes(bytes, "file") .. "/s"
end

function render(ctx)
    local style = ctx.data.bar.style
    local vertical = style.vertical
    local scale = style.height / 40
    local size = 32 * scale
    local fill = style.backgrounds and "surface" or nil
    local edge = style.backgrounds and "border/0.6" or nil
    local item = { gap = if vertical then 6 else 9, radius = size / 2 - 1, fill = fill, border = edge, borderWidth = 1,
        hover = HOVER, onClick = ui.popout,
        if vertical then ui.box{ w = 1, h = 3 } else ui.box{ w = 1, h = 1 },
        meter(ctx, ctx.data.cpu or 0, "accent", vertical),
        meter(ctx, ctx.data.memory, "blue", vertical),
        if vertical then ui.box{ w = 1, h = 3 } else ui.box{ w = 0, h = 1 } }
    if vertical then
        item.w = size
        return ui.column(item)
    end
    item.h = size
    return ui.row(item)
end

local function line(symbol: string, tint: string, label: string, text: string, fraction: number?)
    local row = { w = CARD, gap = 9,
        ui.stack{ w = 24, h = 24, radius = 12, fill = tint .. "/0.18",
            ui.symbol{ name = symbol, size = 11, weight = "semibold", color = tint } },
        ui.text{ text = label, size = 14, weight = "medium", w = 72, maxWidth = 72 },
        ui.box{ grow = 1, h = 1 } }
    if fraction then
        row[#row + 1] = ui.progress{ value = math.clamp(fraction, 0, 1), w = 44, h = 5, radius = 2.5,
            fill = "foreground/0.12", color = fraction >= 0.9 and "warning" or tint, animate = "ease" }
    end
    row[#row + 1] = ui.row{ w = 74, ui.box{ grow = 1, h = 1 },
        ui.text{ text = text, style = "mono", size = 12, weight = "semibold" } }
    return ui.row(row)
end

function popout(ctx)
    local data = ctx.data
    local percent = ctx.format.percent
    local rows = { gap = 8,
        line("cpu", "accent", omniwm.l10n("CPU"), data.cpu and percent(data.cpu / 100) or "—",
            data.cpu and data.cpu / 100),
        line("memorychip", "blue", omniwm.l10n("Memory"), percent(data.memory / 100), data.memory / 100) }
    if data.gpu then
        rows[#rows + 1] = line("cube", "purple", omniwm.l10n("GPU"), percent(data.gpu / 100), data.gpu / 100)
    end
    if data.disk then
        rows[#rows + 1] = line("internaldrive", "orange", omniwm.l10n("Disk"), percent(data.disk / 100),
            data.disk / 100)
    end
    if data.network then
        rows[#rows + 1] = line("arrow.down", "green", omniwm.l10n("Download"), rate(ctx, data.network.down), nil)
        rows[#rows + 1] = line("arrow.up", "teal", omniwm.l10n("Upload"), rate(ctx, data.network.up), nil)
    end
    return panel(data.bar.style, WIDTH, ui.column{ w = WIDTH - 2, pad = 12, center = false,
        ui.column{ w = INNER, pad = 10, radius = 14, fill = "surface", border = "border", borderWidth = 1,
            center = false, ui.column(rows) } })
end
