-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local HOVER = "foreground/0.12"
local WIDTH = 340
local CONTENT = WIDTH - 24
local INNER = CONTENT - 20
local CELL = INNER // 7
local RING = "M12 2.5 A9.5 9.5 0 1 1 12 21.5 A9.5 9.5 0 1 1 12 2.5"
local TRANSPORT_SYMBOLS = {
    builtin = "laptopcomputer",
    usb = "cable.connector",
    bluetooth = "headphones",
    hdmi = "display",
    displayport = "display",
    airplay = "airplayaudio",
    thunderbolt = "bolt.horizontal",
}
local TABS = {
    { id = "audio", symbol = "speaker.wave.2.fill", label = omniwm.l10n("Audio") },
    { id = "media", symbol = "music.note", label = omniwm.l10n("Media") },
    { id = "calendar", symbol = "calendar", label = omniwm.l10n("Calendar") },
    { id = "weather", symbol = "cloud.sun.fill", label = omniwm.l10n("Weather") },
    { id = "system", symbol = "gauge.with.needle", label = omniwm.l10n("System") },
}

local function button(name: string, command: string, size: number?)
    return ui.box{ pad = 5, radius = 8, hover = HOVER, onClick = command,
        ui.symbol{ name = name, w = size or 14, h = size or 14 } }
end

local function card(props)
    props.w = CONTENT
    props.pad = 10
    props.radius = 12
    props.fill = "surface"
    props.gap = props.gap or 6
    props.center = false
    return ui.column(props)
end

local function caption(text: string)
    return ui.text{ text = text, size = 11, weight = "semibold", color = "secondaryForeground", maxWidth = INNER }
end

local function speaker(volume: number, muted: boolean?): string
    if muted or volume == 0 then
        return "speaker.slash.fill"
    end
    return if volume < 34 then "speaker.wave.1.fill" elseif volume < 67 then "speaker.wave.2.fill"
        else "speaker.wave.3.fill"
end

local function audio(ctx)
    local data = ctx.data
    local volume = data.volume
    local rows = { gap = 8, center = false }
    if volume then
        rows[#rows + 1] = card{
            ui.row{ w = INNER, gap = 8,
                ui.symbol{ name = speaker(volume, data.muted), w = 18, h = 18, color = "accent" },
                ui.slider{ value = volume / 100, w = INNER - 110, h = 16,
                    color = if data.muted then "mutedForeground" else "accent",
                    onChange = function(_, event)
                        if event.value then
                            omniwm.run(string.format("volume set %d", math.round(event.value * 100)))
                        end
                    end },
                ui.text{ text = ctx.format.percent(volume / 100), style = "mono", reserve = ctx.format.percent(1) },
                button(if data.muted then "speaker.wave.2" else "speaker.slash", "volume mute") } }
    end
    local outputs = { gap = 2, caption(omniwm.l10n("Output")) }
    for _, device in data.outputs or {} do
        outputs[#outputs + 1] = ui.row{ w = INNER, gap = 8, pad = 4, radius = 8, hover = HOVER,
            onClick = "volume output " .. device.id,
            ui.symbol{ name = TRANSPORT_SYMBOLS[device.transport] or "hifispeaker.fill", w = 16, h = 16,
                color = if device.default then "accent" else "secondaryForeground" },
            ui.text{ text = device.name, grow = 1, maxWidth = INNER - 60,
                weight = if device.default then "semibold" else nil },
            ui.symbol{ name = "checkmark", w = 12, h = 12, color = "accent", opacity = if device.default then 1 else 0 } }
    end
    rows[#rows + 1] = card(outputs)
    local apps = data.audioApps
    if apps and apps.access == "denied" then
        rows[#rows + 1] = ui.row{ w = CONTENT, gap = 6, pad = 6, radius = 8, hover = HOVER, onClick = "volume permission",
            ui.symbol{ name = "lock.fill", w = 14, h = 14 },
            ui.text{ text = omniwm.l10n("Allow System Audio Recording to set app volumes"), maxWidth = CONTENT - 30,
                lines = 2 } }
    end
    local mixer = { gap = 4, caption(omniwm.l10n("Applications")) }
    for _, entry in if apps then apps.apps else {} do
        if entry.playing or entry.muted or entry.volume < 100 then
            mixer[#mixer + 1] = ui.row{ w = INNER, gap = 8,
                ui.icon{ app = entry.id, w = 18, h = 18, opacity = if entry.playing then 1 else 0.6 },
                ui.text{ text = entry.name, w = 80, maxWidth = 80 },
                ui.slider{ value = entry.volume / 100, w = INNER - 140, h = 14,
                    color = if entry.muted then "mutedForeground" else "accent",
                    onChange = function(_, event)
                        if event.value then
                            omniwm.run(string.format("volume app %s set %d", entry.id, math.round(event.value * 100)))
                        end
                    end },
                button(if entry.muted then "speaker.slash.fill" else "speaker.wave.2.fill",
                    "volume app " .. entry.id .. " mute", 12) }
        end
    end
    if #mixer > 1 then
        rows[#rows + 1] = card(mixer)
    end
    return ui.column(rows)
end

local function clock(seconds: number): string
    local whole = math.max(0, math.floor(seconds))
    return string.format("%d:%02d", whole // 60, whole % 60)
end

local function media(ctx)
    local playing = ctx.data.media
    if not playing or playing.title == "" then
        return card{ ui.text{ text = omniwm.l10n("Nothing is playing"), color = "secondaryForeground" } }
    end
    local cover = if playing.artwork
        then ui.image{ image = playing.artwork, w = 76, h = 76, radius = 10 }
        else ui.box{ w = 76, h = 76, radius = 10, fill = "foreground/0.08", center = true,
            ui.icon{ app = playing.bundle, w = 40, h = 40, placeholder = "music.note" } }
    local rows = { gap = 10,
        ui.row{ w = INNER, gap = 12,
            cover,
            ui.column{ gap = 2, center = false,
                ui.text{ text = playing.title, style = "bold", maxWidth = INNER - 90 },
                ui.text{ text = playing.artist, color = "secondaryForeground", maxWidth = INNER - 90 },
                ui.text{ text = playing.album, style = "small", color = "mutedForeground", maxWidth = INNER - 90 } } } }
    if playing.duration and playing.elapsed and playing.duration > 0 then
        local duration = playing.duration
        local elapsed = playing.elapsed
        if playing.playing then
            elapsed += (ctx.data.seconds - playing.sampledAt) * playing.rate
        end
        elapsed = math.clamp(elapsed, 0, duration)
        rows[#rows + 1] = ui.column{ gap = 3,
            ui.slider{ value = elapsed / duration, w = INNER, h = 12, onChange = function(_, event)
                if event.value and event.phase == "ended" then
                    omniwm.run(string.format("media seek %.1f", event.value * duration))
                end
            end },
            ui.row{ w = INNER,
                ui.text{ text = clock(elapsed), style = "small", color = "secondaryForeground" },
                ui.box{ grow = 1 },
                ui.text{ text = clock(duration), style = "small", color = "secondaryForeground" } } }
    end
    rows[#rows + 1] = ui.row{ w = INNER, gap = 10,
        ui.box{ grow = 1 },
        button("backward.fill", "media previous", 16),
        ui.stack{ w = 40, h = 40, radius = 20, fill = "accent", hover = "accentForeground/0.15",
            onClick = "media toggle",
            ui.symbol{ name = if playing.playing then "pause.fill" else "play.fill", w = 18, h = 18,
                color = "accentForeground" } },
        button("forward.fill", "media next", 16),
        ui.box{ grow = 1 },
        button("arrow.up.forward.app", "media open") }
    return card(rows)
end

local function month(calendar)
    local data = calendar.month
    local marked = {}
    for _, day in data.marked do
        marked[day] = true
    end
    local rows = { gap = 0,
        ui.row{ w = INNER, gap = 4,
            ui.text{ text = data.title, style = "bold", grow = 1 },
            button("chevron.left", "calendar month previous", 11),
            button("circle.fill", "calendar month today", 8),
            button("chevron.right", "calendar month next", 11) } }
    local header = { gap = 0 }
    for _, symbol in data.weekdays do
        header[#header + 1] = ui.stack{ w = CELL, h = 20,
            ui.text{ text = symbol, style = "small", color = "secondaryForeground" } }
    end
    rows[#rows + 1] = ui.row(header)
    local week = { gap = 0 }
    for _ = 1, data.offset do
        week[#week + 1] = ui.box{ w = CELL, h = 26 }
    end
    for day = 1, data.days do
        local today = day == data.today
        week[#week + 1] = ui.stack{ w = CELL, h = 26,
            ui.stack{ w = 26, h = 24, radius = 12, fill = if today then "accent" else nil,
                ui.text{ text = tostring(day), style = if today then "bold" else "body",
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
        return card{ ui.text{ text = omniwm.l10n("Unavailable"), color = "secondaryForeground" } }
    end
    local rows = { gap = 8, center = false, month(calendar) }
    if calendar.access == "full" then
        local agenda = { gap = 2 }
        for _, event in calendar.events do
            if event["end"] > ctx.data.seconds and #agenda < 3 then
                agenda[#agenda + 1] = ui.row{ w = INNER, gap = 8, pad = 3, radius = 8, hover = HOVER,
                    onClick = "calendar open " .. event.id,
                    ui.box{ w = 3, h = 28, radius = 1.5, fill = event.color },
                    ui.column{ gap = 1, center = false,
                        ui.text{ text = event.title, maxWidth = INNER - 20 },
                        ui.text{ text = event.day .. " · " .. (if event.allDay then omniwm.l10n("All day") else event.time),
                            style = "small", color = "secondaryForeground", maxWidth = INNER - 20 } } }
            end
        end
        if #agenda == 0 then
            agenda[#agenda + 1] = ui.text{ text = omniwm.l10n("No upcoming events"), color = "secondaryForeground" }
        end
        rows[#rows + 1] = card(agenda)
    elseif calendar.access == "notDetermined" then
        rows[#rows + 1] = ui.row{ w = CONTENT, gap = 6, pad = 6, radius = 8, hover = HOVER, onClick = "calendar authorize",
            ui.symbol{ name = "calendar.badge.plus", w = 14, h = 14 },
            ui.text{ text = omniwm.l10n("Allow Calendar Access") } }
    else
        rows[#rows + 1] = ui.row{ w = CONTENT, gap = 6, pad = 6, radius = 8, hover = HOVER, onClick = "calendar settings",
            ui.symbol{ name = "lock.fill", w = 14, h = 14 },
            ui.text{ text = omniwm.l10n("Open Calendar Privacy Settings"), maxWidth = CONTENT - 30, lines = 2 } }
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
        return card{ ui.text{ text = omniwm.l10n("Unavailable"), color = "secondaryForeground" } }
    end
    local now = { gap = 1, center = false,
        ui.text{ text = degrees(weather.temp), style = "rounded", size = 30, weight = "semibold" },
        ui.text{ text = CONDITIONS[weather.condition] or weather.condition, maxWidth = 140 } }
    if weather.place then
        now[#now + 1] = ui.text{ text = weather.place, style = "small", color = "secondaryForeground", maxWidth = 140 }
    end
    local facts = { gap = 3, center = false }
    if weather.high and weather.low then
        facts[#facts + 1] = ui.text{ text = omniwm.l10n("High %@", degrees(weather.high)) .. "  "
            .. omniwm.l10n("Low %@", degrees(weather.low)), style = "small" }
    end
    if weather.feels then
        facts[#facts + 1] = ui.text{ text = omniwm.l10n("Feels like %@", degrees(weather.feels)), style = "small",
            color = "secondaryForeground" }
    end
    if weather.rain then
        facts[#facts + 1] = ui.text{ text = omniwm.l10n("%lld%% chance of rain", weather.rain), style = "small",
            color = "secondaryForeground" }
    end
    local hours = { gap = 0 }
    for index, hour in weather.hours do
        if index > 8 then
            break
        end
        hours[#hours + 1] = ui.column{ w = INNER / 8, gap = 4,
            ui.text{ text = hour.label, size = 10, color = "secondaryForeground" },
            ui.symbol{ name = hour.symbol, w = 16, h = 16 },
            ui.text{ text = degrees(hour.temp), style = "small" } }
    end
    local low, high = math.huge, -math.huge
    for _, day in weather.days do
        low = math.min(low, day.low)
        high = math.max(high, day.high)
    end
    local span = math.max(1, high - low)
    local track = INNER - 190
    local days = { gap = 5 }
    for index, day in weather.days do
        if index > 5 then
            break
        end
        days[#days + 1] = ui.row{ w = INNER, gap = 8,
            ui.text{ text = day.label, w = 50, maxWidth = 50 },
            ui.symbol{ name = day.symbol, w = 16, h = 16 },
            ui.text{ text = if day.rain and day.rain > 0 then ctx.format.percent(day.rain / 100) else "",
                style = "small", color = "cyan", w = 30 },
            ui.text{ text = degrees(day.low), color = "secondaryForeground", w = 28 },
            ui.stack{ w = track, h = 4, radius = 2, fill = "foreground/0.12",
                ui.box{ align = "leading", dx = (day.low - low) / span * track,
                    w = math.max(4, (day.high - day.low) / span * track), h = 4, radius = 2, fill = "accent" } },
            ui.text{ text = degrees(day.high), w = 28 } }
    end
    return ui.column{ gap = 8,
        card{ ui.row{ w = INNER, gap = 12,
            ui.symbol{ name = weather.symbol, w = 40, h = 40 },
            ui.column(now),
            ui.box{ grow = 1 },
            ui.column(facts) } },
        card{ ui.row(hours) },
        card(days) }
end

local function arc(fraction: number): string
    if fraction >= 0.999 then
        return RING
    end
    local angle = fraction * 2 * math.pi
    return string.format("M12 2.5 A9.5 9.5 0 %d 1 %.2f %.2f", if angle > math.pi then 1 else 0,
        12 + 9.5 * math.sin(angle), 12 - 9.5 * math.cos(angle))
end

local function gauge(ctx, label: string, value: number?, tint: string)
    local size = 54
    local ring = { w = size, h = size,
        ui.path{ w = size, h = size, viewBox = { 0, 0, 24, 24 }, d = RING, border = "foreground/0.14",
            borderWidth = 2.4 } }
    if value and value > 0.5 then
        ring[#ring + 1] = ui.path{ w = size, h = size, viewBox = { 0, 0, 24, 24 }, d = arc(value / 100),
            border = if value >= 90 then "warning" else tint, borderWidth = 2.4 }
    end
    ring[#ring + 1] = ui.text{ text = if value then ctx.format.percent(value / 100) else "—", style = "rounded",
        size = 12, weight = "semibold" }
    return ui.column{ w = INNER / 4, gap = 5,
        ui.stack(ring),
        ui.text{ text = label, size = 11, weight = "medium", color = "secondaryForeground" } }
end

local function systemTab(ctx)
    local data = ctx.data
    local rows = { gap = 8,
        card{ ui.row{ w = INNER, gap = 0,
            gauge(ctx, omniwm.l10n("CPU"), data.cpu, "accent"),
            gauge(ctx, omniwm.l10n("GPU"), data.gpu, "accent"),
            gauge(ctx, omniwm.l10n("Memory"), data.memory, "accent"),
            gauge(ctx, omniwm.l10n("Disk"), data.disk, "accent") } } }
    local facts = { gap = 6 }
    local system = data.system
    if system then
        facts[#facts + 1] = ui.row{ w = INNER, gap = 10,
            ui.symbol{ name = "applelogo", w = 18, h = 18 },
            ui.column{ gap = 1, center = false,
                ui.text{ text = system.host.name, weight = "semibold", maxWidth = INNER - 30 },
                ui.text{ text = system.host.chip .. " · " .. system.host.os, style = "small",
                    color = "secondaryForeground", maxWidth = INNER - 30 } } }
    end
    if data.network then
        facts[#facts + 1] = ui.row{ w = INNER, gap = 6,
            ui.symbol{ name = "arrow.down", w = 12, h = 12, color = "secondaryForeground" },
            ui.text{ text = ctx.format.bytes(data.network.down, "file") .. "/s", style = "mono", size = 11,
                reserve = "000.0 MB/s" },
            ui.box{ grow = 1 },
            ui.symbol{ name = "arrow.up", w = 12, h = 12, color = "secondaryForeground" },
            ui.text{ text = ctx.format.bytes(data.network.up, "file") .. "/s", style = "mono", size = 11,
                reserve = "000.0 MB/s" } }
    end
    if #facts > 0 then
        rows[#rows + 1] = card(facts)
    end
    return ui.column(rows)
end

local SECTIONS = { audio = audio, media = media, calendar = calendarTab, weather = weatherTab, system = systemTab }

local function selected(ctx): string
    local tab = ctx.state.tab or (ctx.data.settings or {}).tab
    return if SECTIONS[tab] then tab else "audio"
end

function render(ctx: Context)
    local style = ctx.data.bar.style
    local size = math.max(16, style.height - 4)
    local capsule = style.transparent and style.backgrounds
    return ui.stack{ w = size, h = size, radius = if capsule then size / 2 else 4,
        fill = if capsule then "surface" else nil, border = if capsule then "border" else nil, borderWidth = 0.5,
        hover = HOVER, onClick = ui.popout, help = omniwm.l10n("Control Center"),
        ui.symbol{ name = "switch.2", size = math.max(11, size * 0.46), weight = "semibold",
            color = if capsule then "accent" else "foreground" } }
end

function popout(ctx: Context)
    local style = ctx.data.bar.style
    local current = selected(ctx)
    local tabs = { w = CONTENT, gap = 4 }
    for _, tab in TABS do
        local active = tab.id == current
        tabs[#tabs + 1] = ui.column{ w = (CONTENT - 16) / 5, h = 46, gap = 4, radius = 10,
            fill = if active then "accent/0.16" else nil, hover = HOVER,
            onClick = function(state)
                state.state.tab = tab.id
            end,
            ui.symbol{ name = tab.symbol, w = 16, h = 16, color = if active then "accent" else "secondaryForeground" },
            ui.text{ text = tab.label, size = 10, weight = if active then "semibold" else "medium",
                color = if active then "accent" else "secondaryForeground", maxWidth = (CONTENT - 20) / 5 } }
    end
    local root = { w = WIDTH, pad = 12, gap = 10, center = false,
        ui.row(tabs),
        SECTIONS[current](ctx) }
    if style.transparent and style.backgrounds then
        root.material = "clear"
        root.attach = true
        root.fill = "background"
        root.border = "border"
        root.borderWidth = 1
        root.radius = 16
    end
    return ui.column(root)
end
