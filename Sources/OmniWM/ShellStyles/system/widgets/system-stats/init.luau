-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")

spanIslands = true
interval = 1

local INNER = style.width - 24

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
    if not bar.style.statsButton
        or (bar.island ~= "all" and (bar.island == "secondary") ~= secondaryHasContent(bar)) then
        return ui.row{}
    end
    return style.bar(ctx, { onClick = ui.popout, help = omniwm.l10n("Show system stats"),
        ui.symbol{ name = "gauge.with.needle", size = 14 * style.scale(ctx) } })
end

local function rounded(bytes: number): number
    if bytes <= 0 then
        return 0
    end
    local scale = 10 ^ (math.floor(math.log10(bytes)) - 2)
    return math.round(bytes / scale) * scale
end

local function fraction(used: number, total: number): number?
    return if total > 0 then math.clamp(used / total, 0, 1) else nil
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
    return if pressure == "warning" then omniwm.l10n("Warning") else omniwm.l10n("Critical")
end

local function meter(ctx, title: string, symbol: string, value: number?, detail: string)
    return ui.column{ w = INNER, gap = 6, center = false,
        ui.row{ w = INNER, gap = 8,
            ui.symbol{ name = symbol, w = 16, h = 16, color = "secondaryForeground" },
            ui.text{ text = title, size = 13, grow = 1 },
            ui.text{ text = if value then ctx.format.percent(value) else "—", size = 13, weight = "medium" } },
        ui.progress{ value = value or 0, w = INNER, h = 4, radius = 2, fill = "foreground/0.08",
            color = if value and value >= 0.9 then "warning" else "accent" },
        ui.text{ text = detail, size = 11, color = "secondaryForeground", maxWidth = INNER, lines = 2 } }
end

function popout(ctx: Context)
    local system = ctx.data.system
    if not system then
        return style.panel{ w = style.width + 28,
            style.heading(omniwm.l10n("System")),
            ui.text{ text = omniwm.l10n("Loading…"), size = 13, color = "secondaryForeground" } }
    end
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
    local screens = #displays > 0 and table.concat(displays, "  ") or omniwm.l10n("Display data unavailable")
    local cpu = ctx.data.cpu and ctx.data.cpu / 100
    local gpu = ctx.data.gpu and ctx.data.gpu / 100
    return style.panel{ w = style.width + 28,
        ui.row{ w = style.width, gap = 10,
            ui.symbol{ name = "desktopcomputer", w = 24, h = 24 },
            ui.column{ gap = 3, center = false, grow = 1,
                ui.text{ text = system.host.name, size = 14, weight = "semibold", maxWidth = style.width - 110 },
                ui.text{ text = system.host.chip, size = 12, color = "secondaryForeground", maxWidth = style.width - 110 } },
            ui.text{ text = uptime(system.uptime), size = 11, color = "secondaryForeground" } },
        style.group{ w = style.width, gap = 14,
            meter(ctx, omniwm.l10n("CPU"), "cpu", cpu,
                cpu and omniwm.l10n("Total processor") or omniwm.l10n("Waiting for delta")),
            meter(ctx, omniwm.l10n("GPU"), "cube", gpu,
                gpu and omniwm.l10n("Device utilization") or omniwm.l10n("Unavailable")),
            meter(ctx, omniwm.l10n("Memory"), "memorychip", fraction(memory.used, memory.total), memoryDetail),
            meter(ctx, omniwm.l10n("Disk"), "internaldrive", fraction(disk.used, disk.total), diskDetail) },
        style.group{ w = style.width, gap = 4,
            ui.text{ text = system.host.model, size = 13, maxWidth = INNER },
            ui.text{ text = system.host.os, size = 12, color = "secondaryForeground", maxWidth = INNER },
            ui.text{ text = screens, size = 11, color = "secondaryForeground", maxWidth = INNER, lines = 2 } } }
end
