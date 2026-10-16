-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

spanIslands = true
interval = 1

local width = 380
local padding = 16
local content = width - padding * 2
local inner = content - 20
local ring = 54
local stroke = 5

local function secondaryHasContent(bar: Bar): boolean
    if #bar.scratchpads > 0 then
        return true
    end
    for _, workspace in ipairs(bar.workspaces) do
        if not workspace.focused then
            return true
        end
    end
    return false
end

function render(ctx: Context)
    local bar = ctx.data.bar
    local style = bar.style
    if not style.statsButton or (bar.island ~= "all" and (bar.island == "secondary") ~= secondaryHasContent(bar)) then
        return ui.row{}
    end
    local scale = style.height / 40
    local size = 32 * scale
    return ui.stack{ w = size, h = size, radius = math.floor(size * 0.24), fill = style.backgrounds and "elevatedSurface" or nil,
        hover = "foreground/0.08", onClick = ui.popout, help = omniwm.l10n("Show system stats"),
        ui.symbol{ name = "gauge.with.needle", size = math.floor(size * 0.52), weight = "semibold",
            color = style.textColor ~= nil and "foreground" or "secondaryForeground" } }
end

local function percent(ctx: Context, fraction: number?): string
    return fraction and ctx.format.percent(fraction) or "—"
end

local function rounded(bytes: number): number
    if bytes <= 0 then
        return 0
    end
    local scale = 10 ^ (math.floor(math.log10(bytes)) - 2)
    return math.round(bytes / scale) * scale
end

local function fraction(used: number, total: number): number?
    if total <= 0 then
        return nil
    end
    return math.clamp(used / total, 0, 1)
end

local function uptime(seconds: number): string
    local total = math.floor(seconds)
    local days = total // 86400
    local hours = (total % 86400) // 3600
    local minutes = (total % 3600) // 60
    if days > 0 then
        return omniwm.l10n("%lldd %lldh %lldm", days, hours, minutes)
    end
    if hours > 0 then
        return omniwm.l10n("%lldh %lldm", hours, minutes)
    end
    return omniwm.l10n("%lldm", minutes)
end

local function pressureName(pressure: string): string
    if pressure == "normal" then
        return omniwm.l10n("Normal")
    end
    if pressure == "warning" then
        return omniwm.l10n("Warning")
    end
    return omniwm.l10n("Critical")
end

local function arc(value: number): string?
    local center = ring / 2
    local radius = (ring - stroke) / 2
    local top = string.format("M%.2f %.2f", center, center - radius)
    if value >= 0.999 then
        return string.format("%s A%.2f %.2f 0 1 1 %.2f %.2f A%.2f %.2f 0 1 1 %.2f %.2f", top, radius, radius, center,
            center + radius, radius, radius, center, center - radius)
    end
    if value <= 0.005 then
        return nil
    end
    local angle = value * 2 * math.pi
    return string.format("%s A%.2f %.2f 0 %d 1 %.2f %.2f", top, radius, radius, angle > math.pi and 1 or 0,
        center + radius * math.sin(angle), center - radius * math.cos(angle))
end

local function gauge(ctx: Context, title: string, value: number?, hue: string, detail: string, column: number)
    local dial = { w = ring, h = ring, help = detail,
        ui.path{ w = ring, h = ring, viewBox = { 0, 0, ring, ring }, d = arc(1) :: string, border = "foreground/0.08",
            borderWidth = stroke } }
    local sweep = value and arc(value)
    if sweep then
        dial[#dial + 1] = ui.path{ w = ring, h = ring, viewBox = { 0, 0, ring, ring }, d = sweep,
            border = (value or 0) >= 0.9 and "red" or hue, borderWidth = stroke }
    end
    dial[#dial + 1] = ui.text{ text = percent(ctx, value), style = "rounded", size = 14, weight = "bold",
        color = "foreground" }
    return ui.column{ w = column, gap = 6, center = true,
        ui.stack(dial),
        ui.text{ text = title, size = 12, weight = "bold", color = "mutedForeground", maxWidth = column - 4 } }
end

local function header(system: System)
    return ui.stack{ w = width, h = 52,
        ui.box{ w = width, h = 52, radius = 12, fill = "elevatedSurface" },
        ui.box{ align = "bottom", w = width, h = 12, fill = "elevatedSurface" },
        ui.row{ w = content, gap = 10,
            ui.stack{ w = 30, h = 30, radius = 8, fill = "accent",
                ui.symbol{ name = "applelogo", size = 16, weight = "semibold", color = "accentForeground" } },
            ui.column{ gap = 1, center = false,
                ui.text{ text = system.host.name, size = 14, weight = "bold", color = "foreground", maxWidth = 170 },
                ui.text{ text = system.host.chip, size = 12, weight = "medium", color = "mutedForeground",
                    maxWidth = 170 } },
            ui.box{ grow = 1, h = 1 },
            ui.row{ h = 22, radius = 6, fill = "foreground/0.06", gap = 4,
                ui.box{ w = 4, h = 1 },
                ui.symbol{ name = "power", size = 9, weight = "bold", color = "green" },
                ui.text{ text = uptime(system.uptime), style = "mono", size = 12, weight = "semibold",
                    color = "secondaryForeground" },
                ui.box{ w = 5, h = 1 } } } }
end

local function gauges(ctx: Context, system: System)
    local cpu = ctx.data.cpu and ctx.data.cpu / 100
    local gpu = ctx.data.gpu and ctx.data.gpu / 100
    local column = (content - 8) / 4
    return ui.row{ w = content, gap = 0, pad = 4, radius = 9, fill = "elevatedSurface",
        gauge(ctx, omniwm.l10n("CPU"), cpu, "blue",
            cpu and omniwm.l10n("Total processor") or omniwm.l10n("Waiting for delta"), column),
        gauge(ctx, omniwm.l10n("GPU"), gpu, "purple",
            gpu and omniwm.l10n("Device utilization") or omniwm.l10n("Unavailable"), column),
        gauge(ctx, omniwm.l10n("Memory"), fraction(system.memory.used, system.memory.total), "green", "", column),
        gauge(ctx, omniwm.l10n("Disk"), fraction(system.disk.used, system.disk.total), "yellow", "", column) }
end

local function detail(symbol: string, hue: string, title: string?, value: string, lines: number)
    local row = { w = inner, gap = 10,
        ui.box{ w = 1, h = lines > 1 and 46 or 38 },
        ui.stack{ w = 24, h = 24, radius = 6, fill = hue .. "/0.16",
            ui.symbol{ name = symbol, size = 11, weight = "semibold", color = hue } } }
    if title then
        row[#row + 1] = ui.text{ text = title, size = 14, weight = "semibold", color = "foreground" }
        row[#row + 1] = ui.box{ grow = 1, h = 1 }
        row[#row + 1] = ui.text{ text = value, size = 12, weight = "medium", color = "secondaryForeground",
            maxWidth = inner - 130 }
    else
        row[#row + 1] = ui.text{ text = value, size = 12, weight = "medium", color = "secondaryForeground",
            maxWidth = inner - 40, lines = lines }
    end
    return ui.row(row)
end

local function details(ctx: Context, system: System)
    local memory = system.memory
    local memoryDetail = ctx.format.bytes(memory.used) .. " / " .. ctx.format.bytes(memory.total)
    if memory.pressure then
        memoryDetail ..= " · " .. pressureName(memory.pressure)
    end
    local disk = system.disk
    local diskDetail = omniwm.l10n("%@ free", ctx.format.bytes(rounded(math.max(disk.total - disk.used, 0)), "file"))
    local displays = {}
    for _, display in ipairs(system.displays) do
        displays[#displays + 1] = omniwm.l10n("%@ @ %lld Hz", string.format("%d×%d", display.w, display.h), display.hz)
    end
    local screens = #displays > 0 and table.concat(displays, "\n") or omniwm.l10n("Display data unavailable")
    local rows = {
        detail("memorychip", memory.pressure == "critical" and "red" or "green", omniwm.l10n("Memory"), memoryDetail, 1),
        detail("internaldrive", "yellow", omniwm.l10n("Disk"), diskDetail, 1),
        detail("display", "blue", nil, screens, math.max(1, #displays)),
        detail("laptopcomputer", "accent", system.host.model, system.host.os, 1),
    }
    local card = { w = content, gap = 0, pad = 0, radius = 9, fill = "elevatedSurface", center = true }
    for index, row in rows do
        if index > 1 then
            card[#card + 1] = ui.box{ w = inner, h = 1, fill = "foreground/0.07" }
        end
        card[#card + 1] = row
    end
    return ui.column(card)
end

local function frame(children)
    local root = { w = width, gap = 0, material = "clear", radius = 12, fill = "surface", border = "border",
        borderWidth = 1, center = false }
    for _, child in children do
        root[#root + 1] = child
    end
    return ui.column(root)
end

function popout(ctx: Context)
    local system = ctx.data.system
    if not system then
        return frame({ ui.row{ w = width, h = 120, center = true,
            ui.box{ grow = 1, h = 1 },
            ui.text{ text = omniwm.l10n("Loading…"), size = 14, weight = "medium", color = "secondaryForeground" },
            ui.box{ grow = 1, h = 1 } } })
    end
    return frame({ header(system), ui.box{ w = width, h = 1, fill = "border" },
        ui.column{ w = width, pad = padding, gap = 10, center = false, gauges(ctx, system), details(ctx, system) } })
end
