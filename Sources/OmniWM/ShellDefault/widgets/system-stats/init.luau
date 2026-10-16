-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

spanIslands = true
interval = 1

local width = 340
local height = 300
local padding = 16
local content = width - padding * 2
local tileWidth = (content - 10) / 2
local tileInner = tileWidth - 20
local titleWidth = tileInner - 68
local meters = { cyan = 0, purple = 1, green = 2, orange = 3 }

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
    local item = math.max(16, style.height - 4)
    local size = math.max(18, item)
    return ui.stack{ w = size, h = size, radius = 6, hoverMaterial = style.backgrounds and "regular" or nil,
        onClick = ui.popout, help = omniwm.l10n("Show system stats"),
        ui.symbol{ name = "gauge.with.needle", size = math.max(11, (item - 6) * 0.8), color = "foreground" } }
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

local function tile(ctx: Context, title: string, symbol: string, value: number?, detail: string, tint: string)
    return ui.column{ w = tileWidth, h = 76, pad = 10, gap = 7, radius = 8, material = "thin", center = false,
        border = "secondaryForeground/0.16", borderWidth = 0.75,
        ui.row{ w = tileInner,
            ui.column{ center = false,
                ui.box{ h = 5 },
                ui.row{ gap = 6, center = true,
                    ui.stack{ w = 14, h = 12, ui.symbol{ name = symbol, size = 10, weight = "semibold", color = tint } },
                    ui.text{ text = title, size = 10, weight = "medium", color = "secondaryForeground",
                        maxWidth = titleWidth } } },
            ui.box{ grow = 1 },
            ui.text{ text = percent(ctx, value), style = "rounded", size = 15, weight = "semibold" } },
        ui.text{ text = detail, size = 10, weight = "medium", color = "secondaryForeground", maxWidth = tileInner },
        ui.stack{ w = tileInner, h = 6, radius = 3, fill = "foreground/0.1",
            ui.shader{ align = "leading", w = value and math.max(value * tileInner, 4) or 0, h = 6,
                source = "meter.metal", values = { meters[tint] }, fps = 0 } } }
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
    return ui.row{ w = content, gap = 10, center = true,
        ui.stack{ w = 26, h = 26, ui.symbol{ name = "applelogo", size = 22, weight = "semibold" } },
        ui.column{ gap = 2, center = false,
            ui.text{ text = system.host.name, size = 13, weight = "bold", maxWidth = 190 },
            ui.text{ text = system.host.chip, size = 10, color = "secondaryForeground", maxWidth = 190 } },
        ui.box{ grow = 1 },
        ui.text{ text = uptime(system.uptime), style = "mono", size = 10, color = "secondaryForeground" } }
end

local function grid(ctx: Context, system: System)
    local cpu = ctx.data.cpu and ctx.data.cpu / 100
    local gpu = ctx.data.gpu and ctx.data.gpu / 100
    local memory = system.memory
    local used = ctx.format.bytes(memory.used)
    local total = ctx.format.bytes(memory.total)
    local memoryDetail = used .. " / " .. total
    if memory.pressure then
        memoryDetail ..= " · " .. pressureName(memory.pressure)
    end
    local disk = system.disk
    local diskDetail = omniwm.l10n("%@ free", ctx.format.bytes(rounded(math.max(disk.total - disk.used, 0)), "file"))
    return ui.column{ gap = 10,
        ui.row{ gap = 10,
            tile(ctx, omniwm.l10n("CPU"), "cpu", cpu,
                cpu and omniwm.l10n("Total processor") or omniwm.l10n("Waiting for delta"), "cyan"),
            tile(ctx, omniwm.l10n("GPU"), "cube", gpu,
                gpu and omniwm.l10n("Device utilization") or omniwm.l10n("Unavailable"), "purple") },
        ui.row{ gap = 10,
            tile(ctx, omniwm.l10n("Memory"), "memorychip", fraction(memory.used, memory.total), memoryDetail, "green"),
            tile(ctx, omniwm.l10n("Disk"), "internaldrive", fraction(disk.used, disk.total), diskDetail, "orange") } }
end

local function footer(system: System)
    local displays = {}
    for _, display in ipairs(system.displays) do
        displays[#displays + 1] = omniwm.l10n("%@ @ %lld Hz", string.format("%d×%d", display.w, display.h), display.hz)
    end
    local screens = #displays > 0 and table.concat(displays, "  ") or omniwm.l10n("Display data unavailable")
    return ui.column{ gap = 2, center = false,
        ui.text{ text = system.host.model, size = 10, weight = "medium", maxWidth = content },
        ui.text{ text = system.host.os .. "  " .. screens, size = 10, weight = "medium",
            color = "secondaryForeground", maxWidth = content, lines = 2 } }
end

function popout(ctx: Context)
    local system = ctx.data.system
    if not system then
        return ui.column{ w = width, h = height, material = "glass", radius = 14,
            ui.box{ grow = 1 },
            ui.text{ text = omniwm.l10n("Loading…"), color = "secondaryForeground" },
            ui.box{ grow = 1 } }
    end
    return ui.column{ w = width, h = height, pad = padding, gap = 12, material = "glass", radius = 14, scroll = true,
        center = false,
        header(system),
        grid(ctx, system),
        footer(system) }
end
