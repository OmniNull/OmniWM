-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("./kit")
local palette = require("./palette")
local drawers = require("./drawers")
local frame = require("./frame")
local windows = require("./windows")
local stick = require("./stick")
local cards = require("./cards")

local drip = kit.springs.drip
local hang = table.freeze({ response = 2 * math.pi / math.sqrt(260), bounce = 1 - 32 / (2 * math.sqrt(260)) })
local splash = table.freeze({ response = 2 * math.pi / math.sqrt(420), bounce = 1 - 13 / (2 * math.sqrt(420)) })
local islandClose = 0.08
local stops = table.freeze({ 0, 0.0625, 0.125, 0.1875, 0.25, 0.3125, 0.375, 0.4375,
    0.5, 0.5625, 0.625, 0.6875, 0.8125, 0.90625, 1, 1.5 })
local views = setmetatable({}, { __mode = "k" })
local sizes = table.freeze({ calendar = { w = 450, h = 373 }, controls = { w = 312, h = 300 }, player = { w = 328, h = 168 } })

local function sample(spring, motion, time: number): (number, number)
    if not motion then return 0, 0 end
    if motion.before and time < motion.begin then return sample(spring, motion.before, time) end
    return kit.springState(spring, motion.from, motion.velocity, time - motion.begin, motion.target)
end

local function motion(spring, previous, time: number, target: number, delay: number?)
    local from, velocity = sample(spring, previous, time)
    if delay and delay > 0 then
        local closing = { from = from, velocity = velocity, target = 0, begin = time }
        from, velocity = sample(spring, closing, time + delay)
        return { from = from, velocity = velocity, target = target, begin = time + delay, before = closing }
    end
    return { from = from, velocity = velocity, target = target, begin = time }
end

local function drop(state, time: number): (number, number)
    return sample(drip, state.drawerDrop, time)
end

local function landingTime(state): number?
    local landing = state.drawerDrop
    if not landing or landing.target ~= 1 then return nil end
    local crossing = kit.springCrossing(drip, landing.from, landing.velocity, 1, 0.97, true)
    return crossing and landing.begin + crossing
end

local function travelTime(state): number?
    local travel = state.drawerTravel
    if not travel or travel.target ~= 1 then return nil end
    local crossing = kit.springCrossing(kit.springs.dripl, travel.from, travel.velocity, 1, 1.14 / 1.3, true)
    return crossing and travel.begin + crossing
end

local function settle(ctx, timed: boolean, now: number)
    local held = ctx.state.drawerSettle
    if held and held.timer then held.timer:cancel() end
    ctx.state.drawerSettle = nil
    if not timed then return end
    local travel = ctx.state.drawerTravel
    local last = math.max(travel and travel.begin or now, landingTime(ctx.state) or now, travelTime(ctx.state) or now)
    if last <= now then return end
    local entry = {}
    entry.timer = omniwm.after(math.max(0.01, last - now), function()
        if ctx.state.drawerSettle == entry then ctx.state.drawerSettle = nil end
    end)
    ctx.state.drawerSettle = entry
end

local function select(ctx, name: string?, preserve: boolean?)
    local previous = ctx.state.drawerPanel
    if previous == name then return end
    local outgoing = drawers[previous or ""]
    if outgoing and outgoing.deactivate then outgoing.deactivate(ctx) end
    windows.dismiss(ctx, previous)
    local now = os.clock()
    local progress, velocity = drop(ctx.state, now)
    local target = if name then 1 else 0
    local framed = frame.framed(ctx.data.settings)
    local delay = 0
    if framed then
        local travel = ctx.state.drawerTravel
        if not travel and previous then travel = { from = 1, velocity = 0, target = 1, begin = now } end
        if previous and name then
            local position, speed = sample(kit.springs.dripl, travel, now)
            if position >= 0.5 then
                delay = kit.springCrossing(kit.springs.dripl, position, speed, 0, 0.5, false) or 0
            end
            ctx.state.drawerPreviousFrame = ctx.state.drawerFrameGeometry
        end
        ctx.state.drawerTravel = motion(kit.springs.dripl, travel, now, target, delay)
        ctx.state.drawerDrop = motion(drip, ctx.state.drawerDrop, now, target, delay)
        ctx.state.drawerDelay = delay
    elseif (previous == nil) ~= (name == nil) then
        ctx.state.drawerDrop = { from = progress, velocity = velocity, target = target, begin = now }
    end
    ctx.state.drawerPanel = name
    ctx.state.drawerRest = previous == nil or (framed and name ~= nil)
    ctx.state.drawerLanding = if name and ctx.state.drawerRest then
        delay + (kit.springCrossing(drip, ctx.state.drawerDrop.from, ctx.state.drawerDrop.velocity, 1, 0.97, true) or 0)
        else nil
    if not framed then ctx.state.drawerDelay = 0 end
    settle(ctx, framed and name ~= nil, now)
    if name == "calendar" and not preserve then
        omniwm.run("calendar month today")
        omniwm.run("calendar day " .. os.date("%Y-%m-%d", ctx.data.seconds))
        ctx.state.calendarEntry = (ctx.state.calendarEntry or 0) + 1
        ctx.state.calendarDraft = nil
        ctx.state.calendarNote = nil
    end
end

local function open(ctx, name)
    select(ctx, name, true)
    if ctx.data.bar then omniwm.run("shell trigger vitreus drawer-selected " .. ctx.data.bar.monitorId) end
end

local function close(ctx)
    select(ctx, nil)
end

local function trigger(ctx, event)
    local name = event.name
    if name == "drawer-close" then
        if event.value == nil or event.value == (ctx.data.bar and ctx.data.bar.monitorId) then close(ctx) end
        return
    end
    if name == "drawer-selected" then
        if event.value ~= (ctx.data.bar and ctx.data.bar.monitorId) then close(ctx) end
        return
    end
    local panel = string.match(name or "", "^drawer%-(%a+)$")
    if not drawers[panel or ""] then return end
    local target = event.value
    if type(target) ~= "string" or not string.match(target, "^display:%d+$") then return end
    if target ~= (ctx.data.bar and ctx.data.bar.monitorId) then close(ctx) return end
    if windows.detached(ctx, panel) or (not frame.framed(ctx.data.settings) and cards.anyOut(ctx, panel)) then
        cards.redock(ctx, panel)
        windows.redock(ctx, panel)
        select(ctx, panel, true)
        return
    end
    local nextPanel = if ctx.state.drawerPanel == panel then nil else panel
    select(ctx, nextPanel)
    if nextPanel then omniwm.run("shell trigger vitreus drawer-selected " .. target) end
end

local function frameGeometry(ctx, g, name, width, height)
    local f, cu = g.frame, g.k.bcu
    local travel = ctx.state.drawerTravel
    local thickness = f.thickness
    local slot = g.pill.slots[if name == "calendar" then "clock" elseif name == "player" then "title" else "controls"]
    local strip = if slot and slot.piece then slot.piece.strip else f.strip
    local up = strip.reach or 0
    local buttonX, buttonY = if slot then slot.cx else strip.cx, if slot then slot.cy else strip.cy
    local padding = (if name == "controls" then 13 elseif name == "calendar" then 6 else 0) * cu
    local inset = (if name == "controls" then 6.5 elseif name == "calendar" then -0.5 else 0) * cu
    local x, y, bx, by, bw, bh, ax, ay, originX, originY, slideX, slideY
    if f.vertical then
        local low = thickness + 24 * g.k.u + (height + padding) / 2
        local high = g.size.h - thickness - (height + padding) / 2
            - (if name == "player" then 24 * g.k.u else 0)
        local centre = math.clamp(buttonY, low, math.max(low, high))
        local reach = if name == "controls" or name == "calendar" then
            14 * g.k.u * math.clamp((centre + (height + padding) / 2
                - (g.size.h - thickness - 14 * g.k.u)) / (14 * g.k.u), 0, 1) else 0
        x = if f.edge == "right" then strip.x - 6.5 * cu - width else strip.x + strip.w + 6.5 * cu
        y = centre - (height + padding) / 2 + inset
        bw = strip.w / 2 + width + 13 * cu
        if name == "controls" or name == "calendar" then
            bw += 14 * g.k.u * math.clamp((strip.w + width + 13 * cu
                - (g.size.w - thickness - 14 * g.k.u)) / (14 * g.k.u), 0, 1)
        end
        bh = height + padding + reach
        bx = if f.edge == "right" then strip.cx - bw else strip.cx
        by = centre - (height + padding) / 2
        ax, ay = if f.edge == "right" then 1 else 0, (centre - by) / bh
        originX, originY = strip.cx, centre
        slideX, slideY = 0, if name == "controls" then buttonY - centre else 0
    else
        if name == "player" then padding, inset = 13 * cu, 6.5 * cu end
        local centred = name == "player" or (name == "calendar" and f.seg)
        local centre = if centred then g.size.w / 2
            else g.size.w - thickness - 6.5 * cu - width / 2
        x = centre - width / 2
        local reach = if name == "controls" or (name == "calendar" and not centred) then 14 * g.k.u else 0
        bw = width + (if name == "player" then 0 else 13 * cu) + reach
        bh = strip.h / 2 + height + padding + up
        bx = if name == "player" then x else x - 6.5 * cu
        by = if f.edge == "fbottom" then strip.cy - bh else strip.cy - up
        y = if f.edge == "fbottom" then strip.y - height - inset else strip.y + strip.h + inset
        ax, ay = (centre - bx) / bw, if f.edge == "fbottom" then 1 else 0
        originX, originY = centre, strip.cy
        slideX, slideY = if name == "controls" then buttonX - centre else 0, 0
    end
    return {
        id = name, w = width, h = height, cu = cu, rs = cu / 1.5525, x = x, y = y,
        top = by, bodyW = bw, bodyH = bh, bodyX = bx, bodyY = by,
        anchor = { x = ax, y = ay }, originX = originX, originY = originY,
        slideX = slideX, slideY = slideY, frame = true, vertical = f.vertical, edge = f.edge,
        tail = f.seg == true and name == "controls", close = close, calm = g.calm, delay = ctx.state.drawerDelay or 0,
        wait = if ctx.state.drawerSettle and travel then math.max(0, travel.begin - os.clock()) else 0,
        key = "drawer-frame-" .. name,
    }
end

local function homeGeometry(ctx, g, given)
    local name = given or ctx.state.drawerPanel
    local size = sizes[name or ""]
    if not size or not g.pill then return nil end
    local view = views[ctx.state]
    if view and view.g == g and view.homes[name] then return view.homes[name] end
    local cu = g.k.bcu
    local module = drawers[name]
    local width = size.w * cu
    local height = (if module.height then module.height(ctx) else size.h) * cu
    if g.frame then return frameGeometry(ctx, g, name, width, height) end
    local header = if name == "player" or name == "controls" then 14 * cu else 0
    height += header
    local panel = {
        id = name, w = width, h = height, cu = cu, rs = cu / 1.5525,
        x = g.pill.x + g.pill.w / 2 - width / 2, y = g.pill.y + g.pill.h,
        top = g.pill.cy, bodyH = g.pill.h / 2 + height, close = close, calm = g.calm,
        header = header, dismiss = close,
    }
    if view and view.g == g then view.homes[name] = panel end
    return panel
end

local function shelfGeometry(ctx, g)
    if g.frame or not ctx.data.island or ctx.data.island.drawer ~= "shelf" then return nil end
    local view = views[ctx.state]
    if view and view.g == g and view.measured then return view.storage end
    local panels = {}
    for _, id in windows.order do
        if windows.stored(ctx, id) then panels[#panels + 1] = homeGeometry(ctx, g, id) end
    end
    for _, card in cards.measures(ctx) do panels[#panels + 1] = card end
    local storage = windows.shelf(ctx, g, panels)
    if view and view.g == g then view.storage, view.measured = storage, true end
    return storage
end

local function geometry(ctx, g, given)
    local panel = homeGeometry(ctx, g, given)
    if not panel or g.frame then return panel end
    return windows.geometry(ctx, panel.id, panel, g, shelfGeometry(ctx, g))
end

local function panels(ctx, g)
    local items = {}
    if g.frame then
        local panel = geometry(ctx, g)
        if panel then items[1] = panel end
        return items
    end
    for _, id in windows.order do
        if windows.visible(ctx, id) then items[#items + 1] = geometry(ctx, g, id) end
    end
    return items
end

local function prepare(ctx, g)
    cards.reset(ctx, g)
    views[ctx.state] = { g = g, homes = {} }
    if g.frame then return end
    local active = {}
    for _, id in windows.order do
        if windows.visible(ctx, id) or cards.anyOut(ctx, id, true) then
            active[id] = true
            local home = homeGeometry(ctx, g, id)
            local module = drawers[id]
            if home and module.sections then cards.add(ctx, id, module.sections(ctx, home)) end
            if home and id == "player" then cards.add(ctx, id, { require("./mediacard").section(ctx, g, home) }) end
        end
    end
    local pages = 0
    for _, entry in ctx.data.components or {} do
        if entry.enabled and not entry.error and (entry.widget == "desk-pad" or entry.widget == "desk-focus")
            and ((ctx.data.island and ctx.data.island.drawer == "shelf") or cards.onShelf(ctx, entry.id)) then
            pages += 1
            if pages > 10 then continue end
            local id = "page-" .. entry.id
            cards.add(ctx, "pages", { { id = id, page = true, x = 0, y = 0, w = 340, h = 360,
                content = function(_, p)
                    return { ui.stack({ key = "shelf-page-" .. entry.id, align = "topLeading", dy = -80 * p.cu,
                        w = p.w, h = 460 * p.cu,
                        ui.component({ id = entry.id, view = "desk", w = p.w, h = 460 * p.cu,
                            props = { du = p.cu, rs = p.rs, u = p.cu * 1.35 / 1.5525, reveal = false } }),
                    }) }
                end } })
        end
    end
    local parents = {}
    for id in active do
        local shown = windows.visible(ctx, id)
        local p = if shown or windows.detached(ctx, id) then geometry(ctx, g, id) else homeGeometry(ctx, g, id)
        if p then p.visible = shown parents[id] = p end
    end
    cards.layout(ctx, shelfGeometry(ctx, g), parents)
end

local function shapeMorph(ctx, panel)
    local values = {}
    for _, progress in stops do
        local lf = math.min(1, 1.6 * progress) + 0.6 * math.max(0, progress - 1)
        local q = math.min(1, progress)
        local bell = 4 * q * (1 - q)
        values[#values + 1] = { at = progress, scale = lf, w = 1 - 0.07 * bell,
            round = math.clamp(1.6 * progress - 0.1, 0, 1) }
    end
    local impulses = {
        { at = islandClose, rising = false, on = "close", spring = splash, velocity = 90,
            w = 0.003 * panel.w, h = -0.002 * panel.bodyH, pivot = "centre" },
    }
    if ctx.state.drawerLanding then
        local at = if ctx.state.drawerRest then 0.97 else nil
        local after = if at then nil else ctx.state.drawerLanding
        impulses[#impulses + 1] = { at = at, after = after, on = "open", spring = hang, velocity = 220, h = 1, pivot = "anchor" }
        impulses[#impulses + 1] = { at = at, after = after, on = "open", spring = splash, velocity = -260,
            w = 0.003 * panel.w, h = -0.002 * panel.bodyH, pivot = "centre" }
    end
    return { anchor = { x = 0.5, y = 0 }, stops = values, impulses = impulses }
end

local function frameImpulses(ctx, panel)
    local impulses = {}
    local function add(after, spring, velocity, width, height, pivot, phase)
        if not after or after < 0 then return end
        impulses[#impulses + 1] = { after = after, spring = spring, velocity = velocity,
            w = width, h = height, pivot = pivot, on = phase }
    end
    local function wobble(after, velocity, phase)
        if panel.tail then return end
        add(after, splash, velocity, 0.003 * panel.bodyW, -0.002 * panel.bodyH, "centre", phase)
    end
    if ctx.state.drawerSettle then
        local now = os.clock()
        local landed, travelled = landingTime(ctx.state), travelTime(ctx.state)
        add(landed and landed - now, hang, 220, 0, 1, "anchor", "open")
        wobble(landed and landed - now, -260, "open")
        wobble(travelled and travelled - now, -520, "open")
    end
    wobble(kit.springCrossing(kit.springs.dripl, 1, 0, 0, 1.14 / 1.3, false), 300, "close")
    wobble(kit.springCrossing(kit.springs.dripl, 1, 0, 0, 0.36 / 1.3, false), -160, "close")
    return impulses
end

local function frameMorph(ctx, panel)
    local values = {}
    for _, progress in stops do
        local lf = math.min(1, 1.6 * progress) + 0.6 * math.max(0, progress - 1)
        local q = math.min(1, progress)
        local tail = if panel.tail then math.clamp(16 * progress - 0.1, 0, 1) else 1
        values[#values + 1] = { at = progress, scale = lf, w = (1 - 0.07 * 4 * q * (1 - q)) * tail,
            h = if panel.tail then tail else nil, dx = panel.slideX * (1 - lf), dy = panel.slideY * (1 - lf),
            round = math.clamp(1.6 * progress - 0.1, 0, 1) }
    end
    local impulses = frameImpulses(ctx, panel)
    return { anchor = panel.anchor, stops = values, impulses = if #impulses > 0 then impulses else nil }
end

local function crestMorph(panel, g, phase, sign, trigger)
    local duration = if phase == "open" then 1.1 else 0.6
    local spring = { response = 2 * math.pi * duration / 6.64, bounce = 0 }
    local values = {}
    for _, time in { 0, 0.03, 0.06, 0.1, 0.15, 0.22, 0.32, 0.45, 0.6, 0.8, 1, 1.3, 1.7, 2.2, 3 } do
        local progress = kit.springState(spring, 0, 0, time, 1)
        local ripple = kit.springState(spring, 0, 0, math.max(0, time - 0.03), 1)
        local amplitude = if ripple < 0.98 then 20 * (1 - ripple) * math.clamp(6 * ripple, 0, 1) else 0
        local distance = sign * (12 + 90 * ripple) * g.k.u
        if progress < 0.99999 then
            values[#values + 1] = { at = progress, w = if panel.vertical then amplitude / 9 else 1,
                h = if panel.vertical then 1 else amplitude / 9,
                dx = if panel.vertical then 0 else distance, dy = if panel.vertical then distance else 0 }
        end
    end
    values[#values + 1] = { at = 1, w = if panel.vertical then 0 else 1, h = if panel.vertical then 1 else 0 }
    return { stops = values, trigger = trigger }, spring
end

local function appendCrests(items, panel, g, phase, trigger)
    if not panel or (g.frame and (panel.edge ~= g.frame.edge or g.frame.seg)) then return end
    local strip = if g.frame then g.frame.strip else g.pill
    local x = if panel.vertical then
        (if panel.edge == "right" then strip.x else strip.x + strip.w) else panel.originX
    local y = if panel.vertical then panel.originY
        else (if panel.edge == "fbottom" then strip.y else strip.y + strip.h)
    local bound = trigger or { shape = panel.key, at = if phase == "open" then 0.84 else 0.06, rising = phase == "open" }
    for _, sign in { -1, 1 } do
        local morph, spring = crestMorph(panel, g, phase, sign, bound)
        items[#items + 1] = ui.shape({ key = "drawer-ripple-" .. panel.id .. "-" .. phase .. "-" .. tostring(sign),
            shape = "ellipse", align = "topLeading", dx = x - 9 * g.k.u, dy = y - 9 * g.k.u,
            w = 18 * g.k.u, h = 18 * g.k.u, hit = false,
            reveal = { response = spring.response, bounce = 0, exit = false }, morph = morph,
        })
    end
end

local function islandShape(ctx, g, panel)
    local props = { key = panel.key,
        align = "topLeading", dx = panel.x, dy = panel.top, w = panel.w, h = panel.bodyH,
        radius = 26 * g.k.u, animate = g.calm, reveal = drip, morph = shapeMorph(ctx, panel) }
    if panel.window then
        if panel.loose then
            local source, reach = stick.source(g, "drawer-content-" .. panel.id, panel.cu, panel.side or "right", {})
            props.dx, props.dy = -reach, -reach
            props.w, props.h = g.size.w + 2 * reach, g.size.h + 2 * reach
            props.morph = { source = source, stops = { { at = 0 }, { at = 1 } } }
        else props.follow = "drawer-content-" .. panel.id end
    end
    return ui.shape(props)
end

local function shapes(ctx, g)
    prepare(ctx, g)
    if ctx.state.drawerLayout ~= g.layout then
        ctx.state.drawerLayout = g.layout
        ctx.state.drawerFrameGeometry = nil
        ctx.state.drawerPreviousFrame = nil
        ctx.state.drawerRing = nil
    end
    local panel = geometry(ctx, g)
    if g.frame then
        local items = {}
        if panel then
            ctx.state.drawerFrameGeometry = panel
            items[#items + 1] = ui.shape({ key = panel.key, align = "topLeading", dx = panel.bodyX, dy = panel.bodyY,
                w = panel.bodyW, h = panel.bodyH, radius = 26 * g.k.u, animate = g.calm,
                reveal = { response = drip.response, bounce = drip.bounce, delay = panel.delay },
                morph = frameMorph(ctx, panel),
            })
        end
        local current = panel or ctx.state.drawerFrameGeometry
        appendCrests(items, current, g, "open")
        appendCrests(items, current, g, "close")
        local previous = ctx.state.drawerPreviousFrame
        if not current or not previous or current.id ~= previous.id then appendCrests(items, previous, g, "close") end
        return items
    end
    local items = {}
    local storage = shelfGeometry(ctx, g)
    if storage then
        items[#items + 1] = ui.shape({ key = "window-shelf-glass", align = "topLeading",
            dx = storage.x, w = storage.w, h = storage.h, radius = 26 * g.k.u, reveal = drip,
            morph = { anchor = { x = 0.5, y = 0 }, stops = { { at = 0, h = 0.01 }, { at = 1 } } } })
    end
    local ring = if g.pill then ctx.state.drawerRing else nil
    for _, item in panels(ctx, g) do
        items[#items + 1] = islandShape(ctx, g, item)
        if not item.loose then ring = item.key end
    end
    if ring and not ctx.state.drawerPanel then
        appendCrests(items, { id = "island", key = ring, originX = g.pill.cx }, g, "close",
            { shape = ring, at = islandClose, rising = false })
    end
    ctx.state.drawerRing = ring
    return items
end

local function outline(g, w: number, h: number): string
    return kit.roundedRect(2, 2, w - 4, h - 4, math.max(0, 26 * g.k.u - 2))
end

local function delayAppearance(item, delay)
    if type(item) ~= "table" then return end
    if item.appear then
        local appear = table.clone(item.appear)
        appear.delay = (appear.delay or 0) + delay
        item.appear = appear
    end
    for _, child in item do
        if type(child) == "table" and child.kind then delayAppearance(child, delay) end
    end
end

local function contentMorph(ctx, panel, given)
    local rect = given or { x = panel.x, y = panel.y, w = panel.w, h = panel.h }
    local values = {}
    for _, progress in stops do
        local lf = math.min(1, 1.6 * progress) + 0.6 * math.max(0, progress - 1)
        if panel.frame then
            local cx, cy = panel.x + panel.w / 2, panel.y + panel.h / 2
            local rx, ry = rect.x + rect.w / 2, rect.y + rect.h / 2
            local scale = math.max(lf, 0.05)
            values[#values + 1] = { at = progress, scale = scale,
                opacity = if progress <= 0.02 then 0 else 1,
                dx = (panel.originX - cx + panel.slideX) * (1 - lf) + (cx - rx) * (1 - scale),
                dy = (panel.originY - cy + panel.slideY) * (1 - lf) + (cy - ry) * (1 - scale) }
        else
            local scale = math.max(lf, 0.05)
            values[#values + 1] = { at = progress, scale = scale,
                dx = (panel.x + panel.w / 2 - rect.x - rect.w / 2) * (1 - scale),
                dy = (panel.y - rect.y) * (1 - scale) - (if ctx.state.drawerRest then 125 * panel.cu * (1 - progress) else 0) }
        end
    end
    return { anchor = { x = 0.5, y = if panel.frame then 0.5 else 0 }, stops = values }
end

local function panelContent(ctx, g, panel)
    local items = drawers[panel.id].content(ctx, panel) or {}
    if panel.frame and panel.wait > 0 then
        for _, item in items do delayAppearance(item, panel.wait) end
    end
    local clipped = { key = "drawer-clip", w = panel.w, h = panel.h, align = "topLeading",
        morph = if panel.loose then nil else contentMorph(ctx, panel),
        ui.path({ key = "drawer-mask-" .. panel.id, mask = true, w = panel.w, h = panel.h,
            animate = if panel.frame or panel.loose then nil else g.calm, d = outline(g, panel.w, panel.h) }),
    }
    for _, item in items do clipped[#clipped + 1] = item end
    local children = { ui.stack(clipped) }
    if panel.window then
        for _, child in cards.nested(ctx, panel.id, if panel.loose then nil else function(rect) return contentMorph(ctx, panel, rect) end) do children[#children + 1] = child end
        children[#children + 1] = windows.grip(ctx, panel)
    end
    return ui.stack({ key = "drawer-content-" .. panel.id, w = panel.w, h = panel.h,
        align = "topLeading", dx = panel.x, dy = panel.y,
        animate = if not panel.frame and not panel.loose then g.calm else nil,
        reveal = if panel.frame then { response = drip.response, bounce = drip.bounce, delay = panel.delay } else drip,
        manipulationFollow = if panel.window then kit.springs.desk else nil,
        manipulationCommit = panel.commit,
        onOutsidePress = function(next, event)
            if not event.claimed and not panel.loose then close(next) end
        end,
        table.unpack(children),
    })
end

local function content(ctx, g)
    local items = {}
    local storage = shelfGeometry(ctx, g)
    if storage then
        local height = math.max(24, g.pill and g.pill.y + g.pill.h + 8 * g.k.u or 24)
        items[#items + 1] = ui.stack({ key = "window-shelf", align = "topLeading", dx = storage.x,
            w = storage.w, h = storage.h, reveal = drip, onPress = function() end,
            onOutsidePress = function(_, event) if not event.claimed then omniwm.run("shell toggle shelf") end end,
            ui.stack({ key = "window-shelf-content", w = storage.w, h = storage.h,
                morph = { anchor = { x = 0.5, y = 0 }, stops = { { at = 0, scale = 0.01, opacity = 0 }, { at = 1 } } },
                ui.text({ key = "window-shelf-hint", text = if storage.empty then "Drag a drop-down here to keep it" else "Drop-down shelf",
                    size = 14 * g.k.u, color = palette.roles.ink, align = "topLeading", dx = 20 * g.k.u, dy = height }),
                ui.stack({ key = "window-shelf-close", w = 44 * g.k.u, h = 24 * g.k.u,
                    align = "topLeading", dx = storage.w - 64 * g.k.u, dy = height - 4 * g.k.u,
                    cursor = "pointer", onClick = "shell toggle shelf",
                    ui.text({ text = "Close", size = 13 * g.k.u, color = palette.roles.ink }) }),
            }),
        })
    end
    for _, panel in panels(ctx, g) do items[#items + 1] = panelContent(ctx, g, panel) end
    return items
end

local function shadow(ctx)
    local amount = if ctx.state.drawerPanel then 1 else 0
    return palette.alpha("deep", 0.08 + 0.16 * amount), 6 + 14 * amount, { x = 0, y = 1 + 6 * amount }, drip
end

return table.freeze({
    open = open, shapes = shapes, content = content, trigger = trigger, shadow = shadow, geometry = geometry, outline = outline, contentMorph = contentMorph,
    panels = panels,
})
