-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local desk = require("./desk")
local mediacard = require("./mediacard")
local kit = require("./kit")
local stick = require("./stick")
local units = require("./units")
local drawer = require("./drawer")

local function plate(g, place)
    local binding, reach = units.edgeSource(g, "desk", place.base.du,
        { left = -6.5 * place.k.du, right = 6.5 * place.k.du })
    return ui.shape({
        key = "desk-shape", align = "topLeading", dx = -reach, dy = -reach,
        w = g.size.w + 2 * reach, h = g.size.h + 2 * reach, radius = place.bodyRadius,
        reveal = kit.springs.drip, morph = { source = binding, stops = { { at = 0 }, { at = 1 } } },
    })
end

local function append(items, given)
    for _, item in given or {} do items[#items + 1] = item end
end

local function edge(g, place, budget: number, target: string?, prefix: string?)
    return stick.pieces(g, { rect = place.envelope, du = place.base.du }, "right",
        target or "desk", prefix or "desk", budget, false)
end

local function shapes(ctx, g, budget: number?)
    if not g.frame then
        local items = {}
        for _, panel in drawer.panels(ctx, g) do
            local place = { rect = { x = panel.x, y = panel.y, w = panel.w, h = panel.h }, du = panel.cu }
            for _, side in (if panel.held then stick.sides elseif panel.side then { panel.side } else {}) do
                append(items, stick.pieces(g, place, side, "drawer-content-" .. panel.id, panel.id .. "-window",
                    math.max(0, (budget or 42) - #items), true, not panel.held))
            end
        end
        return items
    end
    local limit = budget or 8
    local items = {}
    if ctx.state.expanded and limit > 0 then
        local place = desk.geometry(ctx, g)
        items[1] = plate(g, place)
        append(items, edge(g, place, limit - 1))
    end
    append(items, mediacard.shapes(ctx, g, math.max(0, limit - #items)))
    return items
end

local function content(ctx, g)
    if not g.frame then return nil end
    local items = {}
    if ctx.state.expanded then items[1] = desk.render(ctx, desk.geometry(ctx, g)) end
    append(items, mediacard.content(ctx, g))
    return items
end

return table.freeze({ shapes = shapes, content = content, edge = edge })
