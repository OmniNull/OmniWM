-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("./kit")
local palette = require("./palette")
local notches = require("./notches")
local layouts = table.freeze({ left = true, right = true, ftop = true, fbottom = true, seg = true })
local hold = table.freeze({ response = 2 * math.pi * 0.28 / 6.64, bounce = 0 })
local enterDelay = kit.springCrossing(hold, 0, 0, 1, 0.3, true)
local exitDelay = kit.springCrossing(hold, 1, 0, 0, 0.3, false)

local function framed(settings): boolean
    return layouts[(settings and settings.layout) or ""] == true
end

local function geometry(ctx, k, size, names, widths, place, metrics)
    local settings = ctx.data.settings or {}
    if not framed(settings) then return nil end
    local seg = settings.layout == "seg"
    local edge = if seg then "ftop" else settings.layout
    local vertical = edge == "left" or edge == "right"
    local enabled = ctx.data.bar and ctx.data.bar.style ~= nil
    local thin, width = 8 * k.u, if enabled then 46 * k.bu else 8 * k.u
    local strip = if vertical then
        { x = if edge == "right" then size.w - width else 0, y = 0, w = width, h = size.h }
        else { x = 0, y = if edge == "fbottom" then size.h - width else 0, w = size.w, h = width }
    strip.cx, strip.cy = strip.x + strip.w / 2, strip.y + strip.h / 2
    local inset = { left = thin, right = thin, top = thin, bottom = thin }
    if not seg then inset[({ left = "left", right = "right", ftop = "top", fbottom = "bottom" })[edge]] = width end
    local inner = { x = inset.left, y = inset.top, w = size.w - inset.left - inset.right,
        h = size.h - inset.top - inset.bottom }
    local blend, radius = (if seg then 28 else 26) * k.u, 25.27
    local thick = 2 * blend + width + 2 * radius
    local outer = { x = inner.x - thick, y = inner.y - thick, w = inner.w + 2 * thick, h = inner.h + 2 * thick }
    local result = { edge = edge, seg = seg, vertical = vertical, strip = strip, thickness = thin, width = width,
        inner = inner, outer = outer, outerRadius = radius + thick, frameThickness = thick, radius = radius,
        enabled = enabled, blend = blend }
    if not enabled then return table.freeze(result) end
    if seg then
        local layout = notches.geometry(k, size, widths, ctx.data.island)
        result.pieces, result.pill, result.strip = layout.pieces, layout.pill, layout.strip
        return table.freeze(result)
    end
    if not vertical then
        result.pill = place(k, size.w / 2, strip.y, names, widths, size.w - 24 * k.bu, width)
        return table.freeze(result)
    end
    local lv = { ws = thin + 88 * k.bcu, clk = size.h - thin - 73 * k.bu }
    lv.ctl, lv.set, lv.sr = lv.clk - 34 * k.bu, lv.clk - 66 * k.bu, lv.clk - 98 * k.bu
    local function above(y: number, name: string): number
        return if ((widths[name] or {}).w or 0) > 0 then y - 32 * k.bu else y
    end
    lv.app = above(lv.sr, "app")
    lv.apple = above(lv.app, "apple")
    local trayWidth = (widths.tray or widths.privacy or {}).w or 0
    lv.tray = lv.apple - 22 * k.bu - trayWidth
    lv.tt, lv.bot = lv.ws + 52 * k.bcu + 14 * k.bu, lv.tray - (if trayWidth > 0 then 14 * k.bu else 0)
    local titleOn = table.find(names, "title") ~= nil
    lv.mc = if titleOn and ctx.data.media then 62 * k.bcu else 0
    local textLength = if titleOn then math.max(metrics.cw, metrics.tw, if metrics.cw < 1 and metrics.tw < 1 then 44 * k.bcu else 0) else 0
    lv.span = math.clamp(textLength, 0, math.max(1, lv.bot - lv.tt - lv.mc))
    lv.y0 = math.clamp(size.h / 2 - (lv.span + lv.mc) / 2, lv.tt, math.max(lv.tt, lv.bot - lv.span - lv.mc))
    lv.mid, lv.tm = lv.y0 + 31 * k.bcu, lv.y0 + lv.mc + lv.span / 2
    local slots = {}
    for _, name in names do
        local y = if name == "clock" then lv.clk + 30 * k.bu elseif name == "controls" then lv.ctl
            elseif name == "omniwm" then lv.set elseif name == "search" then lv.sr
            elseif name == "apple" or name == "app" then lv[name]
            elseif name == "tray" or name == "privacy" then lv.tray + trayWidth / 2
            elseif name == "title" then lv.tm else lv.ws
        local h = if name == "clock" then 100 * k.bu elseif name == "title" then math.max(1, lv.span)
            elseif name == "tray" or name == "privacy" then trayWidth else 30 * k.bu
        slots[name] = { x = strip.x, y = y - h / 2, w = strip.w, h = h, cx = strip.cx, cy = y }
    end
    result.lv = table.freeze(lv)
    result.pill = table.freeze({ x = strip.x, y = 0, w = strip.w, h = strip.h, cx = strip.cx, cy = strip.cy,
        radius = 14 * k.bu, gap = 12 * k.bu, left = strip.x, right = strip.x + strip.w, slots = table.freeze(slots) })
    return table.freeze(result)
end

local function tabs(ctx, g)
    local f = g.frame
    if not f or not f.enabled then return {} end
    local result = {}
    local thin, reach, length = f.thickness, 15 * g.k.cu, 52 * g.k.cu
    local cx = f.inner.x + f.inner.w / 2
    local cy = f.inner.y + f.inner.h / 2 + (if f.seg then (f.width - f.thickness) / 2 else 0)
    local function add(name, side, action)
        local vertical = side == "left" or side == "right"
        local r = { name = name, side = side, action = action, vertical = vertical }
        r.w, r.h = if vertical then thin + reach else length, if vertical then length else thin + reach
        r.x = if side == "right" then g.size.w - r.w elseif side == "left" then 0 else cx - r.w / 2
        r.y = if side == "bottom" then g.size.h - r.h elseif side == "top" then 0 else cy - r.h / 2
        r.ax, r.ay = if side == "left" then 0 elseif side == "right" then 1 else 0.5,
            if side == "top" then 0 elseif side == "bottom" then 1 else 0.5
        result[#result + 1] = r
    end
    if f.vertical then
        add("top", "top", "open-command-palette")
    else add("left", "left", "open-command-palette") end
    add("bottom", if f.edge == "fbottom" then "top" else "bottom", "shell menu")
    if not ctx.state.expanded then
        add("right", if f.edge == "right" then "left" else "right",
            "shell trigger vitreus desk-open " .. ctx.data.bar.monitorId)
    end
    return result
end

local function shapes(ctx, g)
    local f = g.frame
    if not f then return nil end
    local rect = f.outer
    local result = { ui.shape({ key = "frame", shape = "frame", align = "topLeading",
        dx = rect.x, dy = rect.y, w = rect.w, h = rect.h, radius = f.outerRadius,
        thickness = f.frameThickness, animate = g.calm, reveal = g.calm,
        morph = { stops = { { at = 0, thickness = 0.001 }, { at = 1, thickness = 1 } } },
    }) }
    for _, tab in tabs(ctx, g) do
        if (ctx.state.frameTabs or {})[tab.name] then
            result[#result + 1] = ui.shape({ key = "frame-tab-" .. tab.name, align = "topLeading",
                dx = tab.x, dy = tab.y, w = tab.w, h = tab.h, radius = 9 * g.k.cu,
                reveal = { response = g.calm.response, bounce = g.calm.bounce, delay = enterDelay, hold = exitDelay },
                morph = { anchor = { x = tab.ax, y = tab.ay }, stops = {
                    { at = 0, w = if tab.vertical then f.thickness / tab.w else 1,
                        h = if tab.vertical then 1 else f.thickness / tab.h },
                    { at = 1, w = 1, h = 1 },
                } },
            })
        end
    end
    return result
end

local function content(ctx, g)
    local f = g.frame
    if not f or not f.enabled then return nil end
    local items = {}
    for _, tab in tabs(ctx, g) do
        local active = (ctx.state.frameTabs or {})[tab.name] == true
        local depth = if active then 15 * g.k.cu else 6 * g.k.cu
        local width = if tab.vertical then f.thickness + depth else tab.w + 24 * g.k.cu
        local height = if tab.vertical then tab.h + 24 * g.k.cu else f.thickness + depth
        local x = if tab.side == "right" then g.size.w - width elseif tab.vertical then 0 else tab.x + tab.w / 2 - width / 2
        local y = if tab.side == "bottom" then g.size.h - height elseif not tab.vertical then 0 else tab.y + tab.h / 2 - height / 2
        local hover = { key = "frame-hover-" .. tab.name, align = "topLeading",
            dx = x, dy = y, w = width, h = height,
            onHover = function(next, event)
                local values = next.state.frameTabs or {}
                values[tab.name] = event.phase == "began"
                next.state.frameTabs = values
            end,
        }
        if active then
            local c = kit.canvas(tab.w, tab.h, g.k.cu, g.k.rs)
            local dots = { key = "frame-hit-" .. tab.name, w = tab.w, h = tab.h,
                align = "topLeading", cursor = "pointer", onClick = tab.action,
                morph = { anchor = { x = tab.ax, y = tab.ay }, stops = {
                    { at = 0, scale = 0.05, opacity = 0 },
                    { at = 0.02, scale = 0.05, opacity = 0 },
                    { at = 0.0201, scale = 0.05 },
                    { at = 1 },
                } },
            }
            for index = -1, 1 do
                dots[#dots + 1] = ui.box(kit.at(c, { decorative = true, w = 3.2 * g.k.cu,
                    h = 3.2 * g.k.cu, radius = 1.6 * g.k.cu, fill = palette.alpha("ink", 0.5) },
                    c.w / 2 + (if tab.vertical then 0 else index * 6.5 * g.k.cu),
                    c.h / 2 + (if tab.vertical then index * 6.5 * g.k.cu else 0)))
            end
            hover[#hover + 1] = ui.stack({ key = "frame-button-reveal-" .. tab.name,
                w = tab.w, h = tab.h, align = "topLeading", dx = tab.x - x, dy = tab.y - y,
                reveal = { response = g.calm.response, bounce = g.calm.bounce, delay = enterDelay, hold = exitDelay },
                ui.stack(dots),
            })
        end
        items[#items + 1] = ui.stack(hover)
    end
    return items
end

return table.freeze({ framed = framed, geometry = geometry, shapes = shapes, content = content,
    enterDelay = enterDelay, exitDelay = exitDelay })
