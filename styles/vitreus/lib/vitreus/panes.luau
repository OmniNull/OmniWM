-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local palette = require("./palette")
local desk = require("./desk")
local liquid = require("./liquid")
local mediacard = require("./mediacard")

local function none()
    return nil
end

local function append(list, items)
    for _, item in items or {} do
        list[#list + 1] = item
    end
end

local function render(ctx, g)
    if not g.island or g.frame then return nil end
    local body = {
        key = "desk-glass", w = g.size.w, h = g.size.h, align = "topLeading",
        fill = palette.alpha("tint", 0.36), shadow = palette.alpha("deep", 0.24),
        shadowRadius = 20, shadowOffset = { x = 0, y = 7 }, rim = 0.1, blend = 26 * g.k.u,
    }
    local content = {}
    if ctx.state.expanded then
        local place = desk.geometry(ctx, g)
        body[#body + 1] = desk.shape(place)
        append(body, liquid.edge(g, place, 64 - #body))
        content[#content + 1] = desk.render(ctx, place)
    end
    append(body, mediacard.shapes(ctx, g, 64 - #body))
    append(content, mediacard.content(ctx, g))
    local items = { ui.glass(body) }
    append(items, content)
    return items
end

return table.freeze({ render = render, shapes = none, content = none })
