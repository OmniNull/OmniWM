-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local panel = require("../lib/panel")

spanIslands = true
interval = 1

local WIDTH = 380
local INNER = WIDTH - 2 - 24
local HALF = (INNER - 10) / 2
local RING = 64

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
    local fill = style.backgrounds and "surface" or nil
    local edge = style.backgrounds and "border/0.6" or nil
    return ui.stack{ w = size, h = size, radius = size / 2 - 1, fill = fill, border = edge, borderWidth = 1,
        hover = "focus/0.14", onClick = ui.popout, help = omniwm.l10n("Show system stats"),
        ui.symbol{ name = "gauge.with.needle", size = math.max(11, size * 0.5), weight = "semibold",
            color = "foreground" } }
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

local function circle(size: number, stroke: number): string
    local c = size / 2
    local r = c - stroke / 2
    return string.format("M%g %g A%g %g 0 1 1 %g %g A%g %g 0 1 1 %g %g", c, c - r, r, r, c, c + r, r, r, c, c - r)
end

local function arc(size: number, stroke: number, value: number): string?
    if value <= 0.001 then
        return nil
    end
    if value >= 0.999 then
        return circle(size, stroke)
    end
    local c = size / 2
    local r = c - stroke / 2
    local angle = (value * 2 - 0.5) * math.pi
    return string.format("M%g %g A%g %g 0 %d 1 %.2f %.2f", c, c - r, r, r, value > 0.5 and 1 or 0,
        c + r * math.cos(angle), c + r * math.sin(angle))
end

local function card(props)
    props.radius = 14
    props.fill = "surface"
    props.border = "border"
    props.borderWidth = 1
    return props
end

local function gauge(ctx: Context, title: string, symbol: string, value: number?, detail: string, tint: string)
    local stroke = 6
    local d = value and arc(RING, stroke, value) or nil
    return ui.column(card{ w = HALF, pad = 12, gap = 8,
        ui.stack{ w = RING, h = RING,
            ui.path{ w = RING, h = RING, d = circle(RING, stroke), border = tint .. "/0.16", borderWidth = stroke },
            ui.text{ text = percent(ctx, value), size = 14, weight = "bold" },
            if d then ui.path{ w = RING, h = RING, d = d, border = tint, borderWidth = stroke } else nil },
        ui.column{ gap = 1,
            ui.row{ gap = 5,
                ui.symbol{ name = symbol, size = 10, weight = "semibold", color = tint },
                ui.text{ text = title, size = 14, weight = "bold" } },
            ui.text{ text = detail, size = 12, color = "secondaryForeground", maxWidth = HALF - 24 } } })
end

local function bar(ctx: Context, title: string, symbol: string, value: number?, detail: string, tint: string)
    local width = INNER - 20
    return ui.column{ gap = 5, center = false,
        ui.row{ w = width, gap = 8,
            ui.stack{ w = 24, h = 24, radius = 12, fill = tint .. "/0.18",
                ui.symbol{ name = symbol, size = 11, weight = "semibold", color = tint } },
            ui.column{ gap = 1, center = false,
                ui.text{ text = title, size = 14, weight = "bold" },
                ui.text{ text = detail, size = 12, color = "secondaryForeground", maxWidth = width - 90 } },
            ui.box{ grow = 1, h = 1 },
            ui.text{ text = percent(ctx, value), size = 14, weight = "bold" } },
        ui.progress{ value = value or 0, w = width, h = 6, radius = 3, fill = tint .. "/0.16",
            color = (value or 0) >= 0.9 and "warning" or tint, animate = "ease" } }
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

local function header(system: System)
    return ui.row{ w = INNER, gap = 10,
        ui.stack{ w = 34, h = 34, radius = 17, fill = "accent",
            ui.symbol{ name = "applelogo", size = 16, weight = "semibold", color = "accentForeground" } },
        ui.column{ gap = 1, center = false,
            ui.text{ text = system.host.name, size = 14, weight = "bold", maxWidth = 170 },
            ui.text{ text = system.host.chip, size = 12, color = "secondaryForeground", maxWidth = 170 } },
        ui.box{ grow = 1, h = 1 },
        ui.row{ h = 22, gap = 4, radius = 11, fill = "blue/0.2",
            ui.box{ w = 4, h = 1 },
            ui.symbol{ name = "clock.arrow.circlepath", size = 10, weight = "semibold", color = "blue" },
            ui.text{ text = uptime(system.uptime), style = "mono", size = 12, weight = "semibold", color = "blue" },
            ui.box{ w = 5, h = 1 } } }
end

local function footer(system: System)
    local displays = {}
    for _, display in ipairs(system.displays) do
        displays[#displays + 1] = omniwm.l10n("%@ @ %lld Hz", string.format("%d×%d", display.w, display.h), display.hz)
    end
    local rows = { gap = 6, center = false,
        ui.row{ gap = 8,
            ui.symbol{ name = "laptopcomputer", w = 16, h = 14, size = 12, color = "secondaryForeground" },
            ui.text{ text = system.host.model .. " · " .. system.host.os, size = 12, weight = "medium",
                maxWidth = INNER - 44 } } }
    rows[#rows + 1] = ui.row{ gap = 8,
        ui.symbol{ name = "display.2", w = 16, h = 14, size = 12, color = "secondaryForeground" },
        ui.text{ text = #displays > 0 and table.concat(displays, "  ·  ") or omniwm.l10n("Display data unavailable"),
            size = 12, color = "secondaryForeground", maxWidth = INNER - 44, lines = 2 } }
    return ui.column(card{ w = INNER, pad = 10, center = false, ui.column(rows) })
end

function popout(ctx: Context)
    local system = ctx.data.system
    local style = ctx.data.bar.style
    if not system then
        return panel(style, WIDTH, ui.column{ w = WIDTH - 2, h = 160,
            ui.text{ text = omniwm.l10n("Loading…"), color = "secondaryForeground" } })
    end
    local cpu = ctx.data.cpu and ctx.data.cpu / 100
    local gpu = ctx.data.gpu and ctx.data.gpu / 100
    local memory = system.memory
    local memoryDetail = ctx.format.bytes(memory.used) .. " / " .. ctx.format.bytes(memory.total)
    if memory.pressure then
        memoryDetail ..= " · " .. pressureName(memory.pressure)
    end
    local disk = system.disk
    local diskDetail = omniwm.l10n("%@ free", ctx.format.bytes(rounded(math.max(disk.total - disk.used, 0)), "file"))
    return panel(style, WIDTH, ui.column{ w = WIDTH - 2, pad = 12, gap = 10, center = false,
        header(system),
        ui.row{ gap = 10,
            gauge(ctx, omniwm.l10n("CPU"), "cpu", cpu,
                cpu and omniwm.l10n("Total processor") or omniwm.l10n("Waiting for delta"), "cyan"),
            gauge(ctx, omniwm.l10n("GPU"), "cube", gpu,
                gpu and omniwm.l10n("Device utilization") or omniwm.l10n("Unavailable"), "purple") },
        ui.column(card{ w = INNER, pad = 10, gap = 12, center = false,
            bar(ctx, omniwm.l10n("Memory"), "memorychip", fraction(memory.used, memory.total), memoryDetail, "green"),
            bar(ctx, omniwm.l10n("Disk"), "internaldrive", fraction(disk.used, disk.total), diskDetail, "orange") }),
        footer(system) })
end
