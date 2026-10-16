-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

spanIslands = true
interval = 1

local performance = require("../lib/performance")
local status = require("../lib/status")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

local function secondaryHasContent(bar: Bar): boolean
    if #bar.scratchpads > 0 then
        return true
    end
    for _, workspace in bar.workspaces do
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
    return surface.pill(style, { surface.icon("monitoring", { size = 24 * style.height / 60,
        color = style.textColor ~= nil and "foreground" or "secondaryAccent" }) },
        { hover = status.hover, onClick = ui.popout, help = omniwm.l10n("Show system stats") })
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

local function details(ctx: Context, width: number)
    local system = ctx.data.system
    if not system then
        return ui.text{ text = omniwm.l10n("Loading…"), font = "sans", size = tokens.body.small }
    end
    local memory = system.memory
    local pressure = if memory.pressure == "normal" then omniwm.l10n("Normal")
        elseif memory.pressure == "warning" then omniwm.l10n("Warning")
        elseif memory.pressure == "critical" then omniwm.l10n("Critical") else nil
    local memoryDetail = ctx.format.bytes(memory.used) .. " / " .. ctx.format.bytes(memory.total)
    if pressure then
        memoryDetail ..= " · " .. pressure
    end
    local displays = {}
    for _, display in system.displays do
        displays[#displays + 1] = omniwm.l10n("%@ @ %lld Hz", string.format("%d×%d", display.w, display.h), display.hz)
    end
    local inner = width - tokens.padding.medium * 2
    return ui.column{ w = width, pad = tokens.padding.medium, gap = tokens.spacing.small,
        radius = tokens.rounding.large, fill = "surface", center = false,
        ui.row{ w = inner, gap = tokens.spacing.large,
            ui.text{ text = system.host.name, font = "sans", size = tokens.title.medium, weight = "medium", maxWidth = inner / 2 },
            ui.box{ grow = 1, h = 1 },
            ui.text{ text = uptime(system.uptime), font = "sans", size = tokens.body.small, color = "secondaryForeground" } },
        ui.text{ text = omniwm.l10n("Memory") .. " · " .. memoryDetail, font = "sans", size = tokens.body.small,
            maxWidth = inner, lines = 2 },
        ui.text{ text = omniwm.l10n("Disk") .. " · "
            .. omniwm.l10n("%@ free", ctx.format.bytes(math.max(system.disk.total - system.disk.used, 0), "file")),
            font = "sans", size = tokens.body.small, maxWidth = inner },
        ui.text{ text = system.host.model .. " · " .. system.host.os, font = "sans", size = tokens.label.medium,
            color = "secondaryForeground", maxWidth = inner },
        ui.text{ text = #displays > 0 and table.concat(displays, "  ·  ") or omniwm.l10n("Display data unavailable"),
            font = "sans", size = tokens.label.medium, color = "secondaryForeground", maxWidth = inner, lines = 2 } }
end

function popout(ctx: Context)
    local width = performance.size(ctx).w
    return status.panel(width + 2 * tokens.padding.large, { performance.tab(ctx), details(ctx, width) })
end
