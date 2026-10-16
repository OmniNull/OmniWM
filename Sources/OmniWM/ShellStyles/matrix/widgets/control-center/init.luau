-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local style = require("../lib/style")
local audio = require("../lib/audio")
local media = require("../lib/media")
local HOVER = style.hover
local CONTENT = style.width
local INNER = CONTENT - 24
local CELL = INNER // 7
local TABS = {
    { id = "overview", symbol = "square.grid.2x2", label = omniwm.l10n("Control Center") },
    { id = "audio", symbol = "speaker.wave.2.fill", label = omniwm.l10n("Audio") },
    { id = "media", symbol = "music.note", label = omniwm.l10n("Media") },
    { id = "calendar", symbol = "calendar", label = omniwm.l10n("Calendar") },
    { id = "weather", symbol = "cloud.sun.fill", label = omniwm.l10n("Weather") },
    { id = "system", symbol = "gauge.with.needle", label = omniwm.l10n("System") },
}

local function button(name: string, command: string, _size: number?)
    return style.button(name, command)
end

local function card(props)
    props.w = CONTENT
    return style.group(props)
end

local function month(calendar)
    local data = calendar.month
    local marked = {}
    for _, day in data.marked do
        marked[day] = true
    end
    local rows = { gap = 0,
        ui.row{ w = INNER, gap = 4,
            ui.text{ style = "caption", text = data.title, size = 14, weight = "semibold", grow = 1 },
            button("chevron.left", "calendar month previous", 11),
            button("circle.fill", "calendar month today", 8),
            button("chevron.right", "calendar month next", 11) } }
    local header = { gap = 0 }
    for _, symbol in data.weekdays do
        header[#header + 1] = ui.stack{ w = CELL, h = 20,
            ui.text{ style = "caption", text = symbol, size = 11, color = "secondaryForeground" } }
    end
    rows[#rows + 1] = ui.row(header)
    local week = { gap = 0 }
    for _ = 1, data.offset do
        week[#week + 1] = ui.box{ w = CELL, h = 26 }
    end
    for day = 1, data.days do
        local today = day == data.today
        week[#week + 1] = ui.stack{ w = CELL, h = 26,
            ui.stack{ w = 26, h = 24, radius = 2, fill = if today then "accent" else nil,
                ui.text{ style = "caption", text = tostring(day), size = 13, weight = if today then "semibold" else nil,
                    color = if today then "accentForeground" else "foreground" } },
            ui.box{ align = "bottom", w = 4, h = 4, radius = 2, dy = 1,
                fill = if marked[day] and not today then "accent" else nil } }
        if #week == 7 then
            rows[#rows + 1] = ui.row(week)
            week = { gap = 0 }
        end
    end
    if #week > 0 then
        rows[#rows + 1] = ui.row(week)
    end
    return card(rows)
end

local function calendarTab(ctx)
    local calendar = ctx.data.calendar
    if not calendar or not calendar.month then
        return card{ ui.text{ style = "caption", text = omniwm.l10n("Unavailable"), size = 13, color = "secondaryForeground" } }
    end
    local rows = { gap = 8, center = false, month(calendar) }
    if calendar.access == "full" then
        local agenda = { gap = 2 }
        for _, event in calendar.events do
            if event["end"] > ctx.data.seconds and #agenda < 3 then
                agenda[#agenda + 1] = ui.row{ w = INNER, gap = 8, pad = 3, radius = 2, hover = HOVER,
                    onClick = "calendar open " .. event.id,
                    ui.box{ w = 3, h = 28, radius = 1.5, fill = event.color },
                    ui.column{ gap = 1, center = false,
                        ui.text{ style = "caption", text = event.title, size = 13, maxWidth = INNER - 20 },
                        ui.text{ style = "caption", text = event.day .. " · " .. (if event.allDay then omniwm.l10n("All day") else event.time),
                            size = 11, color = "secondaryForeground", maxWidth = INNER - 20 } } }
            end
        end
        if #agenda == 0 then
            agenda[#agenda + 1] = ui.text{ style = "caption", text = omniwm.l10n("No upcoming events"), size = 13, color = "secondaryForeground" }
        end
        rows[#rows + 1] = card(agenda)
    elseif calendar.access == "notDetermined" then
        rows[#rows + 1] = ui.row{ w = CONTENT, gap = 6, pad = 6, radius = 2, hover = HOVER, onClick = "calendar authorize",
            ui.symbol{ name = "calendar.badge.plus", w = 14, h = 14 },
            ui.text{ style = "caption", text = omniwm.l10n("Allow Calendar Access"), size = 13 } }
    else
        rows[#rows + 1] = ui.row{ w = CONTENT, gap = 6, pad = 6, radius = 2, hover = HOVER, onClick = "calendar settings",
            ui.symbol{ name = "lock.fill", w = 14, h = 14 },
            ui.text{ style = "caption", text = omniwm.l10n("Open Calendar Privacy Settings"), size = 13, maxWidth = CONTENT - 30, lines = 2 } }
    end
    return ui.column(rows)
end

local CONDITIONS = {
    Clear = omniwm.l10n("Clear"),
    ["Partly cloudy"] = omniwm.l10n("Partly cloudy"),
    Overcast = omniwm.l10n("Overcast"),
    Fog = omniwm.l10n("Fog"),
    Drizzle = omniwm.l10n("Drizzle"),
    ["Freezing rain"] = omniwm.l10n("Freezing rain"),
    Rain = omniwm.l10n("Rain"),
    Snow = omniwm.l10n("Snow"),
    Thunderstorms = omniwm.l10n("Thunderstorms"),
    Unknown = omniwm.l10n("Unknown"),
}

local function degrees(value: number?): string
    return value and string.format("%d°", math.round(value)) or "–"
end

local function weatherTab(ctx)
    local weather = ctx.data.weather
    if not weather then
        return card{ ui.text{ style = "caption", text = omniwm.l10n("Unavailable"), size = 13, color = "secondaryForeground" } }
    end
    local now = { gap = 1, center = false,
        ui.text{ style = "caption", text = degrees(weather.temp), size = 30, weight = "semibold" },
        ui.text{ style = "caption", text = CONDITIONS[weather.condition] or weather.condition, size = 13, maxWidth = INNER - 60 } }
    if weather.place then
        now[#now + 1] = ui.text{ style = "caption", text = weather.place, size = 11, color = "secondaryForeground", maxWidth = INNER - 60 }
    end
    local facts = { gap = 3, center = false }
    if weather.high and weather.low then
        facts[#facts + 1] = ui.text{ style = "caption", text = omniwm.l10n("High %@", degrees(weather.high)) .. "  "
            .. omniwm.l10n("Low %@", degrees(weather.low)), size = 11 }
    end
    if weather.feels then
        facts[#facts + 1] = ui.text{ style = "caption", text = omniwm.l10n("Feels like %@", degrees(weather.feels)), size = 11,
            color = "secondaryForeground" }
    end
    if weather.rain then
        facts[#facts + 1] = ui.text{ style = "caption", text = omniwm.l10n("%lld%% chance of rain", weather.rain), size = 11,
            color = "secondaryForeground" }
    end
    local hours = { gap = 0 }
    for index, hour in weather.hours do
        if index > 8 then
            break
        end
        hours[#hours + 1] = ui.column{ w = INNER / 8, gap = 4,
            ui.text{ style = "caption", text = hour.label, size = 11, color = "secondaryForeground", maxWidth = INNER / 8 },
            ui.symbol{ name = hour.symbol, w = 16, h = 16 },
            ui.text{ style = "caption", text = degrees(hour.temp), size = 11 } }
    end
    local low, high = math.huge, -math.huge
    for _, day in weather.days do
        low = math.min(low, day.low)
        high = math.max(high, day.high)
    end
    local span = math.max(1, high - low)
    local track = INNER - 192
    local days = { gap = 5 }
    for index, day in weather.days do
        if index > 5 then
            break
        end
        days[#days + 1] = ui.row{ w = INNER, gap = 8,
            ui.text{ style = "caption", text = day.label, size = 13, w = 50, maxWidth = 50 },
            ui.symbol{ name = day.symbol, w = 16, h = 16 },
            ui.text{ style = "caption", text = if day.rain and day.rain > 0 then ctx.format.percent(day.rain / 100) else "",
                size = 11, color = "accent", w = 30 },
            ui.text{ style = "caption", text = degrees(day.low), size = 12, color = "secondaryForeground", w = 28 },
            ui.stack{ w = track, h = 4, radius = 2, fill = "foreground/0.12",
                ui.box{ align = "leading", dx = (day.low - low) / span * track,
                    w = math.max(4, (day.high - day.low) / span * track), h = 4, radius = 2, fill = "accent" } },
            ui.text{ style = "caption", text = degrees(day.high), size = 12, w = 28 } }
    end
    return ui.column{ gap = 8,
        card{ ui.row{ w = INNER, gap = 12,
            ui.symbol{ name = weather.symbol, w = 40, h = 40 },
            ui.column(now) },
            ui.column(facts) },
        card{ ui.row(hours) },
        card(days) }
end

local function gauge(ctx, label: string, value: number?)
    local width = (INNER - 36) / 4
    return ui.column{ w = width, gap = 6,
        ui.text{ style = "caption", text = if value then ctx.format.percent(value / 100) else "—", size = 17, weight = "medium" },
        ui.progress{ value = (value or 0) / 100, w = width, h = 4, radius = 2, fill = "foreground/0.08",
            color = if value and value >= 90 then "warning" else "accent" },
        ui.text{ style = "caption", text = label, size = 11, color = "secondaryForeground" } }
end

local function systemTab(ctx)
    local data = ctx.data
    local rows = { gap = 8,
        card{ ui.row{ w = INNER, gap = 12,
            gauge(ctx, omniwm.l10n("CPU"), data.cpu),
            gauge(ctx, omniwm.l10n("GPU"), data.gpu),
            gauge(ctx, omniwm.l10n("Memory"), data.memory),
            gauge(ctx, omniwm.l10n("Disk"), data.disk) } } }
    local facts = { gap = 6 }
    local system = data.system
    if system then
        facts[#facts + 1] = ui.row{ w = INNER, gap = 10,
            ui.symbol{ name = "applelogo", w = 18, h = 18 },
            ui.column{ gap = 1, center = false,
                ui.text{ style = "caption", text = system.host.name, size = 13, weight = "semibold", maxWidth = INNER - 30 },
                ui.text{ style = "caption", text = system.host.chip .. " · " .. system.host.os, size = 11,
                    color = "secondaryForeground", maxWidth = INNER - 30 } } }
    end
    if data.network then
        facts[#facts + 1] = ui.row{ w = INNER, gap = 6,
            ui.symbol{ name = "arrow.down", w = 12, h = 12, color = "secondaryForeground" },
            ui.text{ style = "caption", text = ctx.format.bytes(data.network.down, "file") .. "/s", size = 11,
                reserve = "000.0 MB/s" },
            ui.box{ grow = 1 },
            ui.symbol{ name = "arrow.up", w = 12, h = 12, color = "secondaryForeground" },
            ui.text{ style = "caption", text = ctx.format.bytes(data.network.up, "file") .. "/s", size = 11,
                reserve = "000.0 MB/s" } }
    end
    if #facts > 0 then
        rows[#rows + 1] = card(facts)
    end
    return ui.column(rows)
end

local function connection(name: string, text: string, glyph, command: string)
    return style.group{ w = (CONTENT - 12) / 2, gap = 6, hover = HOVER, onClick = command,
        ui.row{ gap = 6,
            glyph,
            ui.text{ style = "caption", text = name, size = 13, weight = "semibold" } },
        ui.text{ style = "caption", text = text, size = 11, color = "secondaryForeground", maxWidth = (CONTENT - 12) / 2 - 24 } }
end

local function overview(ctx)
    local wifi = ctx.data.wifi
    local bluetooth = ctx.data.bluetooth
    local wireless = if not wifi then omniwm.l10n("Unavailable") elseif not wifi.power then omniwm.l10n("Off")
        elseif wifi.ssid then wifi.ssid elseif wifi.connected then omniwm.l10n("Connected")
        else omniwm.l10n("Not Connected")
    local connected = 0
    for _, device in if bluetooth then bluetooth.devices or {} else {} do
        if device.connected then
            connected += 1
        end
    end
    local bluetoothState = if not bluetooth then omniwm.l10n("Unavailable")
        elseif bluetooth.access ~= "granted" then omniwm.l10n("Allow Access")
        elseif not bluetooth.power then omniwm.l10n("Off")
        elseif connected > 0 then tostring(connected) .. " · " .. omniwm.l10n("Connected") else omniwm.l10n("On")
    local rows = { w = CONTENT, gap = 12, center = false,
        ui.row{ gap = 12,
            connection(omniwm.l10n("Wi-Fi"), wireless,
                ui.symbol{ name = if wifi and wifi.power then "wifi" else "wifi.slash", w = 16, h = 16,
                    color = if wifi and wifi.connected then "accent" else "secondaryForeground" }, "wifi settings"),
            connection(omniwm.l10n("Bluetooth"), bluetoothState,
                ui.path{ w = 16, h = 16, viewBox = { 0, 0, 24, 24 },
                    d = "M7 7.5 L17 16.5 L12 21 L12 3 L17 7.5 L7 16.5", borderWidth = 2.2,
                    border = if bluetooth and bluetooth.power then "accent" else "secondaryForeground" },
                if bluetooth and bluetooth.access ~= "granted" then "bluetooth authorize" else "bluetooth settings") },
        audio.level(ctx),
        media.content(ctx, true) }
    local level = ctx.data.battery
    if level then
        local power = ctx.data.power or {}
        rows[#rows + 1] = card{ hover = HOVER, onClick = "battery settings",
            ui.row{ w = INNER, gap = 8,
                ui.symbol{ name = style.batterySymbol(level, ctx.data.charging),
                    w = 22, h = 16 },
                ui.text{ style = "caption", text = omniwm.l10n("Battery"), size = 13, grow = 1 },
                ui.text{ style = "caption", text = ctx.format.percent(level / 100), size = 13 },
                ui.symbol{ name = "chevron.right", w = 10, h = 10, color = "secondaryForeground" } },
            ui.text{ style = "caption", text = if power.charged then omniwm.l10n("Fully charged")
                elseif ctx.data.charging then omniwm.l10n("Charging")
                elseif power.source == "ac" then omniwm.l10n("Power Adapter") else omniwm.l10n("On battery"),
                size = 11, color = "secondaryForeground" } }
    end
    return ui.column(rows)
end

local SECTIONS = {
    overview = overview, audio = audio.content, media = media.content, calendar = calendarTab,
    weather = weatherTab, system = systemTab,
}

local function selected(ctx): string
    local tab = ctx.state.tab or (ctx.data.settings or {}).tab
    return if SECTIONS[tab] then tab else "overview"
end

function render(ctx: Context)
    local scale = style.scale(ctx)
    local item = { onClick = ui.popout, help = omniwm.l10n("Control Center"),
        ui.symbol{ name = "slider.horizontal.3", size = 14 * scale, color = "accent" } }
    if not ctx.data.bar.style.vertical then
        item[#item + 1] = ui.text{ style = "caption", text = "SYS", size = 12 * scale, color = "accent" }
    end
    return style.bar(ctx, item)
end

function popout(ctx: Context)
    local current = selected(ctx)
    local tabs = { w = CONTENT, gap = 4 }
    local title = omniwm.l10n("Control Center")
    for _, tab in TABS do
        local active = tab.id == current
        if active then
            title = tab.label
        end
        tabs[#tabs + 1] = style.button(tab.symbol, function(state)
            state.state.tab = tab.id
        end, { w = (CONTENT - 20) / 6, h = 30, help = tab.label,
            fill = if active then "foreground/0.10" else nil })
    end
    return style.panel{ w = CONTENT + 28,
        ui.row{ w = CONTENT,
            ui.text{ style = "caption", text = "matrix://", size = 11, color = "secondaryForeground", grow = 1 },
            style.button("xmark", ui.popout, { help = omniwm.l10n("Close") }) },
        style.heading(title),
        ui.row(tabs),
        SECTIONS[current](ctx) }
end
