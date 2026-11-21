-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local look = require("./look")
local actions = require("./actions")

local wifi = { settings = "wifi settings" }
local SPREAD = math.rad(45)
local BANDS = { { 0, 2.8 }, { 5.2, 7.8 }, { 10, 12.6 }, { 14.8, 17.4 } }
local SCROLL_AFTER = 7
local LIST_HEIGHT = 360
wifi.bandCount = #BANDS

local function bars(rssi: number?): number
    if not rssi then
        return 0
    end
    if rssi >= -60 then
        return 3
    end
    if rssi >= -70 then
        return 2
    end
    return if rssi >= -80 then 1 else 0
end

local function quality(rssi: number): string
    if rssi >= -60 then
        return omniwm.l10n("Excellent")
    end
    if rssi >= -70 then
        return omniwm.l10n("Good")
    end
    return if rssi >= -80 then omniwm.l10n("Fair") else omniwm.l10n("Weak")
end

local function sector(inner: number, outer: number): string
    local x, y = math.sin(SPREAD), math.cos(SPREAD)
    return string.format("M%.2f %.2f A%.2f %.2f 0 0 1 %.2f %.2f L%.2f %.2f A%.2f %.2f 0 0 0 %.2f %.2f Z",
        12 - outer * x, 20.5 - outer * y, outer, outer, 12 + outer * x, 20.5 - outer * y,
        12 + inner * x, 20.5 - inner * y, inner, inner, 12 - inner * x, 20.5 - inner * y)
end

function wifi.fan(level: number, size: number, color: string, dim: string?)
    local stack = { w = size, h = size }
    for index, band in BANDS do
        stack[#stack + 1] = ui.path{ w = size, h = size, viewBox = { 0, 0, 24, 24 }, d = sector(band[1], band[2]),
            fill = if index - 1 <= level then color else dim or "foreground/0.2" }
    end
    return ui.stack(stack)
end

function wifi.state(ctx)
    local data = ctx.data.wifi
    local connection = ctx.data.connection
    local wired = connection ~= nil and connection.kind == "ethernet"
    if not data then
        return if wired then { wired = true, available = false, power = false, connected = false, level = -1,
            help = omniwm.l10n("Ethernet") } else nil
    end
    return { wired = wired, available = true, power = data.power, connected = data.connected, ssid = data.ssid,
        rssi = data.rssi, level = if data.connected then bars(data.rssi) else -1,
        help = if wired then omniwm.l10n("Ethernet")
            elseif not data.power then omniwm.l10n("Wi-Fi: Off")
            elseif data.ssid then data.ssid
            elseif data.connected then omniwm.l10n("Wi-Fi: Connected")
            else omniwm.l10n("Wi-Fi: Not Connected") }
end

function wifi.glyph(state, size: number)
    if state.wired then
        return look.glyph{ name = "network", size = size, weight = look.barWeight }
    end
    if not state.power then
        return look.glyph{ name = "wifi.slash", size = size, weight = look.barWeight, color = "secondaryForeground" }
    end
    return wifi.fan(state.level, size, "foreground")
end

function wifi.model(ctx)
    local m = wifi.state(ctx)
    if not m then
        return nil
    end
    local data = ctx.data.wifi
    m.details = {}
    m.actions = {}
    if not data then
        local unavailable = omniwm.l10n("Unavailable")
        m.status, m.connectionStatus, m.name = unavailable, unavailable, unavailable
    else
        m.status = if data.power then omniwm.l10n("On") else omniwm.l10n("Off")
        m.connectionStatus = if not data.power then omniwm.l10n("Off")
            elseif data.connected then omniwm.l10n("Connected") else omniwm.l10n("Not Connected")
        m.name = data.ssid or omniwm.l10n("Network name hidden")
        if data.power and data.connected then
            if data.rssi then
                m.details[#m.details + 1] = { symbol = "cellularbars", label = omniwm.l10n("Signal"),
                    value = string.format("%d dBm · %s", data.rssi, quality(data.rssi)) }
            end
            if data.band then
                m.details[#m.details + 1] = { symbol = "antenna.radiowaves.left.and.right",
                    label = omniwm.l10n("Band"),
                    value = if data.channel then string.format("%s · %d", data.band, data.channel) else data.band }
            end
            if data.security then
                m.details[#m.details + 1] = { symbol = "lock", label = omniwm.l10n("Security"), value = data.security }
            end
        end
        if data.power and data.location ~= "authorized" then
            m.actions[#m.actions + 1] = { symbol = "location.fill",
                text = omniwm.l10n("Allow Location Access to show the network name"), command = "wifi authorize",
                wrap = true, prompt = true }
        end
    end
    m.actions[#m.actions + 1] = { symbol = "gearshape", text = omniwm.l10n("Wi-Fi Settings…"), command = wifi.settings,
        wrap = true }
    return m
end

local function detail(entry, width: number)
    return ui.row{ w = width - 24, gap = 8,
        look.glyph{ name = entry.symbol, w = 16, h = 16, color = "secondaryForeground" },
        look.text{ text = entry.label, size = 13, color = "secondaryForeground", grow = 1, maxWidth = 88 },
        look.text{ text = entry.value, size = 12, maxWidth = width - 152 } }
end

local function header(text: string, width: number, trailing)
    local row = { w = width - 24,
        look.text{ text = text, size = 11, weight = "medium", color = "secondaryForeground", grow = 1 } }
    row[#row + 1] = trailing
    return ui.row(row)
end

local function network(entry, data, width: number)
    local failed = data.failure ~= nil and data.failure.id == entry.id
    local status = if data.joining == entry.id then omniwm.l10n("Joining…")
        elseif failed then data.failure.message
        elseif entry.opensSettings then omniwm.l10n("Opens Wi-Fi Settings")
        else entry.security
    local labels = { gap = 2, center = false, grow = 1,
        look.text{ text = entry.ssid, size = 13, maxWidth = width - 96 } }
    if status then
        labels[#labels + 1] = look.text{ text = status, size = 11, maxWidth = width - 96, lines = 2,
            color = if failed then "error" else "secondaryForeground" }
    end
    local row = { w = width - 24, gap = 8, pad = 4, radius = look.radius(8), hover = look.hover,
        onClick = if data.joining then nil else "wifi join " .. entry.id,
        wifi.fan(bars(entry.rssi), 18, "foreground"), ui.column(labels) }
    if entry.secured then
        row[#row + 1] = look.glyph{ name = "lock.fill", w = 12, h = 12, color = "secondaryForeground" }
    end
    return ui.row(row)
end

local function listed(data, id: string?)
    for _, list in { data.known, data.other } do
        for _, entry in list do
            if entry.id == id then
                return entry
            end
        end
    end
    return nil
end

function wifi.networkSections(ctx, width: number)
    local status = ctx.data.wifi
    if not status or not status.power or status.location ~= "authorized" then
        return {}
    end
    local data = ctx.data.wifiNetworks
    if not data then
        return {}
    end
    local lists = { w = width, gap = 12, center = false }
    if #data.known > 0 then
        local group = { w = width, header(omniwm.l10n("Known Networks"), width) }
        for _, entry in data.known do
            group[#group + 1] = network(entry, data, width)
        end
        lists[#lists + 1] = look.group(group)
    end
    local refresh = if data.scanning
        then look.text{ text = omniwm.l10n("Scanning…"), size = 11, color = "secondaryForeground" }
        else ui.row{ pad = 2, radius = look.radius(6), hover = look.hover, onClick = "wifi scan",
            help = omniwm.l10n("Scan for Networks"),
            look.glyph{ name = "arrow.clockwise", w = 12, h = 12, color = "secondaryForeground" } }
    local group = { w = width, header(omniwm.l10n("Other Networks"), width, refresh) }
    for _, entry in data.other do
        group[#group + 1] = network(entry, data, width)
    end
    if #data.other == 0 and not data.scanning then
        group[#group + 1] = look.text{ text = omniwm.l10n("No Networks Found"), size = 13,
            color = "secondaryForeground" }
    end
    lists[#lists + 1] = look.group(group)
    if #data.known + #data.other > SCROLL_AFTER then
        lists.h = LIST_HEIGHT
        lists.scroll = true
    end
    local sections = { ui.column(lists) }
    local failure = data.failure
    if failure and not listed(data, failure.id) then
        sections[#sections + 1] = actions.notice(failure.message, width)
    end
    return sections, listed(data, data.joining)
end

function wifi.content(ctx, width: number?, m, sections: { any }?)
    width = width or look.width
    m = m or wifi.model(ctx)
    if not m then
        return actions.notice(omniwm.l10n("Unavailable"), width)
    end
    local rows = { w = width, gap = 12, center = false }
    if m.wired then
        rows[#rows + 1] = look.group{ w = width,
            ui.row{ w = width - 24, gap = 12,
                ui.stack{ w = 36, h = 36, radius = look.radius(18), fill = "accent",
                    look.glyph{ name = "network", size = 18, color = "accentForeground" } },
                ui.column{ gap = 3, center = false,
                    look.text{ text = omniwm.l10n("Ethernet"), size = 13, weight = "medium", maxWidth = width - 72 },
                    look.text{ text = omniwm.l10n("Connected"), size = 11, color = "secondaryForeground" } } } }
    end
    if m.available then
        rows[#rows + 1] = ui.row{ w = width,
            look.text{ text = omniwm.l10n("Wi-Fi"), size = 14, weight = "semibold", grow = 1 },
            look.text{ text = m.status, size = 13, color = "secondaryForeground" } }
    end
    if m.power and m.connected then
        local card = { w = width,
            ui.row{ w = width - 24, gap = 12,
                ui.stack{ w = 36, h = 36, radius = look.radius(18), fill = "accent", wifi.fan(m.level, 20, "accentForeground") },
                ui.column{ gap = 3, center = false,
                    look.text{ text = m.name, size = 13, weight = "medium", maxWidth = width - 72 },
                    look.text{ text = m.connectionStatus, size = 11, color = "secondaryForeground" } } } }
        for _, entry in m.details do
            card[#card + 1] = detail(entry, width)
        end
        rows[#rows + 1] = look.group(card)
    elseif m.power then
        rows[#rows + 1] = look.group{ w = width,
            look.text{ text = omniwm.l10n("Not Connected"), size = 13, color = "secondaryForeground" } }
    end
    for _, section in sections or {} do
        rows[#rows + 1] = section
    end
    for _, action in m.actions do
        rows[#rows + 1] = actions.row(action.symbol, action.text, action.command, width, action.wrap)
    end
    return ui.column(rows)
end

function wifi.bar(ctx)
    local state = wifi.state(ctx)
    if not state then
        return ui.box{ w = 0, h = 0 }
    end
    local behaviour = { onClick = ui.popout, help = state.help }
    local button = look.wifiBar and look.wifiBar(ctx, state)
    if not button then
        local props = table.clone(behaviour)
        props[1] = wifi.glyph(state, look.px(ctx, "barSymbol"))
        button = look.bar(ctx, props)
    end
    for key, value in behaviour do
        button[key] = value
    end
    return button
end

function wifi.popout(ctx)
    local m = wifi.model(ctx)
    return look.wifiPanel and look.wifiPanel(ctx, m)
        or look.panel(ctx, { w = look.width + 28, wifi.content(ctx, nil, m) })
end

function wifi.networksPopout(ctx)
    local width = look.width
    local m = wifi.model(ctx)
    local sections, joining
    if m then
        sections, joining = wifi.networkSections(ctx, width)
    end
    if joining then
        m.connected, m.name, m.level, m.details = true, joining.ssid, -1, {}
        m.connectionStatus = omniwm.l10n("Joining…")
    end
    return look.panel(ctx, { w = width + 28, wifi.content(ctx, width, m, sections) })
end

return table.freeze(wifi)
