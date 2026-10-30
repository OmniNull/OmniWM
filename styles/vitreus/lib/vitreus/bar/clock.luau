-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("../kit")
local palette = require("../palette")
local pencil = require("../pencil")
local buttons = require("./buttons")

local shadow = palette.alpha("deep", 0.4)
local lift = table.freeze({ x = 0, y = 1 })
local last
local verticalLast

local function round(value: number): number
    return math.floor(value + 0.5)
end

local function parts(ctx)
    local clock = string.gsub(ctx.data.clock or "", "\u{202F}", " ")
    local hour, minute = string.match(clock, "(%d+)[:.](%d%d)")
    local meridiem = string.match(string.gsub(clock, "%d+[:.]%d%d", "", 1), "^%s*(.-)%s*$")
    local day = string.match(ctx.data.date or "", "^[^%d%s%p]+")
    return hour or "", if minute then ":" .. minute else "", string.lower(meridiem or ""), string.upper(day or "")
end

local function measure(ctx, bz: number)
    local hour, minutes, meridiem, day = parts(ctx)
    local key = table.concat({ hour, minutes, meridiem, day, bz }, "|")
    if last and last.key == key then return last end
    local function size(text: string, points: number, weight: string)
        local w, h = ctx.format.measure(text, { font = kit.font, size = points * bz, weight = weight })
        return { text = text, w = w, h = h, size = points * bz, weight = weight }
    end
    local texts = {
        hour = size(hour, 40, "bold"),
        minutes = size(minutes, 26, "bold"),
        lead = size(string.sub(minutes, 1, 2), 26, "bold"),
        tail = size(string.sub(minutes, 3), 26, "bold"),
        day = size(day, 11, "bold"),
        meridiem = size(meridiem, 14, "semibold"),
    }
    local column = math.max(texts.meridiem.w, texts.day.w)
    last = table.freeze({ key = key, texts = texts, column = column, w = texts.hour.w + texts.minutes.w + column })
    return last
end

local function width(ctx, k): (number, number)
    return measure(ctx, k.bz).w, 0
end

local function label(key: string, spec, color: string, x: number, y: number, ox: number, oy: number)
    return ui.text({
        key = "clock-" .. key, text = spec.text, font = kit.font, size = spec.size, weight = spec.weight,
        color = color, decorative = true, align = "topLeading", dx = x - ox, dy = y - spec.h / 2 - oy,
        shadow = shadow, shadowRadius = 3, shadowOffset = lift,
    })
end

local function none()
    return nil
end

local function verticalMeasure(ctx, bz: number)
    local hour, minute, meridiem, day = parts(ctx)
    minute = string.sub(minute, 2)
    local monthDay = string.upper(os.date("%b", ctx.data.seconds)) .. " " .. tostring(tonumber(os.date("%d", ctx.data.seconds)))
    local key = table.concat({ hour, minute, meridiem, day, monthDay, bz }, "|")
    if verticalLast and verticalLast.key == key then return verticalLast end
    local function spec(value: string, points: number)
        local w, h = ctx.format.measure(value, { font = kit.font, size = points * bz, weight = "bold" })
        return { text = value, w = w, h = h, size = points * bz, weight = "bold" }
    end
    verticalLast = table.freeze({ key = key, hour = spec(hour, 30), minute = spec(minute, 17),
        ap = spec(string.sub(meridiem, 1, 1), 11), m = spec(if meridiem == "" then "" else "m", 11),
        day = spec(day, 11), date = spec(monthDay, 14) })
    return verticalLast
end

local function vertical(ctx, g)
    local k, pill, lv = g.k, g.pill, g.frame.lv
    local bu, bz = k.bu, k.bz
    local m = verticalMeasure(ctx, bz)
    local a, fr = buttons.sketch(ctx, "clock")
    local ox, oy = pill.x + 2 * bu, lv.clk - 20 * bu
    local width, height = pill.w - 4 * bu, 100 * bu
    local group = { key = "clock-group", decorative = true, w = width, h = height,
        scale = 1 + 0.08 * a, animate = buttons.touch }
    local function word(key, spec, x, y, color)
        return label(key, spec, color, round(x - spec.w / 2), round(y), ox, oy)
    end
    local numerals = { key = "clock-numerals", decorative = true, align = "topLeading", dx = 0, dy = 2 * bu,
        w = width, h = 60 * bu, effect = { source = "vitreus-clock-gradient.metal", fps = 0, values = { 0.85, 0.55 } },
        shadow = shadow, shadowRadius = 3, shadowOffset = lift }
    for _, item in { { "hour", m.hour, 18 }, { "minutes", m.minute, 46 } } do
        numerals[#numerals + 1] = ui.text({ key = "clock-" .. item[1], text = item[2].text, font = kit.font,
            size = item[2].size, weight = "bold", color = "#ffffff", decorative = true,
            align = "topLeading", dx = round(pill.cx - 5 * bu - item[2].w / 2) - ox,
            dy = item[3] * bu - item[2].h / 2 })
    end
    group[#group + 1] = ui.stack(numerals)
    group[#group + 1] = word("meridiem-a", m.ap, pill.cx + 12.5 * bu, lv.clk + 11.9 * bu, palette.roles.mint)
    group[#group + 1] = word("meridiem-m", m.m, pill.cx + 12.5 * bu, lv.clk + 21.1 * bu, palette.roles.mint)
    group[#group + 1] = word("day", m.day, pill.cx + 5 * bu, lv.clk + 41 * bu, palette.roles.faint)
    group[#group + 1] = word("date", m.date, pill.cx, lv.clk + 55 * bu, palette.roles.ink)
    local line = pencil.line(pill.cx - 5 * bu - ox, lv.clk + 16.5 * bu - oy, 18 * bu, bu, a, fr)
    buttons.append(group, pencil.draw(width, height, line, palette.roles.mint, 0.85))
    local display = ctx.data.bar.monitorId
    return { ui.stack({ key = "bar-clock", align = "topLeading", dx = ox, dy = oy, w = width, h = height,
        cursor = "pointer", onClick = "shell trigger vitreus drawer-calendar " .. display,
        onRightClick = "shell trigger vitreus drawer-close " .. display, onHover = buttons.hover("clock", true),
        ui.stack(group) }) }
end

local function content(ctx, g, slot)
    if g.frame and g.frame.vertical then return vertical(ctx, g) end
    local k = g.k
    local bu, bz = k.bu, k.bz
    local pill = g.pill
    local m = measure(ctx, bz)
    if m.w <= 0 then return nil end
    local t = m.texts
    local y = pill.cy
    local right = slot.x + slot.w
    local zone = { x = slot.cx - (m.w + 8 * bu) / 2, w = m.w + 8 * bu }
    local ox, oy = zone.x, pill.y
    local a, fr = buttons.sketch(ctx, "clock")
    local middle = round(right - m.column / 2)
    local minutes = round(right - m.column - 3 * bz)
    local hour = round(right - m.column - t.minutes.w)
    local left = right - m.column - t.minutes.w - t.hour.w
    local faint, mint = palette.alpha("faint", 1), palette.alpha("mint", 1)
    local group = {
        key = "clock-group", decorative = true, w = zone.w, h = pill.h, scale = 1 + 0.08 * a, animate = buttons.touch,
        label("day", t.day, faint, middle - t.day.w / 2, round(y - 8 * bz), ox, oy),
        label("meridiem", t.meridiem, faint, middle - t.meridiem.w / 2, round(y + 7 * bz), ox, oy),
        label("tail", t.tail, mint, minutes - t.tail.w, round(y + 3 * bz), ox, oy),
        label("lead", t.lead, mint, minutes - t.tail.w + 3 * bz - t.lead.w, round(y + 3 * bz), ox, oy),
        label("hour", t.hour, palette.alpha("ink", 1), hour - t.hour.w, round(y), ox, oy),
    }
    local length = t.hour.w + t.minutes.w
    local line = if g.layout == "seg"
        then pencil.line(right - m.column / 2 - ox, y - 0.5 - oy, 0.6 * m.column, bu, a, fr)
        else pencil.line(left + length / 2 - ox, y + 0.43 * pill.h - oy, length, bu, a, fr)
    buttons.append(group, pencil.draw(zone.w, pill.h, line, mint, 0.5))
    local display = ctx.data.bar.monitorId
    return { ui.stack({
        key = "bar-clock", align = "topLeading", dx = zone.x, dy = pill.y, w = zone.w, h = pill.h, cursor = "pointer",
        onClick = "shell trigger vitreus drawer-calendar " .. display,
        onRightClick = "shell trigger vitreus drawer-close " .. display, onHover = buttons.hover("clock", true),
        ui.stack(group),
    }) }
end

return table.freeze({ width = width, shapes = none, content = content })
