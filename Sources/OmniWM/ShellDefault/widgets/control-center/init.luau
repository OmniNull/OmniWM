-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("../lib/look")
local audio = require("../lib/audio")
local media = require("../lib/media")
local calendar = require("../lib/calendar")
local weather = require("../lib/weather")
local wifi = require("../lib/wifi")
local bluetooth = require("../lib/bluetooth")
local battery = require("../lib/battery")
local stats = require("../lib/stats")

local CONTENT = look.panelWidth("control-center")
local INNER = CONTENT - 24
local TABS = {
    { id = "overview", symbol = "square.grid.2x2", label = omniwm.l10n("Control Center") },
    { id = "audio", symbol = "speaker.wave.2.fill", label = omniwm.l10n("Audio") },
    { id = "displays", symbol = "display", label = omniwm.l10n("Displays") },
    { id = "media", symbol = "music.note", label = omniwm.l10n("Media") },
    { id = "calendar", symbol = "calendar", label = omniwm.l10n("Calendar") },
    { id = "weather", symbol = "cloud.sun.fill", label = omniwm.l10n("Weather") },
    { id = "system", symbol = "gauge.with.needle", label = omniwm.l10n("System") },
}
local GAUGES = {
    { key = "cpu", label = omniwm.l10n("CPU") },
    { key = "gpu", label = omniwm.l10n("GPU") },
    { key = "memory", label = omniwm.l10n("Memory") },
    { key = "disk", label = omniwm.l10n("Disk") },
}

local function card(props)
    props.w = CONTENT
    return look.group(props)
end

local function brightnessSlider(ctx, display)
    local id = display.id or "main"
    local drag = ctx.state.brightnessDrag
    local level = if drag and drag.id == id then drag.level else display.value / 100
    local command = if display.id then "brightness display " .. display.id else "brightness"
    return ui.row{ w = INNER, gap = 8,
        look.glyph{ name = "sun.max", w = 18, h = 18 },
        ui.slider{ key = "display-brightness-" .. id, value = level, w = INNER - 76, h = 16,
            color = "accent", help = display.name, onChange = function(owner, event)
                local value = event.value and math.clamp(event.value, 0, 1)
                if event.phase == "ended" or event.phase == "cancelled" then
                    owner.state.brightnessDrag = nil
                    if event.phase == "ended" and value then
                        omniwm.run(string.format("%s set %d", command, math.round(value * 100)))
                    end
                elseif value then
                    owner.state.brightnessDrag = { id = id, level = value }
                end
            end },
        look.text{ text = ctx.format.percent(level), size = 12, w = 42, reserve = ctx.format.percent(1) } }
end

local function brightnessCard(ctx, unavailable: string)
    local brightness = ctx.data.brightness
    local displays = brightness and brightness.displays or {}
    if brightness and brightness.available and not brightness.mainDisplayId then
        displays = table.clone(displays)
        table.insert(displays, 1, { name = omniwm.l10n("Main Display"), value = brightness.value, available = true })
    end
    local rows = { w = INNER, gap = 8, center = false }
    for _, display in displays do
        local control = if display.available then brightnessSlider(ctx, display) else
            look.text{ text = unavailable, size = 13, color = "secondaryForeground" }
        rows[#rows + 1] = ui.column{ w = INNER, gap = 4, center = false,
            look.text{ text = display.name, size = 13, maxWidth = INNER }, control }
    end
    if #displays == 0 then
        rows[#rows + 1] = look.text{ text = unavailable, size = 13, color = "secondaryForeground" }
    elseif #displays > 5 then
        rows.h = 240
        rows.scroll = true
    end
    return card{ look.heading(omniwm.l10n("Brightness")), ui.column(rows) }
end

local function displaysTab(ctx)
    local unavailable = omniwm.l10n("Unavailable")
    local nightShift = ctx.data.nightShift
    local available = nightShift and nightShift.available
    local enabled = available and nightShift.enabled
    local nightShiftStatus = if not available then unavailable elseif enabled then omniwm.l10n("On") else omniwm.l10n("Off")
    return ui.column{ w = CONTENT, gap = 8, center = false,
        brightnessCard(ctx, unavailable),
        card{ hover = if available then look.hover else nil,
            onClick = if not available then nil elseif enabled then "night-shift off" else "night-shift on",
            ui.row{ w = INNER, gap = 8,
                look.glyph{ name = "sun.horizon", w = 22, h = 16,
                    color = if enabled then "accent" else "secondaryForeground" },
                look.text{ text = omniwm.l10n("Night Shift"), size = 13, grow = 1 },
                look.text{ text = nightShiftStatus, size = 13, color = "secondaryForeground" } } },
        card{ hover = look.hover, onClick = "brightness settings",
            ui.row{ w = INNER, gap = 8,
                look.glyph{ name = "display", w = 22, h = 16 },
                look.text{ text = omniwm.l10n("Displays Settings…"), size = 13, grow = 1 },
                look.glyph{ name = "chevron.right", w = 10, h = 10, color = "secondaryForeground" } } } }
end

local function gauge(label: string, row)
    local width = (INNER - 36) / 4
    return ui.column{ w = width, gap = 6,
        look.text{ text = if row then row.text else "—", size = 17, weight = "medium" },
        ui.progress{ value = (row and row.value or 0) / 100, w = width, h = 4, radius = 2, fill = "foreground/0.08",
            color = if row and row.hot then "warning" else "accent" },
        look.text{ text = label, size = 11, color = "secondaryForeground" } }
end

local function systemTab(ctx)
    local rows = {}
    for _, row in stats.model(ctx).rows do
        rows[row.key] = row
    end
    local gauges = { w = INNER, gap = 12 }
    for _, entry in GAUGES do
        gauges[#gauges + 1] = gauge(entry.label, rows[entry.key])
    end
    local sections = { gap = 8, card{ ui.row(gauges) } }
    local facts = { gap = 6 }
    local system = ctx.data.system
    if system then
        facts[#facts + 1] = ui.row{ w = INNER, gap = 10,
            look.glyph{ name = "applelogo", w = 18, h = 18 },
            ui.column{ gap = 1, center = false,
                look.text{ text = system.host.name, size = 13, weight = "semibold", maxWidth = INNER - 30 },
                look.text{ text = system.host.chip .. " · " .. system.host.os, size = 11,
                    color = "secondaryForeground", maxWidth = INNER - 30 } } }
    end
    if rows.down then
        facts[#facts + 1] = ui.row{ w = INNER, gap = 6,
            look.glyph{ name = "arrow.down", w = 12, h = 12, color = "secondaryForeground" },
            look.text{ text = rows.down.text, style = "mono", size = 11, reserve = "000.0 MB/s" },
            ui.box{ grow = 1 },
            look.glyph{ name = "arrow.up", w = 12, h = 12, color = "secondaryForeground" },
            look.text{ text = rows.up.text, style = "mono", size = 11, reserve = "000.0 MB/s" } }
    end
    if #facts > 0 then
        sections[#sections + 1] = card(facts)
    end
    return ui.column(sections)
end

local function connection(name: string, text: string, glyph, command: string)
    local width = (CONTENT - 12) / 2
    return look.group{ w = width, gap = 6, hover = look.hover, onClick = command,
        ui.row{ gap = 6,
            glyph,
            look.text{ text = name, size = 13, weight = "semibold" } },
        look.text{ text = text, size = 11, color = "secondaryForeground", maxWidth = width - 24 } }
end

local function overview(ctx)
    local network = wifi.model(ctx)
    local radio = bluetooth.state(ctx)
    local wired = network ~= nil and network.wired
    local wireless = if not network then omniwm.l10n("Unavailable")
        elseif wired then omniwm.l10n("Connected")
        else network.power and network.ssid or network.connectionStatus
    local devices = if not radio then omniwm.l10n("Unavailable")
        elseif not radio.granted then omniwm.l10n("Allow Access")
        elseif not radio.power then omniwm.l10n("Off")
        elseif radio.connected > 0 then tostring(radio.connected) .. " · " .. omniwm.l10n("Connected")
        else omniwm.l10n("On")
    local rows = { w = CONTENT, gap = 12, center = false,
        ui.row{ gap = 12,
            connection(if wired then omniwm.l10n("Ethernet") else omniwm.l10n("Wi-Fi"), wireless,
                look.glyph{ name = if wired then "network" elseif network and network.power then "wifi" else "wifi.slash",
                    w = 16, h = 16,
                    color = if wired or network and network.connected then "accent" else "secondaryForeground" },
                wifi.settings),
            connection(omniwm.l10n("Bluetooth"), devices,
                bluetooth.rune(16, if radio and radio.power then "accent" else "secondaryForeground"),
                if radio and not radio.granted then "bluetooth authorize" else "bluetooth settings") },
        audio.level(ctx, CONTENT),
        media.content(ctx, true, CONTENT) }
    local dark = ctx.data.appearance == "dark"
    rows[#rows + 1] = ui.row{ w = CONTENT, gap = 6,
        look.group{ w = CONTENT - 42, hover = look.hover, onClick = "appearance toggle",
            ui.row{ w = INNER - 42, gap = 8,
                look.glyph{ name = if dark then "moon.fill" else "sun.max.fill", w = 22, h = 16,
                    color = if dark then "accent" else "secondaryForeground" },
                look.text{ text = omniwm.l10n("Dark Mode"), size = 13, grow = 1 },
                look.text{ text = if dark then omniwm.l10n("On") else omniwm.l10n("Off"), size = 13,
                    color = "secondaryForeground" } } },
        look.button("chevron.right", "appearance settings",
            { w = 36, h = 36, help = omniwm.l10n("Appearance Settings…") }) }
    local charge = battery.model(ctx)
    if charge then
        rows[#rows + 1] = card{ hover = look.hover, onClick = charge.settings,
            ui.row{ w = INNER, gap = 8,
                look.glyph{ name = charge.symbol, w = 22, h = 16 },
                look.text{ text = omniwm.l10n("Battery"), size = 13, grow = 1 },
                look.text{ text = charge.percent, size = 13 },
                look.glyph{ name = "chevron.right", w = 10, h = 10, color = "secondaryForeground" } },
            look.text{ text = charge.status, size = 11, color = "secondaryForeground" } }
    end
    return ui.column(rows)
end

local SECTIONS = {
    overview = overview,
    audio = function(ctx)
        return audio.content(ctx, CONTENT)
    end,
    displays = displaysTab,
    media = function(ctx)
        return media.content(ctx, false, CONTENT)
    end,
    calendar = function(ctx)
        return calendar.content(ctx, CONTENT)
    end,
    weather = function(ctx)
        return weather.content(ctx, true, CONTENT)
    end,
    system = systemTab,
}

local function selected(ctx): string
    local tab = ctx.state.tab or (ctx.data.settings or {}).tab
    return if SECTIONS[tab] then tab else "overview"
end

function render(ctx: Context)
    local state = { symbol = "switch.2" }
    local behaviour = { onClick = ui.popout, help = omniwm.l10n("Control Center") }
    local button = look.controlCenterBar and look.controlCenterBar(ctx, state)
    if not button then
        local props = table.clone(behaviour)
        props[1] = look.barGlyph(ctx, { name = state.symbol, size = 14 * look.scale(ctx) })
        button = look.bar(ctx, props)
    end
    for key, value in behaviour do
        button[key] = value
    end
    return button
end

function popout(ctx: Context)
    local current = selected(ctx)
    local tabs = { w = CONTENT, gap = 4 }
    local tabWidth = (CONTENT - tabs.gap * (#TABS - 1)) / #TABS
    local title = omniwm.l10n("Control Center")
    for _, tab in TABS do
        local active = tab.id == current
        if active then
            title = tab.label
        end
        tabs[#tabs + 1] = look.button(tab.symbol, function(state)
            state.state.tab = tab.id
        end, { w = tabWidth, h = 30, help = tab.label, fill = if active then "foreground/0.10" else nil })
    end
    local props = { w = CONTENT + 28, look.heading(title), ui.row(tabs), SECTIONS[current](ctx) }
    return look.controlCenterPanel and look.controlCenterPanel(ctx, props) or look.panel(ctx, props)
end
