-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local icons = require("./icons")
local surface = require("./surface")
local tokens = require("./tokens")

local HOVER = "foreground/0.08"

local function scroll(ctx: Context, event)
    require("./audio").scroll(ctx, event, 5)
end

local function wifiIcon(wifi: WiFi?): string
    if not wifi or not wifi.power or not wifi.connected then
        return "wifi_off"
    end
    return icons.wifi(wifi.rssi)
end

local function bluetoothStateIcon(m)
    return not m.power and "bluetooth_disabled" or m.connected > 0 and "bluetooth_connected" or "bluetooth"
end

local function heading(icon: string, title: string, detail: string?, width: number)
    return ui.row{ w = width, gap = tokens.spacing.medium,
        ui.stack{ w = 40, h = 40, radius = 20, fill = "secondaryContainer",
            surface.icon(icon, { size = tokens.icon.small, color = "secondaryContainerForeground", filled = true }) },
        ui.column{ gap = 2, center = false, grow = 1,
            ui.text{ text = title, font = "sans", size = tokens.title.small, weight = "medium", maxWidth = width - 60 },
            detail and ui.text{ text = detail, font = "sans", size = tokens.body.small, color = "secondaryForeground",
                maxWidth = width - 60 } or nil } }
end

local function line(label: string, value: string, width: number, wrap: boolean?)
    local gap = wrap and tokens.spacing.small or nil
    local maximum = wrap and (width - gap) / 2 or nil
    local row = { w = width, gap = gap,
        ui.text{ text = label, font = "sans", size = tokens.body.small, color = "secondaryForeground",
            grow = wrap and 1 or nil, maxWidth = maximum, lines = wrap and 2 or nil } }
    if not wrap then
        row[#row + 1] = ui.box{ grow = 1, h = 1 }
    end
    row[#row + 1] = ui.text{ text = value, font = "sans", size = tokens.body.small, weight = "medium",
        maxWidth = maximum or width * 0.6, lines = wrap and 2 or nil }
    return ui.row(row)
end

local function action(text: string, command: string, width: number, multiline: boolean?)
    return ui.row{ w = width, h = not multiline and 40 or nil, pad = multiline and 12 or nil,
        radius = 20, fill = "secondaryContainer",
        hover = "secondaryContainerForeground/0.08", onClick = command,
        not multiline and ui.box{ grow = 1, h = 1 } or nil,
        ui.text{ text = text, font = "sans", size = tokens.label.large, weight = "medium",
            color = "secondaryContainerForeground", maxWidth = multiline and width - 32 or nil,
            grow = multiline and 1 or nil, lines = multiline and 3 or nil },
        not multiline and ui.box{ grow = 1, h = 1 } or nil }
end

local function panel(width: number, rows)
    rows.w = width
    rows.pad = tokens.padding.large
    rows.gap = tokens.spacing.medium
    rows.radius = tokens.rounding.extraLarge
    rows.fill = "background"
    rows.shadow = "shadow/0.35"
    rows.shadowRadius = 10
    rows.center = false
    return ui.column{ material = "clear", pad = tokens.padding.small, ui.column(rows) }
end

local function networkPanel(ctx: Context, m)
    local wifi = require("./wifi")
    m = m or wifi.model(ctx)
    local width = tokens.bar.popout.network
    local inner = width - 2 * tokens.padding.large
    local rows = { heading(wifiIcon(m), omniwm.l10n("Wi-Fi"),
        m and m.connectionStatus or omniwm.l10n("Unavailable"), inner) }
    if m then
        if m.power and m.connected then
            rows[#rows + 1] = ui.text{ text = m.name, font = "sans", size = tokens.title.medium, weight = "medium",
                maxWidth = inner }
        end
        for _, detail in m.details do
            rows[#rows + 1] = line(detail.label, detail.value, inner)
        end
    end
    local network = ctx.data.network
    if network then
        rows[#rows + 1] = line(omniwm.l10n("Download"), ctx.format.bytes(network.down, "file") .. "/s", inner)
        rows[#rows + 1] = line(omniwm.l10n("Upload"), ctx.format.bytes(network.up, "file") .. "/s", inner)
    end
    if m then
        for _, entry in m.actions do
            rows[#rows + 1] = action(entry.text, entry.command, inner, entry.prompt)
        end
    else
        rows[#rows + 1] = action(omniwm.l10n("Wi-Fi Settings…"), wifi.settings, inner)
    end
    return panel(width, rows)
end

local function bluetoothPanel(ctx: Context, m)
    m = m or require("./bluetooth").model(ctx)
    local width = tokens.bar.popout.network
    local inner = width - 2 * tokens.padding.large
    if not m then
        return panel(width, { heading("bluetooth_disabled", omniwm.l10n("Bluetooth"), omniwm.l10n("Unavailable"), inner) })
    end
    local rows = { heading(bluetoothStateIcon(m), omniwm.l10n("Bluetooth"), m.granted and m.help or nil, inner) }
    for _, device in m.devices do
        rows[#rows + 1] = ui.row{ key = device.id, w = inner, gap = tokens.spacing.medium, pad = tokens.padding.small,
            radius = tokens.rounding.large, fill = device.connected and "secondaryContainer" or nil,
            surface.icon(icons.bluetooth(device.kind), { size = tokens.icon.small,
                color = device.connected and "secondaryContainerForeground" or "secondaryForeground", filled = true }),
            ui.column{ gap = 2, center = false, grow = 1,
                ui.text{ text = device.name, font = "sans", size = tokens.body.small, maxWidth = inner - 110,
                    color = device.connected and "secondaryContainerForeground" or "foreground" },
                ui.text{ text = device.status, font = "sans", size = tokens.label.small, color = "secondaryForeground",
                    maxWidth = inner - 110 } },
            device.batteryText and ui.text{ text = device.batteryText, font = "sans", size = tokens.body.small,
                color = device.lowBattery and "error" or "secondaryForeground" } or nil }
    end
    for _, entry in m.actions do
        rows[#rows + 1] = action(entry.text, entry.command, inner, entry.prompt)
    end
    return panel(width, rows)
end

local function batteryPanel(ctx: Context, m)
    m = m or require("./battery").model(ctx)
    local width = tokens.bar.popout.battery
    local inner = width - 2 * tokens.padding.large
    if not m then
        return panel(width, {
            heading("battery_unknown", omniwm.l10n("Battery"), omniwm.l10n("Unavailable"), inner),
        })
    end
    local rows = {
        ui.row{ w = inner, gap = tokens.spacing.medium,
            surface.icon(icons.battery(m.level / 100, m.charging), { size = tokens.icon.large,
                color = m.low and "error" or "accent", filled = true }),
            ui.column{ center = false, gap = 2,
                ui.text{ text = m.percent, font = "sans", size = tokens.headline.small, weight = "medium" },
                ui.text{ text = m.status, font = "sans", size = tokens.body.small, color = "secondaryForeground" } } },
    }
    for _, detail in m.details do
        rows[#rows + 1] = line(detail.label, detail.value, inner, true)
    end
    rows[#rows + 1] = action(omniwm.l10n("Battery Settings…"), m.settings, inner)
    return panel(width, rows)
end

local function audioPanel(ctx: Context, m)
    m = m or require("./audio").model(ctx)
    local width = tokens.bar.popout.audio
    local inner = width - 2 * tokens.padding.large
    local rows = {}
    rows[#rows + 1] = heading(icons.volume(m.level or 0, m.muted), omniwm.l10n("Volume"),
        m.percent or omniwm.l10n("Unavailable"), inner)
    if m.volume then
        rows[#rows + 1] = ui.row{ w = inner, gap = tokens.spacing.small,
            surface.button(m.muted and "no_sound" or "volume_up", "tonal", { onClick = m.mute, glyph = tokens.icon.small }),
            ui.slider{ value = m.level, grow = 1, h = 16, color = m.muted and "mutedForeground" or "accent",
                onChange = m.set } }
    end
    for _, device in m.outputs do
        rows[#rows + 1] = ui.row{ key = device.select, w = inner, gap = tokens.spacing.medium, pad = tokens.padding.small,
            radius = tokens.rounding.large, fill = device.default and "secondaryContainer" or nil, hover = HOVER,
            onClick = device.select,
            surface.icon(device.transport == "bluetooth" and "headphones" or "speaker", { size = tokens.icon.small,
                color = device.default and "secondaryContainerForeground" or "secondaryForeground", filled = true }),
            ui.text{ text = device.name, font = "sans", size = tokens.body.small, maxWidth = inner - 60,
                color = device.default and "secondaryContainerForeground" or "foreground" } }
    end
    if m.permission then
        rows[#rows + 1] = action(omniwm.l10n("Allow System Audio Recording to set app volumes"), m.permission,
            inner, true)
    end
    for _, app in m.apps do
        rows[#rows + 1] = ui.row{ key = app.id, w = inner, gap = tokens.spacing.small, help = app.name,
            ui.icon{ app = app.id, w = 20, h = 20, opacity = app.playing and 1 or 0.55 },
            ui.slider{ value = app.level, grow = 1, h = 14, color = app.muted and "mutedForeground" or "accent",
                onChange = app.set },
            surface.button(app.muted and "no_sound" or "volume_up", "tonal", { onClick = app.mute,
                glyph = tokens.icon.small }) }
    end
    return panel(width, rows)
end

local function keyboardPanel(ctx: Context, m)
    local inputSource = require("./input-source")
    m = m or inputSource.model(ctx)
    local width = tokens.bar.popout.keyboard
    local inner = width - 2 * tokens.padding.large
    local rows = { heading("keyboard", omniwm.l10n("Input Sources"), m and m.name or omniwm.l10n("Unavailable"), inner) }
    for _, entry in m and m.sources or {} do
        rows[#rows + 1] = ui.row{ key = entry.id, w = inner, gap = tokens.spacing.medium, pad = tokens.padding.small,
            radius = tokens.rounding.large, fill = entry.selected and "secondaryContainer" or nil, hover = HOVER,
            onClick = entry.command,
            ui.text{ text = entry.short, font = "sans", size = tokens.label.medium, weight = "medium",
                color = entry.selected and "secondaryContainerForeground" or "accent" },
            ui.text{ text = entry.name, font = "sans", size = tokens.body.small, maxWidth = inner - 70,
                color = entry.selected and "secondaryContainerForeground" or "foreground" } }
    end
    rows[#rows + 1] = action(omniwm.l10n("Keyboard Settings…"), inputSource.settings, inner)
    return panel(width, rows)
end

local function pane(module, ctx: Context)
    local size = module.size
    if type(size) == "function" then
        size = size(ctx)
    end
    return panel(size.w + 2 * tokens.padding.large, { module.tab(ctx) })
end

return table.freeze({
    hover = HOVER,
    scroll = scroll,
    wifiIcon = wifiIcon,
    bluetoothStateIcon = bluetoothStateIcon,
    panel = panel,
    pane = pane,
    network = networkPanel,
    bluetooth = bluetoothPanel,
    battery = batteryPanel,
    audio = audioPanel,
    keyboard = keyboardPanel,
})
