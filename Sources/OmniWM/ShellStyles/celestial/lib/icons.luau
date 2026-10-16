-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local weatherCodes: { [number]: string } = {
    [0] = "clear_day",
    [1] = "clear_day",
    [2] = "partly_cloudy_day",
    [3] = "cloud",
    [45] = "foggy",
    [48] = "foggy",
    [71] = "cloudy_snowing",
    [73] = "cloudy_snowing",
    [75] = "snowing_heavy",
    [77] = "cloudy_snowing",
    [85] = "cloudy_snowing",
    [86] = "snowing_heavy",
    [95] = "thunderstorm",
    [96] = "thunderstorm",
    [99] = "thunderstorm",
}

local rain = { 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82 }
for _, code in rain do
    weatherCodes[code] = "rainy"
end

local function weather(code: number, day: boolean?): string
    local icon = weatherCodes[code] or "air"
    if day == false then
        icon = string.gsub(icon, "_day$", "_night")
    end
    return icon
end

local wifiLevels = { "signal_wifi_0_bar", "network_wifi_1_bar", "network_wifi_2_bar", "network_wifi_3_bar", "network_wifi" }

local function wifi(rssi: number?, secure: boolean?): string
    local strength = math.clamp(((rssi or -100) + 100) * 2, 0, 100)
    local level = math.clamp(math.floor(strength / 20), 0, 4)
    local icon = wifiLevels[level + 1]
    if secure and level > 0 then
        icon ..= "_locked"
    end
    return icon
end

local function battery(fraction: number, charging: boolean?): string
    if fraction >= 1 then
        return charging and "battery_charging_full" or "battery_full"
    end
    local level = math.floor(math.max(fraction, 0) * 7)
    if charging and (level == 4 or level == 1) then
        level -= 1
    end
    return charging and string.format("battery_charging_%d", (level + 3) * 10) or string.format("battery_%d_bar", level)
end

local function volume(level: number, muted: boolean?): string
    if muted then
        return "no_sound"
    end
    if level >= 0.5 then
        return "volume_up"
    end
    return level > 0 and "volume_down" or "volume_mute"
end

local bluetoothKinds: { [string]: string } = {
    headphones = "headphones",
    keyboard = "keyboard",
    mouse = "mouse",
    gamepad = "stadia_controller",
    computer = "computer",
    phone = "smartphone",
}

local function bluetooth(kind: string?): string
    return kind and bluetoothKinds[kind] or "bluetooth"
end

return table.freeze({
    weather = weather,
    wifi = wifi,
    battery = battery,
    volume = volume,
    bluetooth = bluetooth,
})
