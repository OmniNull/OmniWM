-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local wallpaper = {}

local GAP = 10
local COLUMNS = 3
local FEW = 6
local MANY = 12
local CYCLE = { 0, 15, 30, 60 }
local SCHEMES = {
    tonalSpot = function() return omniwm.l10n("Tonal Spot") end,
    content = function() return omniwm.l10n("Content") end,
    vibrant = function() return omniwm.l10n("Vibrant") end,
    expressive = function() return omniwm.l10n("Expressive") end,
    fidelity = function() return omniwm.l10n("Fidelity") end,
    fruitSalad = function() return omniwm.l10n("Fruit Salad") end,
    rainbow = function() return omniwm.l10n("Rainbow") end,
    neutral = function() return omniwm.l10n("Neutral") end,
    monochrome = function() return omniwm.l10n("Monochrome") end,
}

local ROLES = {
    fill = "surface", raised = "highestSurface", text = "foreground", secondary = "secondaryForeground",
    muted = "mutedForeground", border = "border", accent = "accent", accentText = "accentForeground",
    chip = "accentContainer", chipText = "accentContainerForeground", hover = "foreground/0.08",
    subtle = "foreground/0.08",
}

wallpaper.roles = ROLES

local function token(name: string): string
    return (string.gsub(name, ".", function(character)
        return string.format("%02x", string.byte(character))
    end))
end

local function schemeName(name: string): string
    local title = SCHEMES[name]
    return if title then title() else name
end

local function aspect(display): number
    if display.w and display.h and display.w > 0 and display.h > 0 then
        return display.w / display.h
    end
    return 16 / 9
end

function wallpaper.state(ctx)
    local data = ctx.data.wallpaper
    if not data or not data.enabled then
        return nil
    end
    return data
end

function wallpaper.mainDisplay(data)
    for _, display in data.displays do
        if display.main then
            return display
        end
    end
    return data.displays[1]
end

local function chosen(ctx, data)
    local wanted = ctx.state.wallpaperTab or (ctx.data.bar and ctx.data.bar.monitorId)
    for _, display in data.displays do
        if display.id == wanted then
            return display
        end
    end
    return wallpaper.mainDisplay(data)
end

local function pill(skin, props)
    local row = { key = props.key, h = 26, gap = 5, radius = 13, onClick = props.action, help = props.help,
        fill = props.fill or skin.subtle, hover = skin.hover, opacity = if props.action then 1 else 0.45,
        border = props.border, borderWidth = if props.border then 0.75 else nil,
        ui.box{ w = 4, h = 1 } }
    if props.symbol then
        row[#row + 1] = ui.symbol{ name = props.symbol, size = 11, weight = "semibold", color = props.color or skin.text }
    end
    row[#row + 1] = ui.text{ text = props.text, size = 12, weight = props.weight or "medium",
        color = props.color or skin.text, lines = 1 }
    row[#row + 1] = ui.box{ w = 6, h = 1 }
    return ui.row(row)
end

local function nextRotation(minutes: number): number
    for index, value in CYCLE do
        if value == minutes then
            return CYCLE[index % #CYCLE + 1]
        end
    end
    return 0
end

local function rotationText(ctx, data): string
    if data.rotation <= 0 then
        return omniwm.l10n("Rotation off")
    end
    local minutes = tostring(math.floor(data.rotation))
    local due = data.next and ctx.format.date(data.next, "HHmm")
    if due then
        return omniwm.l10n("Every %@ min, next %@", minutes, due)
    end
    return omniwm.l10n("Every %@ min", minutes)
end

local function header(ctx, data, skin, width: number)
    local on = data.rotation > 0
    local count = #data.displays
    local nextLabel = if count > 2 then omniwm.l10n("Next all") elseif count == 2 then omniwm.l10n("Next both")
        else omniwm.l10n("Next")
    return ui.row{ w = width, gap = 6,
        ui.text{ text = omniwm.l10n("Wallpaper"), size = 15, weight = "semibold", color = skin.text },
        ui.box{ grow = 1, h = 1 },
        pill(skin, { key = "rotation", symbol = "arrow.clockwise", text = rotationText(ctx, data),
            fill = if on then skin.chip else skin.fill, color = if on then skin.chipText else skin.secondary,
            border = if on then nil else skin.border,
            help = omniwm.l10n("Change how often the wallpaper changes: every 15, 30 or 60 minutes, or off"),
            action = function()
                omniwm.run("wallpaper rotation " .. tostring(nextRotation(data.rotation)))
            end }),
        pill(skin, { key = "next all", symbol = "forward.end.fill", text = nextLabel, fill = skin.accent,
            color = skin.accentText, weight = "semibold",
            help = omniwm.l10n("Show the next wallpaper on every display"),
            action = function() omniwm.run("wallpaper next all") end }) }
end

local function cards(ctx, data, selected, skin, width: number)
    local total = 0
    for _, display in data.displays do
        total += aspect(display)
    end
    local pad = 8
    local inner = width - GAP * (#data.displays - 1) - pad * 2 * #data.displays
    local height = math.floor(math.min(150, inner / math.max(total, 0.1)))
    local row = { w = width, gap = GAP }
    for _, display in data.displays do
        local w = math.floor(aspect(display) * height)
        local shown = if display.preview then ui.image{ image = display.preview, w = w, h = height, radius = 10 }
            else ui.stack{ w = w, h = height, radius = 10, fill = skin.raised,
                ui.symbol{ name = "photo", size = 18, color = skin.muted } }
        local isChosen = selected and selected.id == display.id
        row[#row + 1] = ui.column{ key = "card " .. display.id, w = w + pad * 2, pad = pad, gap = 7, radius = 16,
            fill = skin.fill, border = if isChosen then skin.accent else skin.border,
            borderWidth = if isChosen then 1.5 else 0.75,
            help = omniwm.l10n("Show the wallpapers for %@", display.name),
            onClick = function(next)
                next.state.wallpaperTab = display.id
                next.state.wallpaperPage = nil
            end,
            shown,
            ui.row{ w = w, gap = 6,
                ui.column{ gap = 1, grow = 1, center = false,
                    ui.text{ text = display.name, size = 12.5, weight = "semibold", color = skin.text,
                        maxWidth = math.max(1, w - 76), lines = 1 },
                    ui.text{ text = display.current or omniwm.l10n("Not from this folder"), size = 11,
                        color = skin.muted, maxWidth = math.max(1, w - 76), lines = 1 } },
                pill(skin, { key = "next " .. display.id, symbol = "forward.end.fill", text = omniwm.l10n("Next"),
                    help = omniwm.l10n("Show the next wallpaper on %@", display.name),
                    action = function() omniwm.run("wallpaper next " .. display.id) end }) } }
    end
    return ui.row(row)
end

local function palette(ctx, data, skin, width: number)
    local main = wallpaper.mainDisplay(data)
    local swatches = { gap = 4 }
    for _, role in { "accent", "secondaryAccent", "tertiaryAccent", "surface", "foreground" } do
        swatches[#swatches + 1] = ui.box{ w = 22, h = 22, radius = 7, fill = role, border = "foreground/0.14",
            borderWidth = 1 }
    end
    local caption = if data.palette and main then omniwm.l10n("Colors follow the wallpaper on %@", main.name)
        else omniwm.l10n("Pick a scheme to color OmniWM from the wallpaper")
    local strip = ui.row{ w = width, gap = 10, ui.row(swatches),
        ui.text{ text = caption, size = 11.5, color = skin.muted, maxWidth = width - 140, lines = 1 } }
    local dark = ctx.data.appearance == "dark"
    local chipRows = {}
    for _, scheme in data.schemes or {} do
        local on = data.palette and data.scheme == scheme.name
        local colors = if dark then scheme.dark else scheme.light
        local dots = { gap = 2 }
        for index = 1, math.min(3, #colors) do
            dots[#dots + 1] = ui.box{ w = 9, h = 9, radius = 4.5, fill = colors[index] }
        end
        local chips = chipRows[#chipRows]
        if not chips or #chips >= 5 then
            chips = { w = width, gap = 6, pad = 1 }
            chipRows[#chipRows + 1] = chips
        end
        chips[#chips + 1] = ui.row{ key = "scheme " .. scheme.name, h = 24, gap = 5, radius = 11,
            fill = if on then skin.chip else skin.subtle, hover = skin.hover,
            help = omniwm.l10n("Color OmniWM with the %@ scheme", schemeName(scheme.name)),
            onClick = function() omniwm.run("wallpaper scheme " .. scheme.name) end,
            ui.box{ w = 3, h = 1 }, ui.row(dots),
            ui.text{ text = schemeName(scheme.name), size = 11, weight = if on then "semibold" else "regular",
                color = if on then skin.chipText else skin.secondary },
            ui.box{ w = 5, h = 1 } }
    end
    local column = { w = width, gap = 6, center = false, strip }
    for _, chips in chipRows do
        column[#column + 1] = ui.row(chips)
    end
    return ui.column(column)
end

local function tabs(ctx, data, selected, skin, width: number)
    local row = { gap = 4, pad = 3, radius = 15, fill = skin.fill }
    for _, display in data.displays do
        local on = selected and selected.id == display.id
        row[#row + 1] = ui.row{ key = "tab " .. display.id, h = 26, radius = 13,
            fill = if on then skin.raised else nil, hover = skin.hover, help = display.folder,
            onClick = function(next)
                next.state.wallpaperTab = display.id
                next.state.wallpaperPage = nil
            end,
            ui.box{ w = 10, h = 1 },
            ui.text{ text = omniwm.l10n("%@ · %@", display.name, tostring(display.count)), size = 12,
                weight = if on then "semibold" else "regular", color = if on then skin.text else skin.secondary },
            ui.box{ w = 10, h = 1 } }
    end
    return ui.row{ w = width, pad = 1, ui.row(row), ui.box{ grow = 1, h = 1 } }
end

local function pageOf(ctx, display): (number, number, number)
    local per = if ctx.state.wallpaperAll then MANY else FEW
    local pages = math.max(1, math.ceil(#display.items / per))
    local page = ctx.state.wallpaperPage or (math.floor((display.offset or 0) / per) + 1)
    return math.clamp(page, 1, pages), pages, per
end

local function showPage(display, page: number, per: number)
    omniwm.run(string.format("wallpaper page %s %d %d", display.id, (page - 1) * per, per))
end

local function grid(ctx, display, skin, width: number)
    local page, _, per = pageOf(ctx, display)
    local tileW = math.floor((width - 8 * (COLUMNS - 1)) / COLUMNS)
    local tileH = math.floor(tileW / aspect(display))
    local lines = {}
    local first = (page - 1) * per + 1
    for index = first, math.min(#display.items, first + per - 1) do
        local item = display.items[index]
        local current = item.name == display.current
        local tile = { key = "tile " .. display.id .. " " .. item.name, w = tileW, h = tileH, radius = 10,
            fill = skin.raised, border = if current then skin.accent else nil, borderWidth = if current then 2 else nil,
            help = item.name, hoverScale = 1.02, hoverAnimate = 0.12,
            onClick = function() omniwm.run("wallpaper set " .. display.id .. " " .. token(item.name)) end }
        tile[#tile + 1] = if item.preview then ui.image{ image = item.preview, w = tileW, h = tileH, radius = 10 }
            else ui.text{ text = item.name, size = 10.5, color = skin.muted, maxWidth = tileW - 12, lines = 2 }
        if current then
            tile[#tile + 1] = ui.row{ align = "topLeading", dx = 5, dy = 5, h = 16, radius = 8, fill = skin.accent,
                ui.box{ w = 6, h = 1 },
                ui.text{ text = omniwm.l10n("Now"), size = 10, weight = "semibold", color = skin.accentText },
                ui.box{ w = 6, h = 1 } }
        end
        local line = lines[#lines]
        if not line or #line >= COLUMNS then
            line = { gap = 8 }
            lines[#lines + 1] = line
        end
        line[#line + 1] = ui.stack(tile)
    end
    local rows = { w = width, gap = 8, center = false }
    for _, line in lines do
        rows[#rows + 1] = ui.row(line)
    end
    if #display.items == 0 then
        rows[#rows + 1] = ui.text{ text = omniwm.l10n("No wallpapers in %@", display.folder), size = 12,
            color = skin.secondary, maxWidth = width, lines = 2 }
    end
    return ui.column(rows)
end

local function footer(ctx, display, skin, width: number)
    local page, pages, per = pageOf(ctx, display)
    local right = { gap = 6 }
    if ctx.state.wallpaperAll and pages > 1 then
        right[#right + 1] = pill(skin, { key = "previous page", symbol = "chevron.left", text = "",
            help = omniwm.l10n("Previous page"),
            action = function(next)
                next.state.wallpaperPage = math.max(1, page - 1)
                showPage(display, next.state.wallpaperPage, per)
            end })
        right[#right + 1] = ui.text{ text = page .. "/" .. pages, size = 11, style = "mono", color = skin.secondary }
        right[#right + 1] = pill(skin, { key = "next page", symbol = "chevron.right", text = "",
            help = omniwm.l10n("Next page"),
            action = function(next)
                next.state.wallpaperPage = math.min(pages, page + 1)
                showPage(display, next.state.wallpaperPage, per)
            end })
    end
    right[#right + 1] = pill(skin, { key = "show all",
        text = if ctx.state.wallpaperAll then omniwm.l10n("Show fewer") else omniwm.l10n("Show all"),
        color = skin.secondary, help = omniwm.l10n("Page through every wallpaper in the folder"),
        action = function(next)
            next.state.wallpaperAll = not next.state.wallpaperAll
            next.state.wallpaperPage = nil
            local nextPer = if next.state.wallpaperAll then MANY else FEW
            showPage(display, math.floor((display.offset or 0) / nextPer) + 1, nextPer)
        end })
    right[#right + 1] = pill(skin, { key = "change folder", symbol = "folder.badge.gearshape",
        text = omniwm.l10n("Change folder"), color = skin.secondary,
        help = omniwm.l10n("Choose the folder of wallpapers for %@", display.name),
        action = function() omniwm.run("wallpaper folder " .. display.id) end })
    right[#right + 1] = pill(skin, { key = "open folder", symbol = "folder", text = omniwm.l10n("Open folder"),
        color = skin.secondary, help = omniwm.l10n("Open %@ in Finder", display.folder),
        action = function() omniwm.run("wallpaper open " .. display.id) end })
    return ui.column{ w = width, gap = 8, center = false,
        ui.box{ w = width, h = 1, fill = skin.border },
        ui.row{ w = width, gap = 6,
            ui.text{ text = display.folder, size = 12, color = skin.muted, maxWidth = math.max(1, width - 380), lines = 1 },
            ui.box{ grow = 1, h = 1 },
            ui.row(right) } }
end

function wallpaper.off(ctx, skin, width: number)
    local message = if ctx.data.wallpaper then omniwm.l10n("Wallpaper management is off.")
        else omniwm.l10n("Wallpaper data is unavailable.")
    return ui.column{ w = width, gap = 10, center = false,
        ui.text{ text = omniwm.l10n("Wallpaper"), size = 15, weight = "semibold", color = skin.text },
        ui.text{ text = message, size = 12, color = skin.secondary, maxWidth = width, lines = 3 },
        pill(skin, { key = "settings", symbol = "gearshape", text = omniwm.l10n("Wallpaper Settings…"),
            help = omniwm.l10n("Turn on wallpaper management and choose folders in OmniWM Settings"),
            action = function() omniwm.run("wallpaper settings") end }) }
end

function wallpaper.panel(ctx, skin, width: number)
    local data = wallpaper.state(ctx)
    if not data then
        return wallpaper.off(ctx, skin, width)
    end
    local items = { w = width, gap = 12, center = false, header(ctx, data, skin, width) }
    local selected = chosen(ctx, data)
    if #data.displays > 0 then
        items[#items + 1] = cards(ctx, data, selected, skin, width)
        items[#items + 1] = palette(ctx, data, skin, width)
        if #data.displays > 1 then
            items[#items + 1] = tabs(ctx, data, selected, skin, width)
        end
    end
    if selected then
        items[#items + 1] = grid(ctx, selected, skin, width)
        items[#items + 1] = footer(ctx, selected, skin, width)
    end
    if data.problem then
        items[#items + 1] = ui.text{ text = data.problem, size = 11, color = "error", maxWidth = width, lines = 3 }
    end
    return ui.column(items)
end

return table.freeze(wallpaper)
