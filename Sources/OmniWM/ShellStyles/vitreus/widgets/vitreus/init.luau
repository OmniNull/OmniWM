-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local bar = require("../lib/vitreus/bar")
local desk = require("../lib/vitreus/desk")
local panes = require("../lib/vitreus/panes")

local unnamed = false

local function display(ctx)
    return ctx.data.bar and ctx.data.bar.monitorId
end

local function expand(ctx, open: boolean)
    if open and not ctx.state.expanded then ctx.state.reveal = true end
    if not open then
        ctx.state.place = nil
        ctx.state.gripHeld = nil
    end
    ctx.state.expanded = open
end

local function append(tree, items)
    for _, item in items or {} do
        tree[#tree + 1] = item
    end
end

function render(ctx)
    local island = ctx.data.island
    if not island then return desk.opener(ctx) end
    local g = bar.geometry(ctx, island)
    local tree = { w = island.size.w, h = island.size.h, align = "topLeading" }
    append(tree, bar.render(ctx, g))
    local shelf, front = bar.overlay(ctx, g)
    append(tree, shelf)
    if g.opener then tree[#tree + 1] = desk.opener(ctx, g.opener) end
    append(tree, panes.render(ctx, g))
    append(tree, front)
    return ui.stack(tree)
end

function trigger(ctx, event)
    if event.source == "host" then return end
    local name, target = event.name, event.value
    if name == "desk-close" then
        if target == nil or target == display(ctx) then expand(ctx, false) end
        return
    end
    if name ~= "desk-open" and name ~= "desk" then
        bar.trigger(ctx, event)
        return
    end
    if type(target) ~= "string" or not string.match(target, "^display:%d+$") then
        if not unnamed then
            unnamed = true
            omniwm.log("vitreus: " .. name .. " needs a display ID")
        end
        return
    end
    if target ~= display(ctx) then
        expand(ctx, false)
    elseif name == "desk-open" then
        expand(ctx, true)
    else
        expand(ctx, not ctx.state.expanded)
    end
end
