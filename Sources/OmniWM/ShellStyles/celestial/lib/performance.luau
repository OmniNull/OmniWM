-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local geometry = require("./geometry")
local motion = require("./motion")
local shapes = require("./shapes")
local surface = require("./surface")
local tokens = require("./tokens")

local GAP = tokens.spacing.medium
local sizes = tokens.dashboard.performance
local HERO = sizes.hero
local HERO_HEIGHT = 148
local NETWORK = sizes.network
local TANK = sizes.battery.w
local MAIN = 2 * HERO + GAP
local SIDE = (MAIN - NETWORK.w - 2 * GAP) / 2
local HEIGHT = HERO_HEIGHT + GAP + NETWORK.h

local function card(w: number, h: number, radius: number, props)
    props.w = w
    props.h = h
    props.radius = radius
    props.fill = props.fill or "surface"
    return ui.stack(props)
end

local function percent(ctx: Context, value: number?): string
    return value and ctx.format.percent(value / 100) or "…"
end

local function gauge(size: number, width: number, fraction: number, tint: string, start: number?, sweep: number?)
    local parts = geometry.gauge(size, width, fraction, start, sweep, tokens.spacing.extraSmall)
    local layers = { w = size, h = size }
    if parts.track then
        layers[#layers + 1] = ui.path{ d = parts.track, w = size, h = size, fill = "secondaryContainer" }
    end
    if parts.value then
        layers[#layers + 1] = ui.path{ d = parts.value, w = size, h = size, fill = tint, animate = motion.normal }
    end
    return layers
end

local function hero(ctx: Context, icon: string, label: string, detail: string, usage: number?, temperature: number?,
    tint: string)
    local ring = math.max(tokens.icon.medium, 24) + 2 * tokens.padding.medium
    local fraction = (usage or 0) / 100
    local hot = (temperature or 0) > 90
    local shape = fraction >= 0.8 and "SoftBurst" or fraction >= 0.4 and "Sunny" or "Cookie4Sided"
    local shapeSize = sizes.shape
    local barWidth = HERO - shapeSize - 3 * tokens.padding.large
    local ringLayers = gauge(ring, tokens.padding.extraSmall, fraction, tint)
    ringLayers[#ringLayers + 1] = surface.icon(icon, { size = tokens.icon.medium, color = tint })
    local temperatureText = temperature and string.format("%s°C", ctx.format.number(temperature, 0)) or "…"
    return card(HERO, HERO_HEIGHT, tokens.rounding.extraLarge, {
        ui.row{ align = "topLeading", dx = tokens.padding.large, dy = tokens.padding.large, gap = tokens.spacing.large,
            ui.stack(ringLayers),
            ui.column{ gap = tokens.spacing.extraSmall, center = false,
                ui.text{ text = label, font = "sans", size = tokens.title.medium, color = tint },
                ui.text{ text = detail, font = "sans", size = tokens.body.small, color = "secondaryForeground",
                    maxWidth = barWidth - ring - tokens.spacing.large } } },
        ui.column{ align = "bottomLeading", dx = tokens.padding.largeIncreased, dy = -tokens.padding.largeIncreased,
            gap = tokens.spacing.extraSmall, center = false,
            ui.row{ gap = tokens.spacing.extraSmall,
                surface.icon(hot and "thermometer_alert" or "thermometer", { size = tokens.icon.medium,
                    color = hot and "error" or tint, filled = true }),
                ui.text{ text = temperatureText, font = "sans", size = tokens.body.medium } },
            ui.stack{ w = barWidth, h = tokens.padding.small, radius = tokens.padding.small / 2, fill = "secondaryContainer",
                ui.box{ align = "leading", w = math.max(barWidth * math.clamp((temperature or 0) / 100, 0, 1), 1),
                    h = tokens.padding.small, radius = tokens.padding.small / 2, fill = tint, animate = motion.normal } } },
        ui.column{ align = "bottomTrailing", dx = -tokens.padding.medium, dy = -tokens.padding.medium, gap = 0,
            ui.text{ text = omniwm.l10n("Usage"), font = "sans", size = tokens.body.small, color = "secondaryForeground" },
            ui.stack{ w = shapeSize, h = shapeSize,
                ui.path{ d = shapes.path(shape), viewBox = shapes.viewBox, w = shapeSize, h = shapeSize,
                    fill = "secondaryContainer", animate = "spatial" },
                ui.text{ text = percent(ctx, usage), font = "sans", size = tokens.headline.small, color = tint } } } })
end

local function usageGauge(ctx: Context, fraction: number, tint: string, icon: string?)
    local size = 120
    local layers = gauge(size, tokens.padding.small, fraction, tint, -225, 270)
    local inside = { gap = 0 }
    if icon then
        inside[#inside + 1] = surface.icon(icon, { size = tokens.icon.medium, color = tint })
    end
    inside[#inside + 1] = ui.text{ text = ctx.format.percent(fraction), font = "sans", size = tokens.title.large,
        color = tint }
    inside[#inside + 1] = ui.text{ text = omniwm.l10n("Used"), font = "sans", size = tokens.body.small,
        color = "secondaryForeground" }
    layers[#layers + 1] = ui.column(inside)
    return ui.stack(layers)
end

local function storage(ctx: Context)
    local system = ctx.data.system
    local fraction = system and system.disk.total > 0 and system.disk.used / system.disk.total or (ctx.data.disk or 0) / 100
    local usage = system and string.format("%s / %s", ctx.format.bytes(system.disk.used, "file"),
        ctx.format.bytes(system.disk.total, "file")) or ""
    return card(SIDE, NETWORK.h, tokens.rounding.extraExtraLarge, { ui.column{ gap = tokens.spacing.small,
        usageGauge(ctx, fraction, "secondaryAccent", "hard_drive"),
        ui.text{ text = omniwm.l10n("Storage"), font = "sans", size = tokens.title.medium },
        ui.text{ text = usage, font = "sans", size = tokens.body.small, color = "secondaryAccent",
            maxWidth = SIDE - 24 } } })
end

local function memory(ctx: Context)
    local system = ctx.data.system
    local fraction = system and system.memory.total > 0 and system.memory.used / system.memory.total
        or (ctx.data.memory or 0) / 100
    local usage = system and string.format("%s / %s", ctx.format.bytes(system.memory.used, "memory"),
        ctx.format.bytes(system.memory.total, "memory")) or ""
    return card(SIDE, NETWORK.h, tokens.rounding.medium, { ui.column{ gap = tokens.spacing.small,
        ui.row{ gap = tokens.spacing.small,
            surface.icon("memory_alt", { size = tokens.icon.medium, color = "tertiaryAccent", filled = true }),
            ui.text{ text = omniwm.l10n("Memory"), font = "sans", size = tokens.title.medium } },
        usageGauge(ctx, fraction, "tertiaryAccent"),
        ui.text{ text = usage, font = "sans", size = tokens.body.small, maxWidth = SIDE - 24 } } })
end

local function network(ctx: Context)
    local history = ctx.data.networkHistory
    local rate = ctx.data.network
    local inner = NETWORK.w - 2 * tokens.padding.large
    local graph = 64
    local layers = { w = inner, h = graph }
    if history and #history.down >= 2 then
        local top = 1024
        for _, value in history.down do
            top = math.max(top, value)
        end
        for _, value in history.up do
            top = math.max(top, value)
        end
        local up = geometry.sparkline(history.up, inner, graph, top)
        local down = geometry.sparkline(history.down, inner, graph, top)
        layers[#layers + 1] = ui.path{ d = geometry.sparkline(history.up, inner, graph, top, true), w = inner, h = graph,
            fill = "secondaryAccent/0.15" }
        layers[#layers + 1] = ui.path{ d = up, w = inner, h = graph, border = "secondaryAccent", borderWidth = 2 }
        layers[#layers + 1] = ui.path{ d = geometry.sparkline(history.down, inner, graph, top, true), w = inner,
            h = graph, fill = "tertiaryAccent/0.2" }
        layers[#layers + 1] = ui.path{ d = down, w = inner, h = graph, border = "tertiaryAccent", borderWidth = 2 }
    else
        layers[#layers + 1] = ui.text{ text = omniwm.l10n("Collecting data…"), font = "sans", size = tokens.body.small,
            color = "mutedForeground" }
    end
    local function line(icon: string, label: string, value: string, tint: string)
        return ui.row{ w = inner, gap = tokens.spacing.small,
            surface.icon(icon, { size = tokens.icon.medium, color = tint }),
            ui.text{ text = label, font = "sans", size = tokens.body.small, color = "secondaryForeground" },
            ui.box{ grow = 1, h = 1 },
            ui.text{ text = value, font = "sans", size = tokens.body.medium, weight = "medium", color = tint } }
    end
    local function speed(bytes: number?): string
        return ctx.format.bytes(bytes or 0, "file") .. "/s"
    end
    local total = history and string.format("↓%s ↑%s", ctx.format.bytes(history.received, "file"),
        ctx.format.bytes(history.sent, "file")) or "…"
    return card(NETWORK.w, NETWORK.h, tokens.rounding.extraLarge, { ui.column{ w = inner, gap = 0, center = false,
        ui.row{ gap = tokens.spacing.small,
            surface.icon("swap_vert", { size = tokens.icon.medium, color = "accent" }),
            ui.text{ text = omniwm.l10n("Network"), font = "sans", size = tokens.title.medium } },
        ui.box{ w = 1, h = tokens.spacing.medium },
        ui.stack(layers),
        ui.box{ w = 1, h = tokens.spacing.small },
        line("download", omniwm.l10n("Download"), speed(rate and rate.down), "tertiaryAccent"),
        line("upload", omniwm.l10n("Upload"), speed(rate and rate.up), "secondaryAccent"),
        line("history", omniwm.l10n("Total"), total, "secondaryForeground") } })
end

local function tankContents(ctx: Context, accent: string, text: string, detail: string)
    local level = ctx.data.battery or 0
    local power = ctx.data.power
    local status = (power and power.charged) and omniwm.l10n("Fully charged")
        or ctx.data.charging and omniwm.l10n("Charging")
        or (power and power.remaining) and (power.remaining >= 60
            and omniwm.l10n("%lldh %lldm", power.remaining // 60, power.remaining % 60)
            or omniwm.l10n("%lldm", power.remaining))
        or "…"
    local inner = TANK - 2 * tokens.padding.medium
    return ui.column{ w = inner, h = HEIGHT - 2 * tokens.padding.medium, gap = 0, center = false,
        surface.icon("battery_full", { size = tokens.icon.large, color = accent }),
        ui.text{ text = omniwm.l10n("Battery"), font = "sans", size = tokens.body.medium, color = text },
        ui.box{ grow = 1, w = 1 },
        ui.text{ align = "trailing", text = status, font = "sans", size = tokens.body.small, color = detail },
        ui.row{ w = inner, gap = tokens.spacing.extraSmall,
            ui.box{ grow = 1, h = 1 },
            surface.icon("bolt", { size = tokens.icon.large, color = accent, filled = true,
                opacity = ctx.data.charging and 1 or 0, scale = ctx.data.charging and 1 or 0, animate = "fastSpatial" }),
            ui.text{ text = ctx.format.percent(level / 100), font = "sans", size = tokens.headline.medium,
                color = accent } } }
end

local function tank(ctx: Context)
    local level = math.clamp((ctx.data.battery or 0) / 100, 0, 1)
    local filled = HEIGHT * level
    return card(TANK, HEIGHT, tokens.rounding.large, { fill = "secondaryContainer", pad = 0,
        ui.stack{ w = TANK, h = HEIGHT, pad = tokens.padding.medium,
            tankContents(ctx, "accent", "foreground", "secondaryForeground") },
        ui.stack{ w = TANK, h = HEIGHT,
            ui.path{ d = string.format("M 0 %.2f H %d V %d A %d %d 0 0 1 %d %d H %d A %d %d 0 0 1 0 %d Z",
                    HEIGHT - filled, TANK, HEIGHT - tokens.rounding.large, tokens.rounding.large, tokens.rounding.large,
                    TANK - tokens.rounding.large, HEIGHT, tokens.rounding.large, tokens.rounding.large,
                    tokens.rounding.large, HEIGHT - tokens.rounding.large),
                w = TANK, h = HEIGHT, mask = true, animate = motion.normal },
            ui.box{ w = TANK, h = HEIGHT, fill = "secondaryAccent" },
            ui.stack{ w = TANK, h = HEIGHT, pad = tokens.padding.medium,
                tankContents(ctx, "accentContainer", "background", "secondaryContainer") } } })
end

local function width(ctx: Context): number
    return ctx.data.battery and MAIN + GAP + TANK or MAIN
end

local function tab(ctx: Context)
    local data = ctx.data
    local system = data.system
    local thermal = data.thermal
    local row = { gap = GAP, center = false,
        ui.column{ gap = GAP, center = false,
            ui.row{ gap = GAP,
                hero(ctx, "memory", omniwm.l10n("CPU"), system and system.host.chip or "", data.cpu,
                    thermal and thermal.cpu, "accent"),
                hero(ctx, "desktop_windows", omniwm.l10n("GPU"), thermal and thermal.gpuName or "", data.gpu,
                    thermal and thermal.gpu, "secondaryAccent") },
            ui.row{ gap = GAP, storage(ctx), network(ctx), memory(ctx) } } }
    if data.battery then
        row[#row + 1] = tank(ctx)
    end
    return ui.row(row)
end

return table.freeze({
    size = function(ctx: Context)
        return { w = width(ctx), h = HEIGHT }
    end,
    tab = tab,
})
