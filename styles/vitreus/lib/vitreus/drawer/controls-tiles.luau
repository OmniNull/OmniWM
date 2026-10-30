-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("../kit")
local palette = require("../palette")
local buttons = require("../bar/buttons")

local entrance = table.freeze({ response = 2 * math.pi * 0.38 / 6.64, bounce = 0 })
local tiles = table.freeze({
    { name = "wifi", title = "Wi-Fi", x = 12, y = 8 },
    { name = "caffeine", title = "Caffeine", x = 109, y = 8 },
    { name = "notifications", title = "Notifications", x = 206, y = 8 },
    { name = "bluetooth", title = "Bluetooth", x = 12, y = 84 },
    { name = "capture", title = "Capture", x = 109, y = 84 },
    { name = "power", title = "Power", x = 206, y = 84 },
})

local paths = table.freeze({
    wifi = "M 2 8 Q 12 0 22 8 M 5.5 12 Q 12 6 18.5 12 M 9 16 Q 12 13 15 16 M 12 20 L 12 20.01",
    bluetooth = "M 11 1 L 18 7 L 6 17 M 11 1 L 11 23 L 18 17 L 6 7",
    caffeine = "M 3 8 L 3 16 Q 3 21 8 21 L 12 21 Q 17 21 17 16 L 17 8 Z M 17 9 L 20 9 Q 24 14 17 16 M 6 4 L 6 1 M 11 4 L 11 0 M 16 4 L 16 1",
    notifications = "M 3 18 L 6 14 L 6 9 Q 6 2 12 2 Q 18 2 18 9 L 18 14 L 21 18 Z M 9 21 Q 12 25 15 21",
    capture = "M 3 6 L 7 6 L 9 3 L 15 3 L 17 6 L 21 6 Q 23 6 23 8 L 23 20 L 1 20 L 1 8 Q 1 6 3 6 Z M 16.5 13 A 4.5 4.5 0 1 0 7.5 13 A 4.5 4.5 0 1 0 16.5 13",
    power = "M 7 4 A 9 9 0 1 0 17 4 M 12 0 L 12 11",
})

local function icon(name, cu, key, active)
    local side = 24 * cu
    return ui.stack(buttons.glow({ key = key, decorative = true, w = side, h = side,
        opacity = if active then 1 else 0.68,
        ui.path({ w = side, h = side, d = paths[name], viewBox = { 0, 0, 24, 24 }, fill = 0,
            border = palette.roles.ink, borderWidth = 1.5 * cu }),
    }, cu))
end

local function state(ctx, name)
    if name == "wifi" then
        local data = ctx.data.wifi
        if not data then return false, "No adapter", false end
        return data.power, if data.connected then (data.ssid or "Connected") else if data.power then "Disconnected" else "Off", true
    end
    if name == "bluetooth" then
        local data = ctx.data.bluetooth
        if not data then return false, "Unavailable", false end
        if not data.power then return false, "Off", true end
        for _, device in data.devices do
            if device.connected then return true, device.name, true end
        end
        return true, "No device", true
    end
    if name == "caffeine" then
        local awake = ctx.data.awake
        if not awake then return false, "Unavailable", false end
        if not awake.on then return false, "Off", true end
        if awake["until"] then
            local minutes = math.max(0, math.ceil((awake["until"] - ctx.data.seconds) / 60))
            return true, tostring(minutes) .. " min", true
        end
        return true, "Awake", true
    end
    if name == "notifications" then
        local data = ctx.data.notifications
        if not data then return false, "History", true end
        if data.state == "accessDenied" then return false, "Access denied", true end
        if data.state ~= "ready" and data.state ~= "empty" then return false, "Unavailable", true end
        local count = #data.items
        return false, if count == 0 then "No notifications" else tostring(count) .. " saved", true
    end
    return false, if name == "capture" then "Shot · Record" else "Lock · Sleep · Off", true
end

local function touch(name)
    return function(next, event)
        if event.button ~= "left" or event.phase ~= "down" then return end
        local touches = next.state.controlsTouches or {}
        touches[name] = (touches[name] or 0) + 1
        next.state.controlsTouches = touches
    end
end

local function ripple(ctx, name, cu)
    local serial = (ctx.state.controlsTouches or {})[name]
    if not serial then return nil end
    local side = 14 * cu
    return ui.path({ key = "controls-touch-" .. name .. "-" .. tostring(serial), decorative = true,
        w = side, h = side, align = "topLeading", dx = 66 * cu, dy = 11 * cu,
        d = kit.circle(side / 2, side / 2, 6 * cu), fill = 0,
        border = palette.roles.mint, borderWidth = 1.4 * cu, opacity = 0,
        appear = { opacity = 0.55, animate = { duration = 0.7, curve = "linear" }, delay = 0.04 },
        pulse = { key = serial, duration = 0.74, scale = { 0, 2, 4, 6, 9, 0 } },
    })
end

local function switch(ctx, p, model, name, on, available)
    local cu = p.cu
    local width = if on then 38 else 34
    local left = 86 - width
    local knob = left + 11 + (if on then width - 22 else 0)
    return ui.stack({ key = "controls-toggle-" .. name, w = 46 * cu, h = 30 * cu,
        align = "topLeading", dx = 45 * cu, dy = 3 * cu,
        cursor = if available then "pointer" else nil,
        onClick = if available then function(next) model.toggle(next, name) end else nil,
        onPress = if available then touch(name) else nil,
        ui.box({ key = "controls-track-" .. name, w = width * cu, h = 22 * cu, radius = (if on then 9 else 11) * cu,
            align = "topLeading", dx = (left - 45) * cu, dy = 4 * cu,
            fill = palette.alpha(if on then "mint" else "off", 1), animate = kit.springs.pop,
            shadow = palette.alpha("mint", if on then 0.48 else 0), shadowRadius = 10 * cu,
            shadowOffset = { x = 0, y = 0 },
        }),
        ui.box({ key = "controls-knob-" .. name, w = 17 * cu, h = 17 * cu,
            radius = (if on then 6.5 else 8.5) * cu, align = "topLeading", dx = (knob - 45 - 8.5) * cu, dy = 6.5 * cu,
            fill = palette.roles.ink, animate = kit.springs.pop,
            shadow = palette.alpha("deep", 0.26), shadowRadius = 5 * cu, shadowOffset = { x = 0, y = 2 * cu },
        }),
        ui.box({ key = "controls-knob-mark-" .. name, w = 3 * cu, h = 3 * cu, radius = 1.5 * cu,
            align = "topLeading", dx = (knob - 45 - 1.5) * cu, dy = 13.5 * cu,
            fill = palette.roles.off, animate = kit.springs.pop,
        }),
    })
end

local function auxiliary(model, p, name)
    local cu = p.cu
    if name == "power" then return nil end
    local c = kit.canvas(40 * cu, 30 * cu, cu, p.rs)
    return ui.stack({ key = "controls-toggle-" .. name, w = c.w, h = c.h,
        align = "topLeading", dx = 49 * cu, dy = 3 * cu, cursor = "pointer",
        onClick = function(next) model.toggle(next, name) end, onPress = touch(name),
        if name == "notifications" then
            ui.box({ w = 34 * cu, h = 22 * cu, radius = 11 * cu, fill = palette.alpha("ink", 0.1) }) else nil,
        if name == "notifications" then kit.label(c, { text = "Focus", size = 8.5, color = palette.roles.ink }) else nil,
        if name == "capture" then ui.path({ w = c.w, h = c.h, decorative = true,
            d = kit.circle(c.w / 2, c.h / 2, 9 * cu), fill = 0, border = palette.roles.ink, borderWidth = 1.4 * cu,
            opacity = 0.7 }) else nil,
        if name == "capture" then ui.box({ w = 9 * cu, h = 9 * cu, radius = 4.5 * cu,
            fill = palette.alpha("mint", 0.8), decorative = true }) else nil,
    })
end

local function tile(ctx, p, model, spec)
    local cu = p.cu
    local on, subtitle, available = state(ctx, spec.name)
    local c = kit.canvas(94 * cu, 72 * cu, cu, p.rs)
    local switchable = spec.name == "wifi" or spec.name == "bluetooth" or spec.name == "caffeine"
    return ui.stack({ key = "controls-tile-" .. spec.name, w = c.w, h = c.h,
        align = "topLeading", dx = spec.x * cu, dy = spec.y * cu, radius = 12 * cu,
        fill = palette.alpha("ink", palette.veil), hover = palette.alpha("ink", palette.veil + 0.06),
        cursor = "pointer", onClick = function(next) model.open(next, spec.name) end,
        onPress = touch(spec.name), opacity = if available then 1 else 0.55,
        ui.stack({ w = c.w, h = c.h, decorative = true,
            ui.path({ mask = true, w = c.w, h = c.h, d = kit.roundedRect(0, 0, c.w, c.h, 12 * cu) }),
            ui.box({ key = "controls-flood-" .. spec.name, w = 192 * cu, h = 192 * cu, radius = 96 * cu,
                align = "topLeading", dx = -23 * cu, dy = -78 * cu,
                fill = palette.alpha("mint", 0.15), scale = if on then 1 else 0,
                animate = kit.springs.pop,
            }),
            ripple(ctx, spec.name, cu),
        }),
        ui.stack(kit.at(c, { decorative = true, w = 24 * cu, h = 24 * cu,
            icon(spec.name, cu, "controls-icon-" .. spec.name, on),
        }, 20 * cu, 20 * cu)),
        kit.label(c, { key = "controls-title-" .. spec.name, text = spec.title, size = 13,
            align = "leading", x = 10 * cu, y = 40 * cu, maxWidth = 74 * cu, lines = 1 }),
        kit.label(c, { key = "controls-state-" .. spec.name, text = subtitle, size = 11.5,
            color = if on then palette.alpha("mint", 0.9) else palette.roles.faint,
            align = "leading", x = 10 * cu, y = 55 * cu, maxWidth = 74 * cu, lines = 1 }),
        if switchable then switch(ctx, p, model, spec.name, on, available) else auxiliary(model, p, spec.name),
    })
end

local function content(ctx, p, model)
    local items = { key = "controls-f2", w = p.w, h = 156 * p.cu, align = "topLeading",
        appear = { opacity = 0, dy = 12 * p.cu, delay = 0.2, animate = entrance },
        exit = { opacity = 0, dy = 12 * p.cu, animate = kit.springs.close },
    }
    for _, spec in tiles do items[#items + 1] = tile(ctx, p, model, spec) end
    return ui.stack(items)
end

return table.freeze({ content = content })
