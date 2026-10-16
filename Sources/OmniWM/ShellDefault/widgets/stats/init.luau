-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local SAMPLES = 30
local RING = "M12 2.5 A9.5 9.5 0 1 1 12 21.5 A9.5 9.5 0 1 1 12 2.5"

local function history(ctx, key: string): { number }
    local all = ctx.state.history
    if not all then
        all = { cpu = {}, memory = {} }
        ctx.state.history = all
    end
    local cpu = ctx.data.cpu
    if cpu and all.sampled ~= cpu then
        all.sampled = cpu
        for name, value in { cpu = cpu, memory = ctx.data.memory } do
            local list = all[name]
            list[#list + 1] = value
            if #list > SAMPLES then
                table.remove(list, 1)
            end
        end
    end
    return all[key]
end

local function arc(fraction: number): string
    if fraction >= 0.999 then
        return RING
    end
    local angle = fraction * 2 * math.pi
    return string.format("M12 2.5 A9.5 9.5 0 %d 1 %.2f %.2f", if angle > math.pi then 1 else 0,
        12 + 9.5 * math.sin(angle), 12 - 9.5 * math.cos(angle))
end

local function gauge(value: number, size: number, color: string, center)
    local ring = { w = size, h = size,
        ui.path{ w = size, h = size, viewBox = { 0, 0, 24, 24 }, d = RING, border = "foreground/0.16",
            borderWidth = 2.6 } }
    if value > 0.5 then
        ring[#ring + 1] = ui.path{ w = size, h = size, viewBox = { 0, 0, 24, 24 }, d = arc(value / 100),
            border = color, borderWidth = 2.6, animate = "ease" }
    end
    ring[#ring + 1] = center
    return ui.stack(ring)
end

local function sparkline(values: { number }, w: number, h: number, color: string)
    if #values < 2 then
        return ui.box{ w = w, h = h }
    end
    local last = #values - 1
    local line = {}
    for index, value in values do
        line[#line + 1] = string.format("%s%d %.1f", if index == 1 then "M" else "L", index - 1, 100 - value)
    end
    local stroke = table.concat(line, " ")
    return ui.stack{ w = w, h = h,
        ui.path{ w = w, h = h, viewBox = { 0, -4, last, 108 },
            d = stroke .. string.format(" L%d 104 L0 104 Z", last), fill = color .. "/0.1" },
        ui.path{ w = w, h = h, viewBox = { 0, -4, last, 108 }, d = stroke, border = color, borderWidth = 1.4 } }
end

local function meter(ctx, key: string, symbol: string, value: number, variant: string)
    local color = if value >= 90 then "warning" else "accent"
    local style = ctx.data.bar.style
    if variant == "gauge" then
        local size = math.max(18, style.height - 8)
        return gauge(value, size, color,
            ui.text{ text = tostring(math.round(value)), style = "mono", size = size * 0.36, weight = "semibold" })
    end
    if style.vertical then
        return ui.column{ gap = 1,
            ui.symbol{ name = symbol },
            ui.text{ text = tostring(value), style = "mono", size = 9 } }
    end
    local reading = ui.text{ text = ctx.format.percent(value / 100), style = "mono", reserve = ctx.format.percent(1) }
    if variant == "graph" then
        return ui.row{ gap = 5,
            ui.symbol{ name = symbol, color = "secondaryForeground" },
            sparkline(history(ctx, key), 34, 16, color),
            reading }
    end
    return ui.row{ gap = 4,
        ui.symbol{ name = symbol },
        reading,
        ui.progress{ value = value / 100, w = 24, h = 4, radius = 2, fill = "foreground/0.15",
            color = color, animate = "ease" } }
end

local function rate(ctx, bytes: number): string
    return ctx.format.bytes(bytes, "file") .. "/s"
end

local function line(symbol: string, label: string, text: string, extra)
    return ui.row{ gap = 8,
        ui.symbol{ name = symbol, w = 14, h = 14, color = "secondaryForeground" },
        ui.text{ text = label, w = 70 },
        ui.text{ text = text, style = "mono", reserve = "000.0 MB/s" },
        extra }
end

function render(ctx)
    local style = ctx.data.bar.style
    local vertical = style.vertical
    local variant = (ctx.data.settings or {}).variant or "meters"
    local capsule = style.transparent and style.backgrounds
    local size = math.max(16, style.height - 4)
    local item = { gap = if vertical then 6 else 10, pad = 2, radius = 4, hover = "foreground/0.12",
        onClick = ui.popout,
        meter(ctx, "cpu", "cpu", ctx.data.cpu or 0, variant),
        meter(ctx, "memory", "memorychip", ctx.data.memory, variant) }
    if capsule then
        item.pad = nil
        item.gap = if variant == "gauge" then 4 else 10
        item.radius = size / 2
        item.fill = "surface"
        item.border = "border"
        item.borderWidth = 0.5
        item[if vertical then "w" else "h"] = size
        local edge = if variant == "gauge" then 3 else 8
        table.insert(item, 1, if vertical then ui.box{ w = 1, h = edge } else ui.box{ w = edge, h = 1 })
        item[#item + 1] = if vertical then ui.box{ w = 1, h = edge } else ui.box{ w = edge, h = 1 }
    end
    return if vertical then ui.column(item) else ui.row(item)
end

function popout(ctx)
    local data = ctx.data
    local percent = ctx.format.percent
    local style = data.bar.style
    local graph = (data.settings or {}).variant == "graph"
    local rows = { gap = 6, pad = 10, center = false,
        line("cpu", omniwm.l10n("CPU"), data.cpu and percent(data.cpu / 100) or "—",
            graph and sparkline(history(ctx, "cpu"), 90, 18, "accent") or nil),
        line("memorychip", omniwm.l10n("Memory"), percent(data.memory / 100),
            graph and sparkline(history(ctx, "memory"), 90, 18, "accent") or nil) }
    if data.gpu then
        rows[#rows + 1] = line("cube", omniwm.l10n("GPU"), percent(data.gpu / 100))
    end
    if data.disk then
        rows[#rows + 1] = line("internaldrive", omniwm.l10n("Disk"), percent(data.disk / 100))
    end
    if data.network then
        rows[#rows + 1] = line("arrow.down", omniwm.l10n("Download"), rate(ctx, data.network.down))
        rows[#rows + 1] = line("arrow.up", omniwm.l10n("Upload"), rate(ctx, data.network.up))
    end
    if style.transparent and style.backgrounds then
        rows.material = "clear"
        rows.fill = "background"
        rows.border = "border"
        rows.borderWidth = 1
        rows.radius = 14
    end
    return ui.column(rows)
end
