-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local icons = require("./icons")
local surface = require("./surface")
local tokens = require("./tokens")

local PRECISE_POINTS_PER_STEP = 12
local HOVER = "foreground/0.08"

local function scroll(ctx: Context, event)
    local delta = if event.precise then event.dy / PRECISE_POINTS_PER_STEP else event.dy
    local total = ctx.state.scroll or 0
    if total * delta < 0 then
        total = 0
    end
    total += delta
    local steps = if total >= 0 then math.floor(total) else math.ceil(total)
    ctx.state.scroll = total - steps
    if steps ~= 0 then
        omniwm.run(string.format("volume %s %g", if steps > 0 then "up" else "down", math.abs(steps) * 5))
    end
end

local function wifiIcon(wifi: WiFi?): string
    if not wifi or not wifi.power or not wifi.connected then
        return "wifi_off"
    end
    return icons.wifi(wifi.rssi)
end

local function bluetoothIcon(bluetooth: Bluetooth): string
    if not bluetooth.power then
        return "bluetooth_disabled"
    end
    for _, device in bluetooth.devices do
        if device.connected then
            return "bluetooth_connected"
        end
    end
    return "bluetooth"
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

local function line(label: string, value: string, width: number)
    return ui.row{ w = width,
        ui.text{ text = label, font = "sans", size = tokens.body.small, color = "secondaryForeground" },
        ui.box{ grow = 1, h = 1 },
        ui.text{ text = value, font = "sans", size = tokens.body.small, weight = "medium", maxWidth = width * 0.6 } }
end

local function action(text: string, command: string, width: number)
    return ui.row{ w = width, h = 40, radius = 20, fill = "secondaryContainer",
        hover = "secondaryContainerForeground/0.08", onClick = command,
        ui.box{ grow = 1, h = 1 },
        ui.text{ text = text, font = "sans", size = tokens.label.large, weight = "medium",
            color = "secondaryContainerForeground" },
        ui.box{ grow = 1, h = 1 } }
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

local function duration(minutes: number): string
    local hours = math.floor(minutes / 60)
    local rest = math.floor(minutes % 60)
    if hours > 0 then
        return omniwm.l10n("%lldh %lldm", hours, rest)
    end
    return omniwm.l10n("%lldm", rest)
end

local function networkPanel(ctx: Context)
    local width = tokens.bar.popout.network
    local inner = width - 2 * tokens.padding.large
    local wifi = ctx.data.wifi
    local rows = {}
    local status = not wifi and omniwm.l10n("Unavailable") or not wifi.power and omniwm.l10n("Off")
        or wifi.connected and omniwm.l10n("Connected") or omniwm.l10n("Not Connected")
    rows[#rows + 1] = heading(wifiIcon(wifi), omniwm.l10n("Wi-Fi"), status, inner)
    if wifi and wifi.connected then
        if wifi.ssid then
            rows[#rows + 1] = ui.text{ text = wifi.ssid, font = "sans", size = tokens.title.medium, weight = "medium",
                maxWidth = inner }
        elseif wifi.location ~= "authorized" then
            rows[#rows + 1] = action(omniwm.l10n("Allow Location Access to show the network name"), "wifi authorize",
                inner)
        else
            rows[#rows + 1] = ui.text{ text = omniwm.l10n("Network name hidden"), font = "sans",
                size = tokens.body.medium, color = "secondaryForeground" }
        end
        if wifi.band then
            rows[#rows + 1] = line(omniwm.l10n("Band"), wifi.band, inner)
        end
        if wifi.security then
            rows[#rows + 1] = line(omniwm.l10n("Security"), wifi.security, inner)
        end
    end
    local network = ctx.data.network
    if network then
        rows[#rows + 1] = line(omniwm.l10n("Download"), ctx.format.bytes(network.down, "file") .. "/s", inner)
        rows[#rows + 1] = line(omniwm.l10n("Upload"), ctx.format.bytes(network.up, "file") .. "/s", inner)
    end
    rows[#rows + 1] = action(omniwm.l10n("Wi-Fi Settings…"), "wifi settings", inner)
    return panel(width, rows)
end

local function bluetoothPanel(ctx: Context)
    local width = tokens.bar.popout.network
    local inner = width - 2 * tokens.padding.large
    local bluetooth = ctx.data.bluetooth
    local rows = {}
    if not bluetooth then
        return panel(width, { heading("bluetooth_disabled", omniwm.l10n("Bluetooth"), omniwm.l10n("Unavailable"), inner) })
    end
    local connected = 0
    for _, device in bluetooth.devices do
        connected += device.connected and 1 or 0
    end
    rows[#rows + 1] = heading(bluetoothIcon(bluetooth), omniwm.l10n("Bluetooth"),
        bluetooth.power and omniwm.l10n("Bluetooth: %lld connected", connected) or omniwm.l10n("Bluetooth: Off"), inner)
    if bluetooth.access ~= "granted" then
        rows[#rows + 1] = action(omniwm.l10n("Allow Bluetooth access to list devices"), "bluetooth authorize", inner)
    end
    for _, device in bluetooth.devices do
        local battery = device.battery or device.left or device.right
        rows[#rows + 1] = ui.row{ key = device.id, w = inner, gap = tokens.spacing.medium, pad = tokens.padding.small,
            radius = tokens.rounding.large, fill = device.connected and "secondaryContainer" or nil,
            surface.icon(icons.bluetooth(device.kind), { size = tokens.icon.small,
                color = device.connected and "secondaryContainerForeground" or "secondaryForeground", filled = true }),
            ui.text{ text = device.name, font = "sans", size = tokens.body.small, grow = 1, maxWidth = inner - 110,
                color = device.connected and "secondaryContainerForeground" or "foreground" },
            battery and ui.text{ text = ctx.format.percent(battery / 100), font = "sans", size = tokens.body.small,
                color = "secondaryForeground" } or nil }
    end
    rows[#rows + 1] = action(omniwm.l10n("Bluetooth Settings…"), "bluetooth settings", inner)
    return panel(width, rows)
end

local function batteryPanel(ctx: Context)
    local width = tokens.bar.popout.battery
    local inner = width - 2 * tokens.padding.large
    local level = ctx.data.battery or 0
    local power = ctx.data.power
    local charging = ctx.data.charging
    local rows = {}
    local status = power and power.charged and omniwm.l10n("Fully charged") or charging and omniwm.l10n("Charging")
        or omniwm.l10n("On battery")
    rows[#rows + 1] = ui.row{ w = inner, gap = tokens.spacing.medium,
        surface.icon(icons.battery(level / 100, charging), { size = tokens.icon.large,
            color = (level <= 20 and not charging) and "error" or "accent", filled = true }),
        ui.column{ center = false, gap = 2,
            ui.text{ text = ctx.format.percent(level / 100), font = "sans", size = tokens.headline.small,
                weight = "medium" },
            ui.text{ text = status, font = "sans", size = tokens.body.small, color = "secondaryForeground" } } }
    if power and power.remaining and not charging then
        rows[#rows + 1] = line(omniwm.l10n("Time Remaining"), duration(power.remaining), inner)
    elseif power and power.full and charging then
        rows[#rows + 1] = line(omniwm.l10n("Time to Full"), duration(power.full), inner)
    end
    if power and power.lowPower then
        rows[#rows + 1] = line(omniwm.l10n("Low Power Mode"), omniwm.l10n("On"), inner)
    end
    rows[#rows + 1] = action(omniwm.l10n("Battery Settings…"), "battery settings", inner)
    return panel(width, rows)
end

local function audioPanel(ctx: Context)
    local width = tokens.bar.popout.audio
    local inner = width - 2 * tokens.padding.large
    local volume = ctx.data.volume or 0
    local muted = ctx.data.muted
    local rows = {}
    rows[#rows + 1] = heading(icons.volume(volume / 100, muted), omniwm.l10n("Volume"), ctx.format.percent(volume / 100),
        inner)
    rows[#rows + 1] = ui.row{ w = inner, gap = tokens.spacing.small,
        surface.button(muted and "no_sound" or "volume_up", "tonal", { onClick = "volume mute", glyph = tokens.icon.small }),
        ui.slider{ value = volume / 100, grow = 1, h = 16, color = muted and "mutedForeground" or "accent",
            onChange = function(ctx, event)
                if event.value then
                    omniwm.run(string.format("volume set %d", math.round(event.value * 100)))
                end
            end } }
    for _, device in ctx.data.outputs or {} do
        rows[#rows + 1] = ui.row{ key = device.id, w = inner, gap = tokens.spacing.medium, pad = tokens.padding.small,
            radius = tokens.rounding.large, fill = device.default and "secondaryContainer" or nil, hover = HOVER,
            onClick = "volume output " .. device.id,
            surface.icon(device.transport == "bluetooth" and "headphones" or "speaker", { size = tokens.icon.small,
                color = device.default and "secondaryContainerForeground" or "secondaryForeground", filled = true }),
            ui.text{ text = device.name, font = "sans", size = tokens.body.small, maxWidth = inner - 60,
                color = device.default and "secondaryContainerForeground" or "foreground" } }
    end
    local audio = ctx.data.audioApps
    if audio and audio.access == "denied" then
        rows[#rows + 1] = action(omniwm.l10n("Allow System Audio Recording to set app volumes"), "volume permission",
            inner)
    end
    for _, app in audio and audio.apps or {} do
        if app.playing or app.muted or app.volume < 100 then
            rows[#rows + 1] = ui.row{ key = app.id, w = inner, gap = tokens.spacing.small,
                ui.icon{ app = app.id, w = 20, h = 20, opacity = app.playing and 1 or 0.55 },
                ui.slider{ value = app.volume / 100, grow = 1, h = 14, color = app.muted and "mutedForeground" or "accent",
                    onChange = function(ctx, event)
                        if event.value then
                            omniwm.run(string.format("volume app %s set %d", app.id, math.round(event.value * 100)))
                        end
                    end } }
        end
    end
    return panel(width, rows)
end

local function keyboardPanel(ctx: Context)
    local width = tokens.bar.popout.keyboard
    local inner = width - 2 * tokens.padding.large
    local source = ctx.data.inputSource
    local rows = { heading("keyboard", omniwm.l10n("Input Sources"), source and source.name or nil, inner) }
    for _, entry in source and source.sources or {} do
        local selected = source and entry.id == source.id
        rows[#rows + 1] = ui.row{ key = entry.id, w = inner, gap = tokens.spacing.medium, pad = tokens.padding.small,
            radius = tokens.rounding.large, fill = selected and "secondaryContainer" or nil, hover = HOVER,
            onClick = "input-source select " .. entry.id,
            ui.text{ text = entry.short, font = "sans", size = tokens.label.medium, weight = "medium",
                color = selected and "secondaryContainerForeground" or "accent" },
            ui.text{ text = entry.name, font = "sans", size = tokens.body.small, maxWidth = inner - 70,
                color = selected and "secondaryContainerForeground" or "foreground" } }
    end
    rows[#rows + 1] = action(omniwm.l10n("Keyboard Settings…"), "input-source settings", inner)
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
    bluetoothIcon = bluetoothIcon,
    panel = panel,
    pane = pane,
    network = networkPanel,
    bluetooth = bluetoothPanel,
    battery = batteryPanel,
    audio = audioPanel,
    keyboard = keyboardPanel,
})
