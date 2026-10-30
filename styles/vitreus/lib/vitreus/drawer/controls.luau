-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local tiles = require("./controls-tiles")
local mixer = require("./controls-mixer")
local windows = require("./controls-windows")
local floating = require("../windows")
local cards = require("../cards")
local frame = require("../frame")

local function cancelHold(ctx)
    if ctx.state.controlsHoldTimer then ctx.state.controlsHoldTimer:cancel() end
    ctx.state.controlsHoldTimer = nil
    ctx.state.controlsHold = nil
end

local function deactivate(ctx)
    cancelHold(ctx)
    if ctx.state.controlsBurstTimer then ctx.state.controlsBurstTimer:cancel() end
    ctx.state.controlsBurstTimer = nil
    ctx.state.controlsBurst = nil
    if floating.detached(ctx, "controls") or cards.out(ctx, "controls-toggles") or cards.out(ctx, "controls-sliders") or cards.out(ctx, "controls-mixer") then return end
    ctx.state.controlsPanel = nil
    ctx.state.controlsMixer = false
    ctx.state.controlsOutputs = false
    ctx.state.controlsError = nil
end

local function open(ctx, name)
    cancelHold(ctx)
    ctx.state.controlsPanel = name
    if cards.out(ctx, "controls-mixer") then cards.home(ctx, "controls-mixer") end
    ctx.state.controlsMixer = false
    ctx.state.controlsOutputs = false
    ctx.state.controlsError = nil
    if name == "notifications" then omniwm.run("notifications refresh") end
end

local function toggle(ctx, name)
    if name == "caffeine" then
        omniwm.run("session awake " .. (if ctx.data.awake and ctx.data.awake.on then "off" else "on"))
    elseif name == "notifications" then omniwm.run("focus settings")
    elseif name == "capture" then omniwm.run("screenshot settings")
    elseif name == "wifi" or name == "bluetooth" then omniwm.run(name .. " settings")
    else open(ctx, name) end
end

local function hold(ctx, event, action)
    if event.phase ~= "down" then cancelHold(ctx) return end
    if event.button ~= "left" or ctx.state.controlsBurst then return end
    cancelHold(ctx)
    ctx.state.controlsSerial = (ctx.state.controlsSerial or 0) + 1
    local serial = ctx.state.controlsSerial
    ctx.state.controlsHold = { action = action, serial = serial }
    local timer, err = omniwm.after(1, function()
        local pending = ctx.state.controlsHold
        if not pending or pending.serial ~= serial then return end
        ctx.state.controlsHoldTimer = nil
        ctx.state.controlsHold = nil
        if not (floating.visible(ctx, "controls") or cards.out(ctx, "controls-toggles")) or ctx.state.controlsPanel ~= "power" then return end
        ctx.state.controlsBurst = { action = action, serial = serial }
        omniwm.run("session " .. action)
        local cleanup, cleanupError = omniwm.after(0.95, function()
            if ctx.state.controlsBurst and ctx.state.controlsBurst.serial == serial then
                ctx.state.controlsBurst = nil
                ctx.state.controlsBurstTimer = nil
            end
        end)
        ctx.state.controlsBurstTimer = cleanup
        if not cleanup then
            ctx.state.controlsBurst = nil
            ctx.state.controlsError = "Effect unavailable: " .. tostring(cleanupError)
        end
    end)
    ctx.state.controlsHoldTimer = timer
    if not timer then
        ctx.state.controlsHold = nil
        ctx.state.controlsError = "Hold unavailable: " .. tostring(err)
    end
end

local actions = table.freeze({ open = open, toggle = toggle, hold = hold })

local function height(ctx)
    if ctx.state.controlsPanel and not cards.out(ctx, "controls-toggles") then return windows.height(ctx) end
    local model = mixer.model(ctx)
    if frame.framed(ctx.data.settings) then return model.totalHeight end
    local tilesH = if cards.out(ctx, "controls-toggles") then 0 else 160
    local slidersH = if cards.out(ctx, "controls-sliders") then 0 else model.height + 16
    local mixerH = if model.mixer and not cards.out(ctx, "controls-mixer") and slidersH == 0
        then math.max(28, #model.apps * 32 - 4) + 16 else 0
    return math.max(22, tilesH + slidersH + mixerH)
end

local function content(ctx, p)
    if ctx.state.controlsPanel and not cards.out(ctx, "controls-toggles") then
        return { ui.stack({ w = p.w, h = p.h, align = "topLeading", dy = p.header or 0, windows.content(ctx, p, actions) }) }
    end
    local model = mixer.model(ctx)
    if p.frame then return { tiles.content(ctx, p, actions), mixer.content(ctx, p, model) } end
    local result = {}
    if not cards.out(ctx, "controls-toggles") then result[#result + 1] = cards.placeholder(p, "controls-toggles", 0, (p.header or 0) / p.cu, 312, 160) end
    if not cards.out(ctx, "controls-sliders") then result[#result + 1] = cards.placeholder(p, "controls-sliders", 0,
        (p.header or 0) / p.cu + (if cards.out(ctx, "controls-toggles") then 0 else model.top), 312, model.height + 16) end
    return result
end

local function sections(ctx, p)
    local model = mixer.model(ctx)
    local details = ctx.state.controlsPanel and not cards.out(ctx, "controls-toggles")
    local result = {}
    local header = (p.header or 0) / p.cu
    local top = header + (if cards.out(ctx, "controls-toggles") then 0 else model.top)
    if not details or cards.out(ctx, "controls-toggles") then
        result[#result + 1] = { id = "controls-toggles", x = 0, y = header, w = 312, gripY = if ctx.state.controlsPanel then 0 else 80, gripH = if ctx.state.controlsPanel then 10 else 4,
            h = if ctx.state.controlsPanel then windows.height(ctx) else 160,
            content = function(next, offer)
                return { if next.state.controlsPanel then windows.content(next, offer, actions) else tiles.content(next, offer, actions) }
            end }
    end
    if not details or cards.out(ctx, "controls-sliders") then
        result[#result + 1] = { id = "controls-sliders", x = 0, y = top, w = 312, h = model.height + 16,
            content = function(next, offer)
                local view = mixer.model(next)
                view.top = 0
                return { mixer.content(next, offer, view) }
            end }
    end
    if model.mixer or cards.out(ctx, "controls-mixer") then
        result[#result + 1] = { id = "controls-mixer", x = 12, y = top + (if cards.out(ctx, "controls-sliders") then 8 else 124 + (if model.bright then 0 else -40)),
            w = 288, h = math.max(28, #model.apps * 32 - 4),
            content = function(next, offer) return { mixer.appList(next, offer, mixer.model(next), 0) } end }
    end
    return result
end

return table.freeze({ height = height, content = content, deactivate = deactivate, sections = sections })
