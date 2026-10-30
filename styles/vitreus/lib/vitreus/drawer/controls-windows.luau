-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("../kit")
local palette = require("../palette")
local lengths = table.freeze({ 0, 15, 30, 60, 120, 240, -1 })
local session = table.freeze({ "lock", "sleep", "logout", "restart", "shutdown" })
local sessionNames = table.freeze({ "Lock", "Sleep", "Log out", "Restart", "Power off" })
local sessionIcons = table.freeze({ "lock", "moon", "rectangle.portrait.and.arrow.right", "arrow.clockwise", "power" })

local function label(c, key, value, x, y, size, color, weight, width)
    return kit.label(c, { key = key, text = value, x = x * c.du, y = y * c.du,
        size = size, color = color or palette.roles.ink, weight = weight, maxWidth = (width or 276) * c.du,
        lines = 1, decorative = true })
end

local function at(c, props, x, y)
    return kit.at(c, props, x * c.du, y * c.du)
end

local function button(c, key, text, x, y, w, h, command)
    return ui.stack(at(c, { key = key, w = w * c.du, h = h * c.du, radius = 12 * c.du,
        fill = palette.alpha("ink", 0.08), hover = palette.alpha("mint", 0.2), cursor = "pointer", onClick = command,
        kit.label(kit.canvas(w * c.du, h * c.du, c.du, c.rs), { text = text, size = 13, weight = "bold", lines = 1,
            maxWidth = (w - 8) * c.du }),
    }, x, y))
end

local function visibleNotifications(data)
    local hidden, rows = {}, {}
    for _, id in (data and data.dispatched) or {} do hidden[string.lower(id)] = true end
    for _, item in (data and data.items) or {} do
        if not hidden[string.lower(item.id)] then rows[#rows + 1] = item end
    end
    return rows
end

local function batteries(ctx)
    local result = {}
    local battery = ctx.data.battery
    if battery then
        result[#result + 1] = { name = "This computer", percent = battery, charging = ctx.data.charging }
    end
    for _, device in (ctx.data.bluetooth and ctx.data.bluetooth.devices) or {} do
        if device.connected and device.battery then
            result[#result + 1] = { name = device.name, percent = device.battery }
        end
    end
    return result
end

local function height(ctx)
    if ctx.state.controlsPanel == "power" then
        local rows = batteries(ctx)
        return 229 + (if #rows > 0 then 20 + 56 * #rows else 0)
    end
    return 308
end

local function wifi(ctx, c, items)
    local data = ctx.data.wifi
    local name = if not data then "No adapter" elseif not data.power then "Wi-Fi is off"
        elseif data.connected then data.ssid or "Connected network" else "Not connected"
    items[#items + 1] = label(c, "controls-wifi-name", name, 156, 82, 18, palette.roles.mint, "bold")
    local detail = if data and data.connected then
        table.concat({ data.band or "", if data.channel then "Channel " .. tostring(data.channel) else "",
            data.security or "" }, "  ") else "Join a network in macOS Settings"
    items[#items + 1] = label(c, "controls-wifi-detail", detail, 156, 112, 12.5, palette.roles.faint)
    if data and data.rssi then
        items[#items + 1] = label(c, "controls-wifi-signal", tostring(data.rssi) .. " dBm", 156, 142, 13)
    end
    items[#items + 1] = button(c, "controls-wifi-settings", "Wi-Fi Settings", 156, 208, 276, 42, "wifi settings")
end

local function bluetooth(ctx, c, items)
    local data = ctx.data.bluetooth
    local rows = (data and data.devices) or {}
    items[#items + 1] = label(c, "controls-bluetooth-state", if not data then "Bluetooth unavailable"
        elseif data.access ~= "granted" then "Allow access in Bluetooth Settings"
        elseif data.power then "Devices" else "Bluetooth is off", 156, 70, 13, palette.roles.faint)
    local list = { key = "controls-bluetooth-list", w = 276 * c.du, h = 152 * c.du, gap = 4 * c.du,
        align = "topLeading", dx = 18 * c.du, dy = 86 * c.du, scroll = true, center = false }
    for _, device in rows do
        local row = kit.canvas(276 * c.du, 34 * c.du, c.du, c.rs)
        list[#list + 1] = ui.stack({ key = "controls-bluetooth-" .. device.id, w = row.w, h = row.h,
            radius = 10 * c.du, fill = palette.alpha("ink", 0.06), hover = palette.alpha("mint", 0.14),
            cursor = "pointer", onClick = "bluetooth settings",
            kit.label(row, { text = device.name, x = 12 * c.du, y = 17 * c.du, align = "leading", size = 13,
                maxWidth = 162 * c.du, lines = 1 }),
            label(row, nil, if device.connected then
                (if device.battery then tostring(device.battery) .. "%" else "Connected") else "Pair…",
                226, 17, 11.5, if device.connected then palette.roles.mint else palette.roles.faint, nil, 88),
        })
    end
    if #rows == 0 then list[#list + 1] = ui.stack({ w = list.w, h = 34 * c.du,
        kit.label(kit.canvas(list.w, 34 * c.du, c.du, c.rs), { text = "No devices", size = 14,
            color = palette.roles.faint }) }) end
    items[#items + 1] = ui.column(list)
    items[#items + 1] = button(c, "controls-bluetooth-settings", "Bluetooth Settings", 156, 274,
        276, 36, "bluetooth settings")
end

local function caffeine(ctx, c, items)
    local data = ctx.data.awake
    local on = data and data.on
    local left = if on and data["until"] then math.max(0, data["until"] - ctx.data.seconds) else nil
    local chosen = if not on then 1 elseif not left then 7 else ctx.state.controlsAwakeChoice
    if left and chosen and (chosen < 2 or chosen > 6 or left > lengths[chosen] * 60 + 1) then chosen = nil end
    if not chosen then
        chosen = 6
        for index = 2, 6 do if left <= lengths[index] * 60 then chosen = index break end end
    end
    local duration = if chosen > 1 and chosen < 7 then lengths[chosen] * 60 else 1
    local progress = if not on then 0 elseif not left then 1 else math.clamp(left / duration, 0, 1)
    items[#items + 1] = kit.stroke(c, kit.circle(90 * c.du, 136 * c.du, 44 * c.du),
        palette.alpha("ink", 0.1), 5 * c.du, "controls-awake-ring-base")
    if on then
        local path, evenOdd = kit.ringPath(90 * c.du, 136 * c.du, 44 * c.du, 5 * c.du, progress)
        items[#items + 1] = ui.path({ key = "controls-awake-ring", w = c.w, h = c.h,
            d = path, fill = palette.roles.mint, evenOdd = evenOdd, decorative = true })
    end
    items[#items + 1] = ui.symbol(at(c, { name = "cup.and.saucer", size = 46 * c.du,
        color = if on then palette.roles.mint else palette.roles.faint, decorative = true }, 90, 136))
    items[#items + 1] = label(c, "controls-awake-time", if not on then "Off" elseif left then
        tostring(math.ceil(left / 60)) .. "m" else "On", 214, 126, 36, if on then palette.roles.mint else palette.roles.faint, "bold", 130)
    items[#items + 1] = label(c, "controls-awake-detail", if not on then "No awake timer"
        elseif left then "until this timer ends" else "until turned off",
        214, 156, 12.5, palette.roles.faint, nil, 124)
    items[#items + 1] = ui.box(at(c, { w = 266 * c.du, h = 36 * c.du, radius = 18 * c.du,
        fill = palette.alpha("ink", 0.08) }, 156, 234))
    items[#items + 1] = ui.box(at(c, { key = "controls-awake-thumb", w = 34 * c.du, h = 26 * c.du,
        radius = 10 * c.du, fill = if on then palette.roles.mint else palette.alpha("ink", 0.16),
        shadow = if on then palette.alpha("mint", 0.48) else nil, shadowRadius = 10 * c.du,
        animate = kit.springs.pop }, 42 + (chosen - 1) * 38, 234))
    for index, minutes in lengths do
        local command = if minutes == 0 or (on and chosen == index) then "off"
            elseif minutes < 0 then "on" else tostring(minutes)
        items[#items + 1] = ui.stack(at(c, { key = "controls-awake-stop-" .. tostring(index - 1),
            w = 38 * c.du, h = 36 * c.du, cursor = "pointer", onClick = function(next)
                next.state.controlsAwakeChoice = index
                omniwm.run("session awake " .. command)
            end,
            kit.label(kit.canvas(38 * c.du, 36 * c.du, c.du, c.rs), { text = if minutes == 0 then "Off"
                elseif minutes < 0 then "∞" elseif minutes < 60 then tostring(minutes) .. "m"
                else tostring(minutes / 60) .. "h", size = 12, weight = "bold",
                color = if chosen == index and on then palette.roles.onmint else palette.roles.ink }),
        }, 42 + (index - 1) * 38, 234))
    end
end

local function notifications(ctx, c, items)
    local data = ctx.data.notifications
    local rows = visibleNotifications(data)
    items[#items + 1] = button(c, "controls-notifications-focus", "Do Not Disturb · Focus Settings", 156, 76,
        276, 36, "focus settings")
    items[#items + 1] = label(c, nil, "HISTORY", 60, 110, 10.5, palette.roles.faint, "bold", 84)
    items[#items + 1] = button(c, "controls-notifications-clear", "Clear", 268, 110, 52, 24, "notifications dismiss-all")
    local list = { key = "controls-notifications-list", w = 276 * c.du, h = 150 * c.du, gap = 6 * c.du,
        align = "topLeading", dx = 18 * c.du, dy = 126 * c.du, center = false, scroll = true }
    for _, item in rows do
        local row = kit.canvas(276 * c.du, 54 * c.du, c.du, c.rs)
        list[#list + 1] = ui.stack({ key = "controls-notification-" .. item.id, w = row.w, h = row.h,
            fill = palette.alpha("ink", 0.06), radius = 12 * c.du,
            kit.label(row, { text = item.title, x = 10 * c.du, y = 16 * c.du, align = "leading", size = 13,
                weight = "bold", maxWidth = 226 * c.du, lines = 1 }),
            kit.label(row, { text = item.body, x = 10 * c.du, y = 37 * c.du, align = "leading", size = 11.5,
                color = palette.roles.faint, maxWidth = 226 * c.du, lines = 1 }),
            button(row, "controls-notification-dismiss-" .. item.id, "×", 256, 27, 26, 30,
                "notifications dismiss " .. item.bundle .. " " .. item.id),
        })
    end
    if #rows == 0 then
        local status = if not data then "History unavailable" elseif data.state == "accessDenied" then
            "Allow notification history in Settings" elseif data.state == "loading" then "Loading history…"
            elseif data.state == "ready" or data.state == "empty" then "All clear" else data.error or "History unavailable"
        list[#list + 1] = ui.stack({ w = list.w, h = 110 * c.du,
            kit.label(kit.canvas(list.w, 110 * c.du, c.du, c.rs), { text = status, size = 13,
                color = palette.roles.faint, maxWidth = 260 * c.du, lines = 2 }) })
    end
    items[#items + 1] = ui.column(list)
    if data and data.dismissAll and data.dismissAll.active then
        items[#items + 1] = button(c, "controls-notifications-cancel", "Stop clearing", 156, 292,
            150, 24, "notifications cancel-dismiss-all")
    elseif data and data.action then
        items[#items + 1] = label(c, "controls-notifications-action", "Notification: " .. tostring(data.action.state),
            156, 292, 11, palette.roles.faint)
    end
end

local function power(ctx, c, items, actions)
    local pending, burst = ctx.state.controlsHold, ctx.state.controlsBurst
    items[#items + 1] = label(c, nil, "SESSION", 54, 70, 11, palette.roles.faint, "bold", 72)
    for index, command in session do
        local x = 43 + (index - 1) * 56.5
        local held = pending and pending.action == command
        local gone = burst and burst.action == command
        local inner = kit.canvas(52 * c.du, 58 * c.du, c.du, c.rs)
        items[#items + 1] = ui.stack(at(c, { key = "controls-power-" .. command, w = inner.w, h = inner.h,
            radius = 14 * c.du, fill = palette.alpha("ink", 0.08), hover = palette.alpha("mint", 0.2),
            cursor = if burst then nil else "pointer", opacity = if gone then 0 else 1,
            onPress = if not burst then function(next, event) actions.hold(next, event, command) end else nil,
            ui.path({ mask = true, w = inner.w, h = inner.h,
                d = kit.roundedRect(0, 0, inner.w, inner.h, 14 * c.du) }),
            ui.box({ key = "controls-power-progress-" .. command, w = inner.w, h = if held then inner.h else 0,
                align = "bottom", fill = palette.alpha("mint", 0.34),
                animate = { duration = if held then 1 else 0, curve = "linear" } }),
            ui.symbol(at(inner, { name = sessionIcons[index], size = 22 * c.du,
                color = palette.roles.ink, decorative = true }, 26, 21)),
            label(inner, nil, if held then "Hold 1s" else sessionNames[index], 26, 48, 11,
                if held then palette.roles.mint else palette.roles.ink, "bold", 50),
        }, x, 104))
    end
    local rows = batteries(ctx)
    local extra = if #rows > 0 then 20 + 56 * #rows else 0
    if #rows > 0 then items[#items + 1] = label(c, nil, "BATTERY", 58, 150, 11, palette.roles.faint, "bold", 80) end
    for index, row in rows do
        local localC = kit.canvas(276 * c.du, 50 * c.du, c.du, c.rs)
        items[#items + 1] = ui.stack(at(c, { key = "controls-battery-" .. tostring(index), w = localC.w, h = localC.h,
            radius = 12 * c.du, fill = palette.alpha("ink", 0.08),
            label(localC, nil, row.name, 90, 15, 13, nil, "bold", 160),
            label(localC, nil, tostring(row.percent) .. "%" .. (if row.charging then " · Charging" else ""),
                220, 15, 11, palette.roles.mint, nil, 100),
            ui.box({ w = 252 * c.du, h = 5 * c.du, radius = 2.5 * c.du, fill = palette.alpha("ink", 0.12),
                align = "topLeading", dx = 12 * c.du, dy = 34 * c.du }),
            ui.box({ w = 252 * c.du * math.clamp(row.percent / 100, 0, 1), h = 5 * c.du,
                radius = 2.5 * c.du, fill = palette.roles.mint, align = "topLeading", dx = 12 * c.du, dy = 34 * c.du }),
        }, 156, 187 + (index - 1) * 56))
    end
    items[#items + 1] = label(c, nil, "POWER PROFILE", 82, 150 + extra, 11, palette.roles.faint, "bold", 128)
    local saver = ctx.data.power and ctx.data.power.lowPower == true
    local modes = { key = "controls-power-settings", w = 276 * c.du, h = 46 * c.du,
        radius = 16 * c.du, fill = palette.alpha("ink", 0.08) }
    local localC = kit.canvas(276 * c.du, 46 * c.du, c.du, c.rs)
    for index, mode in { "Saver", "Balanced", "Performance" } do
        modes[#modes + 1] = ui.stack(at(localC, { key = "controls-power-mode-" .. string.lower(mode),
            w = 90 * c.du, h = 44 * c.du, radius = 15 * c.du,
            fill = if index == 1 and saver then palette.alpha("mint", 0.24) else nil,
            hover = palette.alpha("ink", 0.12), cursor = "pointer", onClick = "battery settings",
            ui.symbol({ name = ({ "leaf", "equal", "bolt" })[index], size = 16 * c.du,
                align = "top", dy = 5 * c.du, color = if index == 1 and saver then palette.roles.mint else palette.roles.ink,
                decorative = true }),
            label(kit.canvas(90 * c.du, 44 * c.du, c.du, c.rs), nil, mode, 45, 33, 11.5,
                if index == 1 and saver then palette.roles.mint else palette.roles.ink, "semibold", 88),
        }, 46 + (index - 1) * 92, 23))
    end
    items[#items + 1] = ui.stack(at(c, modes, 156, 184 + extra))
    items[#items + 1] = label(c, nil, "Managed in macOS Battery Settings", 156, 219 + extra, 10, palette.roles.faint)
    if burst then
        items[#items + 1] = ui.shader(at(c, { key = "controls-power-shatter-" .. tostring(burst.serial),
            source = "vitreus-shatter.metal", w = 312 * c.du, h = 260 * c.du, fps = 60,
            values = { c.du, burst.serial }, decorative = true }, 43 + (table.find(session, burst.action) - 1) * 56.5, 104))
    end
end

local function content(ctx, p, actions)
    local c = kit.canvas(p.w, p.h, p.cu, p.rs)
    local name = ctx.state.controlsPanel
    local items = { key = "controls-window-" .. name, w = p.w, h = p.h, align = "topLeading",
        appear = { opacity = 0, dy = 12 * p.cu, delay = 0.2, animate = kit.springs.fd2 },
        exit = { opacity = 0, animate = kit.springs.close },
        button(c, "controls-back", "‹", 32, 30, 30, 30, function(next) actions.open(next, nil) end),
        label(c, "controls-window-title", string.upper(name), 162, 30, 17, nil, "bold", 240),
        ui.box(at(c, { w = 276 * c.du, h = c.du, fill = palette.alpha("ink", 0.08) }, 156, 52)),
    }
    if name == "wifi" then wifi(ctx, c, items)
    elseif name == "bluetooth" then bluetooth(ctx, c, items)
    elseif name == "caffeine" then caffeine(ctx, c, items)
    elseif name == "notifications" then notifications(ctx, c, items)
    elseif name == "power" then power(ctx, c, items, actions)
    elseif name == "capture" then
        items[#items + 1] = ui.symbol(at(c, { name = "viewfinder", size = 54 * c.du,
            color = palette.roles.mint, decorative = true }, 156, 114))
        items[#items + 1] = button(c, "controls-capture-settings", "Open Screenshot", 156, 190,
            276, 48, "screenshot settings")
        items[#items + 1] = label(c, nil, "Choose a region, display or recording in macOS", 156, 244, 12, palette.roles.faint)
    end
    if ctx.state.controlsError then
        items[#items + 1] = label(c, "controls-error", ctx.state.controlsError, 156, p.h / p.cu - 12,
            11, palette.roles.alert)
    end
    return ui.stack(items)
end

return table.freeze({ content = content, height = height })
