-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("./kit")
local palette = require("./palette")

local bands = table.freeze({ response = 2 * math.pi / math.sqrt(520), bounce = 1 - 26 / (2 * math.sqrt(520)) })

local function resample(values)
    local result, count = {}, #values
    for index = 0, 23 do
        local left, right = index * count / 24, (index + 1) * count / 24
        local total = 0
        for source = math.floor(left), math.ceil(right) - 1 do
            local weight = math.max(0, math.min(right, source + 1) - math.max(left, source))
            total += math.clamp(values[source + 1] or 0, 0, 1) * weight
        end
        result[index + 1] = if count > 0 then total * 24 / count else 0
    end
    return result
end

local function clock(seconds: number): string
    local time = math.max(0, math.floor(seconds + 0.5))
    if time >= 3600 then return string.format("%d:%02d:%02d", time // 3600, time % 3600 // 60, time % 60) end
    return string.format("%d:%02d", time // 60, time % 60)
end

local function position(ctx, m)
    local elapsed = m.elapsed or 0
    if m.playing then elapsed += math.max(0, (ctx.data.seconds or m.sampledAt) - m.sampledAt) * m.rate end
    local duration = m.duration
    if duration and duration > 0 then return math.clamp(elapsed, 0, duration), duration end
    return math.max(0, elapsed), nil
end

local function box(c, props, x, y, w, h, r)
    props.w, props.h, props.radius = w * c.du, h * c.du, r * c.du
    return ui.box(kit.at(c, props, x * c.du, y * c.du))
end

local function label(c, key, text, x, y, size, color, weight, width)
    return kit.label(c, { key = key, text = text, align = "leading", x = x * c.du, y = y * c.du,
        size = size, color = color, weight = weight, maxWidth = width * c.du, lines = 1, decorative = true })
end

local function path(c, key, points, color, width)
    local words = {}
    for _, point in points do
        words[#words + 1] = type(point) == "string" and point or string.format("%.3f", point * c.du)
    end
    return ui.path({ key = key, w = c.w, h = c.h, align = "topLeading", decorative = true,
        d = table.concat(words, " "), fill = if width then 0 else color, border = if width then color else nil,
        borderWidth = width and width * c.du })
end

local function cover(ctx, c, m, key)
    local art = m.artwork
    if art and art ~= "" then
        return ui.stack(kit.at(c, { key = key .. "-cover", w = 72 * c.du, h = 72 * c.du,
            shadow = palette.alpha("ink", 0.6), shadowRadius = 12 * c.du, shadowOffset = { x = 0, y = 0 },
            appear = { opacity = 0, scale = 0.7, rotate = -12, animate = kit.springs.pop },
            ui.image({ key = key .. "-art-" .. art, image = art, w = 72 * c.du, h = 72 * c.du, radius = 15 * c.du }),
        }, 48 * c.du, 50 * c.du))
    end
    return ui.stack({ key = key .. "-cover", w = c.w, h = c.h, align = "topLeading", decorative = true,
        ui.glass({ key = key .. "-cover-fallback", w = 72 * c.du, h = 72 * c.du,
            dx = 12 * c.du, dy = 14 * c.du, align = "topLeading", backdrop = false, blend = 0, rim = 0.14,
            gradient = { from = palette.roles.off, to = palette.roles.deep, angle = 45 },
            ui.shape({ w = 72 * c.du, h = 72 * c.du, radius = 15 * c.du }),
        }),
        box(c, { fill = palette.alpha("ink", 0.75) }, 42, 61, 13, 13, 6.5),
        box(c, { fill = palette.alpha("ink", 0.75) }, 49.5, 46, 3, 30, 1.5),
        path(c, nil, { "M", 51, 31, "C", 61, 33, 63, 36, 63, 44 }, palette.alpha("ink", 0.75), 3),
    })
end

local function hover(ctx, key)
    return function(next, event)
        if event.phase == "began" then next.state.mediaHot = key
        elseif next.state.mediaHot == key then next.state.mediaHot = nil end
    end
end

local function transport(ctx, c, m, key)
    local items = {}
    for _, spec in { { "previous", 17.9, 26 }, { "play", 48, 30 }, { "next", 78.1, 26 } } do
        local name, x, w = spec[1], spec[2], spec[3]
        local hot = ctx.state.mediaHot == key .. "-" .. name
        local color = palette.alpha("ink", if hot then 1 else 0.75)
        if name == "play" then
            items[#items + 1] = box(c, { fill = palette.alpha("ink", 0.95), animate = kit.springs.pop },
                x, 108, if hot then 25.4 else 23, if hot then 25.4 else 23, 12.7)
            if m.playing then
                for _, dx in { -3, 3 } do
                    items[#items + 1] = box(c, { fill = palette.roles.onmint }, x + dx, 108, 3, 10.5, 1.2)
                end
            else
                items[#items + 1] = path(c, nil, { "M", x - 3, 102, "L", x + 6, 108, "L", x - 3, 114, "Z" },
                    palette.roles.onmint)
            end
        else
            local sign = if name == "next" then 1 else -1
            items[#items + 1] = box(c, { fill = color }, x + 5 * sign, 108, 1.8, 9.6, 0.9)
            items[#items + 1] = path(c, nil,
                { "M", x - 4 * sign, 103.2, "L", x + 3.6 * sign, 108, "L", x - 4 * sign, 112.8, "Z" }, color)
        end
        items[#items + 1] = ui.box(kit.at(c, { key = key .. "-" .. name, w = w * c.du, h = 30 * c.du,
            cursor = "pointer", onClick = "media " .. (if name == "play" then "toggle" else name),
            onHover = hover(ctx, key .. "-" .. name),
        }, x * c.du, 108 * c.du))
    end
    return items
end

local function spectrum(ctx, c, m, key)
    local source = {}
    if (ctx.data.settings or {}).visualiser == true then
        local sampled = ctx.data.spectrum
        if sampled and sampled.access == "granted" then source = sampled.bars end
    end
    local levels, items = resample(source), {}
    for index, level in levels do
        local value = math.clamp(level * (0.8 + 0.7 * (index - 1) / 23), 0, 1)
        local height, x = 1.5 + 31 * value, 94 + (index - 0.5) * 7.6
        local alpha = (if m.playing then 1 else 0.35) * (0.45 + 0.55 * value)
        items[#items + 1] = ui.stack(kit.at(c, { key = key .. "-band-" .. index,
            w = 4.2 * c.du, h = height * c.du, opacity = alpha, animate = bands,
            ui.box({ w = 4.2 * c.du, h = height * c.du, radius = 2.1 * c.du, fill = palette.roles.mint, animate = bands }),
            ui.box({ w = 4.2 * c.du, h = height * c.du, radius = 2.1 * c.du, fill = palette.roles.ink,
                opacity = 0.85 * value, animate = bands }),
        }, x * c.du, (88 - height / 2) * c.du))
        items[#items + 1] = box(c, { key = key .. "-reflection-" .. index, fill = palette.roles.mint,
            opacity = if m.playing then 0.28 * value else 0, animate = bands },
            x, 90 + height * 0.28, 4.2, height * 0.56, 2.1)
    end
    return ui.stack({ key = key .. "-spectrum", w = c.w, h = c.h, align = "topLeading", decorative = true,
        shadow = palette.alpha("mint", 0.35), shadowRadius = 6 * c.du, shadowOffset = { x = 0, y = 0 },
        table.unpack(items),
    })
end

local function seek(ctx, c, m, key, wave)
    local elapsed, duration = position(ctx, m)
    local identity = table.concat({ m.bundle, m.title, m.artist }, "\0")
    if ctx.state.mediaIdentity ~= identity then ctx.state.mediaIdentity, ctx.state.mediaSeek = identity, nil end
    local draft = ctx.state.mediaSeek
    local fraction = draft or (if duration then elapsed / duration else 1)
    local width = 192 * fraction
    local hot = ctx.state.mediaHot == key .. "-seek" or draft ~= nil
    local items = { label(c, key .. "-elapsed", clock(if draft and duration then draft * duration else elapsed),
        12, 134, 11.5, palette.roles.faint, "semibold", 34) }
    local total = if duration then clock(duration) else "Live"
    local totalWidth = ctx.format.measure(total, { font = kit.font, size = 11.5 * c.rs, weight = "semibold" })
    items[#items + 1] = label(c, key .. "-duration", total,
        276 - math.min(totalWidth / c.du, 34), 134, 11.5,
        if duration then palette.roles.faint else palette.roles.mint, "semibold", 34)
    if duration then
        items[#items + 1] = box(c, { fill = palette.alpha("ink", 0.14) }, 144, 134, 192, if hot then 6 else 4, 3)
        items[#items + 1] = box(c, { key = key .. "-seek-knob", fill = palette.roles.ink },
            math.clamp(48 + width, 50, 238), 134, 5, if hot then 18 else 15, 2.5)
    end
    if wave then
        items[#items + 1] = wave(c, key, width, hot, duration == nil)
    else
        local words = {}
        local falloff = math.max(0.001, math.min(width * 0.2, 9))
        for index = 0, 192 do
            local x = width * index / 192
            local envelope = math.clamp(x / falloff, 0, 1) * math.clamp((width - x) / falloff, 0, 1)
            words[#words + 1] = if index == 0 then "M" else "L"
            words[#words + 1] = string.format("%.3f %.3f", (48 + x) * c.du,
                (134 + (if hot then 4.5 else 3.4) * envelope * math.sin(x * 2 * math.pi / 26)) * c.du)
        end
        items[#items + 1] = ui.path({ key = key .. "-seek-wave", w = c.w, h = c.h, align = "topLeading",
            decorative = true, d = table.concat(words, " "), fill = 0, border = palette.roles.mint,
            borderWidth = (if hot then 6 else 4) * c.du, opacity = math.min(1, width / 6) })
    end
    if duration and m.elapsed ~= nil then
        local function update(next, event)
            local phase = event.phase
            if phase == "down" or phase == "began" or phase == "changed" then
                next.state.mediaSeek = math.clamp(((event.x or 0) / c.du - 8) / 192, 0, 1)
            elseif phase == "up" or phase == "ended" then
                local value = next.state.mediaSeek
                next.state.mediaSeek = nil
                if value ~= nil then omniwm.run(string.format("media seek %.3f", value * duration)) end
            elseif phase == "cancel" or phase == "cancelled" then next.state.mediaSeek = nil end
        end
        items[#items + 1] = ui.box(kit.at(c, { key = key .. "-seek", w = 208 * c.du, h = 22 * c.du,
            cursor = "pointer", onHover = hover(ctx, key .. "-seek"), onPress = update,
            gesture = { axis = "x", threshold = 0 }, gestureEvents = "all", onGesture = update,
        }, 144 * c.du, 134 * c.du))
    end
    return items
end

local function plate(ctx, p)
    local m = ctx.data.media
    if not m then return nil end
    local key = p.key or "player-media"
    local c = kit.canvas(288 * p.cu, 148 * p.cu, p.cu, p.rs)
    local art = p.cover and m.artwork and m.artwork ~= ""
    local items = { key = key, w = c.w, h = c.h, align = "topLeading", dx = p.x or 0, dy = p.y or 0,
        box(c, { key = key .. "-plate", fill = palette.alpha("ink", palette.veil), decorative = true,
            opacity = p.veil, animate = p.veilMotion }, 144, 74, 288, 148, 14),
        if art then p.cover(c, m, key) else cover(ctx, c, m, key),
        label(c, key .. "-title", m.title, 94, 26, 16.5, palette.roles.ink, "bold", 186),
        label(c, key .. "-artist", m.artist, 94, 44, 14, palette.alpha("mint", 0.9), nil, 186),
    }
    for _, item in transport(ctx, c, m, key) do items[#items + 1] = item end
    items[#items + 1] = spectrum(ctx, c, m, key)
    for _, item in seek(ctx, c, m, key, p.wave) do items[#items + 1] = item end
    return ui.stack(items)
end

return table.freeze({ plate = plate, resample = resample })
