-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("../palette")
local buttons = require("./buttons")

local lights = table.freeze({
    { key = "microphone", color = "#f59e0b" },
    { key = "camera", color = "#22c55e" },
})

local function round(value: number): number
    return math.floor(value + 0.5)
end

local function number(value: number): string
    return string.format("%.3f", value)
end

local function entries(ctx, name: string?)
    local list = {}
    local privacy = ctx.data.privacy
    for _, light in lights do
        if privacy and privacy[light.key] then list[#list + 1] = { light = light } end
    end
    local hidden = if name == "privacy" then nil else ctx.data.hiddenBar
    for _, item in (hidden and hidden.items) or {} do
        list[#list + 1] = { item = item }
    end
    return list
end

local function width(ctx, k, name: string?): (number, number)
    local count = #entries(ctx, name)
    local w = math.max(0, count * 24 - 6) * k.bu
    return w, if count > 0 then w + 12 * k.bu else 0
end

local function none()
    return nil
end

local function glyph(key: string, color: string, bu: number, cell: number)
    local function part(cx: number, cy: number, w: number, h: number, r: number)
        return ui.box({
            decorative = true, align = "topLeading", dx = (cx - w / 2) * bu, dy = (cy - h / 2) * bu, w = w * bu,
            h = h * bu, radius = r * bu, fill = color,
        })
    end
    if key == "microphone" then
        local function at(x: number, y: number): string
            return number((9 + x) * bu) .. " " .. number((7 + y) * bu)
        end
        return {
            part(9, 7, 5, 8.5, 2.5),
            ui.path({
                decorative = true, w = cell, h = cell, fill = 0, border = color, borderWidth = 1.3 * bu,
                d = table.concat({ "M", at(-4, 0.5), "Q", at(-4, 5.5), at(0, 5.5), "Q", at(4, 5.5), at(4, 0.5) }, " "),
            }),
            part(9, 13.8, 1.3, 2.2, 0.6),
        }
    end
    local function at(x: number, y: number): string
        return number((12.5 + x) * bu) .. " " .. number((9 + y) * bu)
    end
    return {
        part(7.6, 9, 9, 7, 2),
        ui.path({
            decorative = true, w = cell, h = cell, fill = color,
            d = table.concat({ "M", at(0, -1.2), "L", at(3.2, -3), "L", at(3.2, 3), "L", at(0, 1.2), "Z" }, " "),
        }),
    }
end

local function light(spec, bu: number, cell: number, x: number, y: number)
    local color = spec.color
    local disc = buttons.glow({
        key = "tray-" .. spec.key, decorative = true, align = "topLeading", dx = x, dy = y, w = cell, h = cell,
        ui.box({
            key = "tray-" .. spec.key .. "-disc", align = "topLeading", dx = 0, dy = 0, w = 18 * bu, h = 18 * bu,
            radius = 9 * bu, fill = color .. "45", shadow = color .. "99", shadowRadius = 4.5 * bu,
            shadowOffset = { x = 0, y = 0 },
        }),
    }, bu)
    return ui.stack(buttons.append(disc, glyph(spec.key, color, bu, cell)))
end

local function picture(item, cell: number)
    if not item.image then
        return ui.symbol({ name = "app.dashed", size = 0.8 * cell, color = palette.alpha("faint", 1) })
    end
    local fit = cell / math.max(item.w, item.h, 1)
    return ui.image({ key = "tray-" .. item.id .. "-image", image = item.image, w = item.w * fit, h = item.h * fit })
end

local function icon(ctx, item, bu: number, cell: number, x: number, y: number)
    local key = "tray-" .. item.id
    local a = if ctx.state.barHot == key then 1 else 0
    return ui.stack({
        key = key, align = "topLeading", dx = x + 9 * bu - 12 * bu, dy = y + 9 * bu - 15 * bu, w = 24 * bu,
        h = 30 * bu, cursor = "pointer", help = item.name, onClick = "hidden-bar activate " .. item.id,
        onHover = buttons.hover(key),
        ui.box({
            key = key .. "-plate", decorative = true, w = 26 * bu, h = 26 * bu, radius = 8 * bu,
            fill = palette.alpha("ink", 0.14), opacity = a, animate = buttons.touch,
        }),
        ui.stack(buttons.glow({
            key = key .. "-icon", decorative = true, w = cell, h = cell, dx = cell / 2 - 9 * bu, dy = cell / 2 - 9 * bu,
            scale = 1 + 0.14 * a, opacity = 0.78 + 0.22 * a, animate = buttons.touch, picture(item, cell),
        }, bu)),
    })
end

local function content(ctx, g, slot, name: string?)
    local list = entries(ctx, name)
    if #list == 0 then return nil end
    local bu = g.k.bu
    local cell = round(18 * bu)
    local step = cell + round(6 * bu)
    local vertical = g.frame and g.frame.vertical
    local x = round(if vertical then g.pill.cx - 9 * bu else slot.cx - (#list * 24 - 6) * bu / 2)
    local y = round(if vertical then slot.y else g.pill.cy - 9 * bu)
    local items = {}
    for index, entry in list do
        local left = x + (if vertical then 0 else (index - 1) * step)
        local top = y + (if vertical then (index - 1) * step else 0)
        items[index] = if entry.light then light(entry.light, bu, cell, left, top)
            else icon(ctx, entry.item, bu, cell, left, top)
    end
    return items
end

return table.freeze({ width = width, shapes = none, content = content })
