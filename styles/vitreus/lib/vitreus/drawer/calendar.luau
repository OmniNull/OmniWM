-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("../kit")
local palette = require("../palette")
local cards = require("../cards")
local frame = require("../frame")

local clockLast
local dayLast

local function at(c, props, x, y)
    return kit.at(c, props, x * c.du, y * c.du)
end

local function label(c, props, x, y)
    props.x, props.y = x * c.du, y * c.du
    return kit.label(c, props)
end

local function quote(text)
    return '"' .. string.gsub(string.gsub(text, "\\", "\\\\"), '"', '\\"') .. '"'
end

local function plate(c, key, x, y, w, h)
    return ui.box(at(c, { key = key, decorative = true, w = w * c.du, h = h * c.du,
        radius = 14 * c.du, fill = palette.alpha("ink", palette.veil) }, x, y))
end

local function presence(c, key, delay, spring, items)
    items.key, items.w, items.h = key, c.w, c.h
    items.appear = { opacity = 0, dy = 12 * c.du, delay = delay, animate = spring }
    items.exit = { opacity = 0, dy = 12 * c.du, animate = kit.springs.close }
    return ui.stack(items)
end

local function date(ctx, seconds, template)
    return ctx.format.date(seconds, template) or ""
end

local function currentDay(ctx): string
    local key = ctx.data.date or ""
    if not dayLast or dayLast.key ~= key then
        dayLast = table.freeze({ key = key, iso = os.date("%Y-%m-%d", ctx.data.seconds or 0) })
    end
    return dayLast.iso
end

local function weatherKind(code)
    if code == 0 then return 0 end
    if code <= 2 then return 1 end
    if code == 3 then return 2 end
    if code <= 48 then return 3 end
    if code >= 95 then return 6 end
    if code >= 71 and code <= 77 or code >= 85 and code <= 86 then return 5 end
    return 4
end

local function weatherIcon(cu, code, cloud)
    local c = kit.canvas(26 * cu, 20 * cu, cu, cu / 1.5525)
    local items = { decorative = true, w = c.w, h = c.h }
    local ink, mint = palette.alpha(cloud or "ink", 1), palette.alpha("mint", 1)
    local kind = weatherKind(code)
    local function box(x, y, w, h, r, color, rotate)
        items[#items + 1] = ui.box(at(c, { w = w * cu, h = h * cu, radius = r * cu,
            fill = color, rotate = rotate }, x, y))
    end
    local function disc(x, y, r, color)
        box(x, y, 2 * r, 2 * r, r, color)
    end
    if kind == 0 or kind == 1 then
        local x, y, r, distance, w, h = 13, 10, 4.6, 7.8, 1.7, 3
        if kind == 1 then x, y, r, distance, w, h = 8.5, 7.5, 3.4, 5.9, 1.4, 2.2 end
        disc(x, y, r, mint)
        for index = 0, 7 do
            local angle = index * math.pi / 4
            box(x + distance * math.sin(angle), y - distance * math.cos(angle), w, h, w / 2, mint, index * 45)
        end
    end
    if kind == 1 then
        disc(10, 13, 3.6, ink)
        disc(15, 11.5, 4.6, ink)
        disc(19, 13.5, 3.2, ink)
        box(14.5, 15.5, 13, 4.5, 2.2, ink)
    elseif kind == 2 or kind >= 4 then
        local cy = if kind == 2 then 10 else 7.5
        disc(9, cy + 1, 4, ink)
        disc(14, cy - 1.5, 5, ink)
        disc(18.5, cy + 1, 3.6, ink)
        box(13.5, cy + 3, 14, 5, 2.5, ink)
    elseif kind == 3 then
        box(13, 5.5, 17, 2, 1, ink)
        box(13, 10, 13, 2, 1, ink)
        box(13, 14.5, 17, 2, 1, ink)
    end
    if kind == 4 then
        local path = {}
        for index = 0, 2 do
            local x = 8.5 + index * 5
            path[#path + 1] = string.format("M %.3f %.3f L %.3f %.3f", x * cu, 14 * cu, (x - 1.5) * cu, 18 * cu)
        end
        items[#items + 1] = kit.stroke(c, table.concat(path, " "), mint, 1.5 * cu)
    elseif kind == 5 then
        disc(8, 15.5, 1.3, mint)
        disc(13, 17.5, 1.3, mint)
        disc(18, 15.5, 1.3, mint)
    elseif kind == 6 then
        local points = { {14.5,11}, {10.5,15.5}, {13.2,15.5}, {11.8,15}, {17,5.5}, {13.5,5.5} }
        local path = {}
        for index, point in points do
            path[#path + 1] = string.format("%s %.3f %.3f", if index == 1 then "M" else "L", point[1] * cu, point[2] * cu)
        end
        items[#items + 1] = ui.path({ w = c.w, h = c.h, d = table.concat(path, " ") .. " Z", fill = mint })
    end
    return ui.stack(items)
end

local function weather(ctx, c)
    local items = { plate(c, "calendar-weather-plate", 225, 49, 426, 60) }
    local data = ctx.data.weather
    if not data or data.access ~= "ok" then
        local text = if not data then "Loading weather…" elseif data.access == "off" then "Weather is off" else "Weather unavailable"
        items[#items + 1] = label(c, { key = "calendar-weather-status", text = text, size = 13,
            color = "secondaryForeground", maxWidth = 300 * c.du, lines = 1 }, 225, 49)
        return items
    end
    items[#items + 1] = ui.stack(at(c, { w = 39 * c.du, h = 30 * c.du,
        weatherIcon(1.5 * c.du, data.code, "ink") }, 35, 41))
    items[#items + 1] = label(c, { text = string.format("%.0f°", data.temp), size = 22, weight = "bold",
        maxWidth = 70 * c.du, lines = 1, align = "leading" }, 65, 39)
    items[#items + 1] = label(c, { text = data.condition, size = 11.5, color = "secondaryForeground",
        maxWidth = 100 * c.du, lines = 1, align = "leading" }, 65, 58)
    items[#items + 1] = ui.box(at(c, { w = c.du, h = 40 * c.du, fill = palette.alpha("ink", 0.12) }, 129, 49))
    for index, day in data.days do
        if index > 7 then break end
        local x = 135 + (index - 1) * (42 + 1 / c.du)
        items[#items + 1] = label(c, { text = day.label, size = 11, weight = "bold",
            color = if index == 1 then "accent" else "secondaryForeground", maxWidth = 40 * c.du, lines = 1 }, x + 21, 31)
        items[#items + 1] = ui.stack(at(c, { w = 26 * c.du, h = 20 * c.du,
            weatherIcon(c.du, day.code, if index == 1 then "mint" else "ink") }, x + 21, 49))
        items[#items + 1] = label(c, { text = string.format("%.0f°", day.high), size = 11.5, weight = "bold" }, x + 12, 66)
        items[#items + 1] = label(c, { text = string.format("%.0f°", day.low), size = 11.5, weight = "bold",
            color = "secondaryForeground" }, x + 31, 66)
    end
    return items
end

local function clockText(ctx)
    local key = (ctx.data.clock or "") .. "|" .. (ctx.data.date or "")
    if clockLast and clockLast.key == key then return clockLast end
    local now = ctx.data.seconds or 0
    local hm, ap = date(ctx, now, "h:mm"), date(ctx, now, "a")
    local first, last = string.find(hm, ap, 1, true)
    if ap ~= "" and first then hm = string.sub(hm, 1, first - 1) .. string.sub(hm, last + 1) end
    hm = string.gsub(string.gsub(hm, " ", " "), " ", " ")
    hm = string.match(hm, "^%s*(.-)%s*$")
    clockLast = table.freeze({ key = key, hm = hm, ap = ap, md = date(ctx, now, "MMM d"), wd = date(ctx, now, "EEEE") })
    return clockLast
end

local function clock(ctx, c)
    local text = clockText(ctx)
    local hm, ap, md, wd = text.hm, text.ap, text.md, text.wd
    local style = { font = kit.font, size = 64.5 * c.rs, weight = "bold" }
    local width = ctx.format.measure(hm, style)
    style.size = 14 * c.rs
    local mdw, wdw = ctx.format.measure(md, style), ctx.format.measure(wd, style)
    return {
        plate(c, "calendar-clock-plate", 95, 123, 166, 72),
        label(c, { key = "calendar-clock", text = hm, size = 64.5, weight = "bold", align = "leading" }, 24, 111),
        ui.box(at(c, { w = 34 * c.rs, h = 20 * c.rs, radius = 10 * c.rs,
            fill = palette.alpha("mint", 0.2) }, 24 + width / c.du + 8 + 17 * c.rs / c.du, 111)),
        label(c, { text = ap, size = 14, weight = "bold", color = "accent" }, 24 + width / c.du + 8 + 17 * c.rs / c.du, 111),
        label(c, { text = md, size = 14, weight = "bold", align = "leading" }, 166 - mdw / c.du, 144),
        label(c, { text = "|", size = 16, weight = "light", color = "accent" }, 166 - mdw / c.du - 8, 144),
        label(c, { text = wd, size = 14, weight = "bold", color = "secondaryForeground",
            align = "leading", maxWidth = 142 * c.du - mdw - 20 * c.du, lines = 1 }, 166 - (mdw + wdw) / c.du - 20, 144),
    }
end

local function daysIn(year, month)
    if month == 2 then return if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then 29 else 28 end
    return if month == 4 or month == 6 or month == 9 or month == 11 then 30 else 31
end

local function cellDate(month, value)
    local year, number = month.year, month.month
    if value < 1 then
        number -= 1
        if number < 1 then number, year = 12, year - 1 end
        value += daysIn(year, number)
    elseif value > month.days then
        value -= month.days
        number += 1
        if number > 12 then number, year = 1, year + 1 end
    end
    return string.format("%04d-%02d-%02d", year, number, value), value
end

local function month(ctx, c)
    local data = ctx.data.calendar
    local m = data and data.month
    local items = { plate(c, "calendar-month-plate", 311, 203, 254, 232) }
    if not m then
        items[#items + 1] = label(c, { text = "Loading calendar…", size = 13, color = "secondaryForeground" }, 311, 203)
        return items
    end
    items[#items + 1] = label(c, { key = "calendar-month-title", text = m.title, size = 17, weight = "semibold",
        maxWidth = 156 * c.du, lines = 1, align = "leading" }, 195, 107)
    local controls = {
        { "previous", 366.5, "‹", "calendar month previous" },
        { "today", 395.5, "Today", "calendar month today" },
        { "next", 424.5, "›", "calendar month next" },
    }
    for _, control in controls do
        local today = control[1] == "today"
        items[#items + 1] = ui.stack(at(c, { key = "calendar-" .. control[1],
            w = (if today then 42 else 26) * c.du, h = (if today then 24 else 26) * c.du,
            radius = 12 * c.du, fill = if today then palette.alpha("ink", 0.08) else nil,
            hover = palette.alpha("ink", 0.18), cursor = "pointer",
            onClick = if today then function(next)
                omniwm.run("calendar month today")
                local current = os.date("%Y-%m-%d", next.data.seconds or 0)
                if current ~= "" then omniwm.run("calendar day " .. current) end
            end else control[4],
            if today then kit.label(kit.canvas(42 * c.du, 24 * c.du, c.du, c.rs), {
                text = "Today", size = 13, weight = "semibold", opacity = 0.8,
            }) else kit.stroke(kit.canvas(26 * c.du, 26 * c.du, c.du, c.rs), string.format(
                "M %.3f %.3f L %.3f %.3f L %.3f %.3f",
                (if control[1] == "previous" then 15.5 else 10.5) * c.du, 8 * c.du,
                (if control[1] == "previous" then 10.5 else 15.5) * c.du, 13 * c.du,
                (if control[1] == "previous" then 15.5 else 10.5) * c.du, 18 * c.du
            ), palette.alpha("ink", 0.8), 1.6 * c.du),
        }, control[2], 107))
    end
    for index, day in m.weekdays do
        items[#items + 1] = label(c, { text = day, size = 11, weight = "semibold",
            color = "secondaryForeground", opacity = 0.65 }, 212 + (index - 1) * 33, 133)
    end
    local marked = {}
    for _, day in m.marked do marked[day] = true end
    local selected = data.selectedDay or currentDay(ctx)
    for index = 0, 41 do
        local value = index - m.offset + 1
        local iso, day = cellDate(m, value)
        local active, today = iso == selected, m.today > 0 and value == m.today
        local x, y = 212 + index % 7 * 33, 157 + math.floor(index / 7) * 27
        local tile = kit.canvas(30 * c.du, 26 * c.du, c.du, c.rs)
        items[#items + 1] = ui.stack(at(c, {
            key = "calendar-day-" .. iso, w = tile.w, h = tile.h, radius = 13 * c.du,
            opacity = if value >= 1 and value <= m.days then 1 else 0.38,
            cursor = "pointer", onClick = "calendar day " .. iso, hover = palette.alpha("ink", 0.09),
            ui.box({ w = 24 * c.du, h = 24 * c.du, radius = 12 * c.du,
                fill = if active then "accent" else nil, border = if today then "accent" else nil,
                borderWidth = if today then 1.5 * c.du else nil, animate = kit.springs.slide }),
            kit.label(tile, { text = tostring(day), size = 13, weight = if today then "bold" else "medium",
                color = if active then "accentForeground" else "foreground" }),
            if value >= 1 and value <= m.days and marked[value] then
                ui.box({ w = 3 * c.du, h = 3 * c.du, radius = 1.5 * c.du, dy = 8.5 * c.du,
                    fill = if active then "accentForeground" else "accent" }) else nil,
        }, x, y))
    end
    return items
end

local function reminder(ctx, c, item)
    local width = 74 * c.du
    local _, textHeight = ctx.format.measure(item.title, { font = kit.font, size = 13 * c.rs,
        maxWidth = width, lines = 5 })
    local h = math.max(30 * c.rs, math.floor(14 * c.rs + textHeight + 0.5))
    local row = kit.canvas(154 * c.du, h, c.du, c.rs)
    local time = if item.due and not item.allDay then date(ctx, item.due, "h:mm") else ""
    return ui.stack({ key = "calendar-reminder-" .. item.id, w = row.w, h = h, radius = 8 * c.du,
        fill = palette.alpha("ink", 0.06), hover = palette.alpha("ink", 0.13),
        ui.stack(kit.at(row, { key = "calendar-complete-" .. item.id, w = 22 * c.du, h = 30 * c.rs,
            cursor = if item.canComplete then "pointer" else nil,
            onClick = if item.canComplete then "reminders complete " .. quote(item.id) else nil,
            ui.box({ w = 11 * c.du, h = 11 * c.du, radius = 5.5 * c.du,
                border = palette.alpha("mint", 0.85), borderWidth = 1.3 * c.du }),
        }, 15 * c.rs, 15 * c.rs)),
        kit.label(row, { text = time, x = 22 * c.du, y = 15 * c.rs, align = "leading", size = 11.5,
            weight = "semibold", color = "accent", maxWidth = 34 * c.du, lines = 1 }),
        ui.text({ text = item.title, font = kit.font, size = 13 * c.rs, color = "foreground",
            w = width, maxWidth = width, lines = 5, align = "topLeading", dx = 56 * c.du, dy = 7 * c.rs }),
    })
end

local function reminders(ctx, c)
    local data = ctx.data.calendar
    local snapshot = data and data.reminders
    local selected = data and data.selectedDay or currentDay(ctx)
    local title = if selected == currentDay(ctx) then "Today" else selected
    local count = if snapshot then #snapshot.items else 0
    local events = if data then data.events else {}
    local total = count + #events
    local items = {
        plate(c, "calendar-reminders-plate", 95, 242, 166, 154),
        label(c, { key = "calendar-selected-day", text = title, size = 15, weight = "semibold",
            maxWidth = 142 * c.du, lines = 1, align = "leading" }, 24, 185),
        label(c, { text = if total == 1 then "1 item" else tostring(total) .. " items", size = 12,
            color = "secondaryForeground", opacity = 0.75, align = "leading" }, 24, 200),
    }
    local rows = { key = "calendar-reminders", w = 154 * c.du, h = 106 * c.du,
        align = "topLeading", dx = 18 * c.du, dy = 213 * c.du, gap = 4 * c.rs, center = false, scroll = true }
    if total == 0 then
        local text = if snapshot and snapshot.access == "full" then "Add one below" else "Reminders unavailable"
        rows[#rows + 1] = ui.text({ text = text, font = kit.font, size = 13 * c.rs,
            color = "secondaryForeground", maxWidth = rows.w, lines = 2 })
    else
        for _, item in if snapshot then snapshot.items else {} do rows[#rows + 1] = reminder(ctx, c, item) end
        for _, event in events do
            local width = 126 * c.du
            local _, height = ctx.format.measure(event.title, { font = kit.font, size = 13 * c.rs,
                maxWidth = width, lines = 5 })
            rows[#rows + 1] = ui.column({ key = "calendar-event-" .. event.id, w = 154 * c.du,
                pad = 6 * c.du, gap = 3 * c.rs, radius = 8 * c.du, center = false,
                fill = palette.alpha("ink", 0.06), hover = palette.alpha("ink", 0.13),
                cursor = "pointer", onClick = "calendar open " .. quote(event.id),
                ui.text({ text = if event.allDay then "All day" else event.time, font = kit.font, size = 11.5 * c.rs,
                    color = "accent", weight = "semibold", maxWidth = width, lines = 1 }),
                ui.text({ text = event.title, font = kit.font, size = 13 * c.rs, color = "foreground",
                    w = width, h = height, maxWidth = width, lines = 5 }),
            })
        end
    end
    items[#items + 1] = ui.column(rows)
    return items
end

local function submit(ctx, text)
    local trimmed = string.match(text, "^%s*(.-)%s*$")
    if trimmed == "" then return end
    if #trimmed > 4096 then ctx.state.calendarError = "Reminder is too long" return end
    omniwm.run("reminders add " .. quote(trimmed))
    ctx.state.calendarDraft, ctx.state.calendarError = trimmed, nil
    ctx.state.calendarNote = "Reminder requested"
    ctx.state.calendarEntry = (ctx.state.calendarEntry or 0) + 1
end

local function entry(ctx, c)
    local calendar = ctx.data.calendar
    local reminders = calendar and calendar.reminders
    local allowed = reminders and (reminders.access == "full" or reminders.access == "writeOnly")
    local items = { plate(c, "calendar-entry-plate", 225, 344, 426, 34) }
    if not allowed then
        items[#items + 1] = ui.stack(at(c, { key = "calendar-reminders-access", w = 400 * c.du, h = 28 * c.du,
            cursor = "pointer", onClick = "reminders settings",
            kit.label(kit.canvas(400 * c.du, 28 * c.du, c.du, c.rs), {
                text = if reminders and reminders.error then reminders.error else "Open Reminders Privacy Settings",
                size = 13, color = "secondaryForeground", maxWidth = 396 * c.du, lines = 1,
            }),
        }, 225, 344))
        return items
    end
    items[#items + 1] = ui.box(at(c, { w = 8 * c.du, h = 8 * c.du, radius = 4 * c.du,
        fill = palette.alpha("mint", 0.85) }, 24, 344))
    items[#items + 1] = ui.input(at(c, {
        key = "calendar-entry-" .. (ctx.state.calendarEntry or 0), w = 330 * c.du, h = 25 * c.rs,
        text = ctx.state.calendarDraft or "", font = kit.font, size = 15 * c.rs, color = "foreground",
        placeholder = ctx.state.calendarError or "New reminder: 3:30pm Call mom", maxLength = 4096, focus = true,
        onChange = function(next, event)
            next.state.calendarDraft = event.text
            next.state.calendarNote = nil
        end,
        onCommit = function(next, event) submit(next, event.text) end,
    }, 201, 344))
    items[#items + 1] = ui.stack(at(c, { key = "calendar-add", w = 48 * c.du, h = 28 * c.du,
        radius = 12 * c.du, fill = palette.alpha("mint", 0.8), hover = "accent", cursor = "pointer",
        onClick = function(next) submit(next, next.state.calendarDraft or "") end,
        kit.label(kit.canvas(48 * c.du, 28 * c.du, c.du, c.rs), {
            text = "Add", size = 14, weight = "bold", color = "accentForeground",
        }),
    }, 403, 344))
    if ctx.state.calendarError or reminders.error or ctx.state.calendarNote then
        items[#items + 1] = label(c, { text = ctx.state.calendarError or reminders.error or ctx.state.calendarNote, size = 10,
            color = if ctx.state.calendarError or reminders.error then "error" else "secondaryForeground", maxWidth = 426 * c.du, lines = 1 }, 225, 368)
    end
    return items
end

local function append(to, values)
    for _, value in values do to[#to + 1] = value end
end

local function layout(ctx)
    local month = not cards.out(ctx, "calendar-month")
    local events = not cards.out(ctx, "calendar-events")
    local eventX, eventY = if month then 12 else 272, if month then 165 else 87
    local clockY = if month and not events then 203 else 123
    local bottom = math.max(clockY + 36, if month then 319 else 0, if events then eventY + 154 else 0)
    return { eventsX = eventX, eventsY = eventY, clockY = clockY, entryY = bottom + 25, h = bottom + 54 }
end

local function height(ctx)
    return if frame.framed(ctx.data.settings) then 373 else layout(ctx).h
end

local function group(c, p, key, nodes, x, y)
    local props = { key = key, w = c.w, h = c.h, align = "topLeading", dx = (x or 0) * c.du, dy = (y or 0) * c.du,
        animate = if not p.loose then p.calm else nil }
    append(props, nodes)
    return ui.stack(props)
end

local function content(ctx, p)
    if not p or not p.cu or not p.w or not p.h then return nil end
    local c = kit.canvas(p.w, p.h, p.cu, p.rs)
    if not p.frame then
        c = kit.canvas(p.w, 373 * p.cu, p.cu, p.rs)
        local plan = layout(ctx)
        local result = {
            presence(c, "calendar-f1", 0.22, kit.springs.fd0, { align = "topLeading",
                group(c, p, "calendar-clock-group", clock(ctx, c), 0, plan.clockY - 123) }),
            presence(c, "calendar-f4", 0.30, kit.springs.fd1, { align = "topLeading",
                group(c, p, "calendar-weather-group", weather(ctx, c)),
                group(c, p, "calendar-entry-group", entry(ctx, c), 0, plan.entryY - 344) }),
        }
        if not cards.out(ctx, "calendar-events") then result[#result + 1] = cards.placeholder(p, "calendar-events", plan.eventsX, plan.eventsY, 166, 154) end
        if not cards.out(ctx, "calendar-month") then result[#result + 1] = cards.placeholder(p, "calendar-month", 184, 87, 254, 232) end
        return result
    end
    local first, fourth = {}, {}
    append(first, clock(ctx, c))
    append(first, reminders(ctx, c))
    append(fourth, month(ctx, c))
    append(fourth, weather(ctx, c))
    append(fourth, entry(ctx, c))
    return {
        presence(c, "calendar-f1", 0.22, kit.springs.fd0, first),
        presence(c, "calendar-f4", 0.30, kit.springs.fd1, fourth),
    }
end

local function sections(ctx, p)
    local result = {}
    local plan = layout(ctx)
    for _, spec in { { "calendar-month", 184, 87, 254, 232, month }, { "calendar-events", 12, 165, 166, 154, reminders } } do
        result[#result + 1] = { id = spec[1], x = if spec[1] == "calendar-events" then plan.eventsX else spec[2],
            y = if spec[1] == "calendar-events" then plan.eventsY else spec[3], w = spec[4], h = spec[5],
            gripY = if spec[1] == "calendar-month" then 222 else 0,
            delay = if spec[1] == "calendar-month" then 0.30 else 0.22,
            spring = if spec[1] == "calendar-month" then kit.springs.fd1 else kit.springs.fd0,
            content = function(next, offer)
                local c = kit.canvas(450 * offer.cu, 373 * offer.cu, offer.cu, offer.rs)
                local nodes = { w = c.w, h = c.h, align = "topLeading", dx = -spec[2] * offer.cu, dy = -spec[3] * offer.cu }
                append(nodes, spec[6](next, c))
                return { ui.stack(nodes) }
            end }
    end
    return result
end

return table.freeze({ content = content, sections = sections, height = height })
