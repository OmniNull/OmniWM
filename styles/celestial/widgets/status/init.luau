-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

require("../lib/audio")
require("../lib/battery")
require("../lib/bluetooth")
require("../lib/input-source")
require("../lib/wifi")
local icons = require("../lib/icons")
local status = require("../lib/status")
local surface = require("../lib/surface")
local tokens = require("../lib/tokens")

local TINT = "secondaryAccent"

local function setting(ctx: Context, key: string, default: boolean): boolean
    local value = (ctx.data.settings or {})[key]
    if value == nil then
        return default
    end
    return value == true
end

local function entry(part: string, child, help: string?)
    return ui.stack{ key = part, popout = true, help = help, radius = tokens.rounding.small, hover = status.hover,
        onClick = function(ctx) ctx.state.part = part end, child }
end

local function glyph(name: string, scale: number, color: string?)
    return surface.icon(name, { size = tokens.icon.medium * scale, color = color or TINT, filled = true, animate = "effects" })
end

function render(ctx: Context)
    local data = ctx.data
    local style = data.bar.style
    local scale = style.height / 60
    local items = {}
    if setting(ctx, "audio", false) and data.volume then
        items[#items + 1] = entry("audio", glyph(icons.volume(data.volume / 100, data.muted), scale), omniwm.l10n("Volume"))
    end
    if setting(ctx, "keyboard", false) and data.inputSource then
        items[#items + 1] = entry("keyboard", ui.text{ text = data.inputSource.short, font = "sans",
            size = tokens.body.medium * scale, weight = "medium",
            color = style.textColor ~= nil and "foreground" or TINT }, data.inputSource.name)
    end
    if setting(ctx, "network", true) then
        items[#items + 1] = entry("network", glyph(status.wifiIcon(data.wifi), scale), omniwm.l10n("Wi-Fi"))
    end
    local bluetooth = data.bluetooth
    if setting(ctx, "bluetooth", true) and bluetooth then
        local group = { gap = tokens.spacing.medium / 2 * scale,
            glyph(status.bluetoothStateIcon(require("../lib/bluetooth").state(ctx)), scale) }
        for _, device in bluetooth.devices do
            if device.connected then
                group[#group + 1] = glyph(icons.bluetooth(device.kind), scale)
            end
        end
        items[#items + 1] = entry("bluetooth", style.vertical and ui.column(group) or ui.row(group),
            omniwm.l10n("Bluetooth"))
    end
    local level = data.battery
    if setting(ctx, "battery", true) and level then
        local low = level <= 20 and not data.charging
        items[#items + 1] = entry("battery", glyph(icons.battery(level / 100, data.charging), scale, low and "error" or nil),
            omniwm.l10n("Battery"))
    end
    if #items == 0 then
        return ui.box{ w = 0, h = 0 }
    end
    return surface.pill(style, items, { onScroll = status.scroll })
end

function popout(ctx: Context)
    local part = ctx.state.part
    if part == "network" then
        return status.network(ctx)
    elseif part == "bluetooth" then
        return status.bluetooth(ctx)
    elseif part == "battery" then
        return status.battery(ctx)
    elseif part == "keyboard" then
        return status.keyboard(ctx)
    end
    return status.audio(ctx)
end
