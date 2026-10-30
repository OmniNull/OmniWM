local policy = require("./policy")
local attention = require("./attention")
local preferences = require("./preferences")
local motion = require("./motion")
local tracks = table.freeze({
    up = motion.swipe,
    down = table.freeze({ dy = table.freeze({ 0, 40, rubber = 0.4 }), scale = motion.swipe.scale, opacity = motion.swipe.opacity }),
    left = table.freeze({ dx = table.freeze({ 0, -40, rubber = 0.4 }), scale = motion.swipe.scale, opacity = motion.swipe.opacity }),
    right = table.freeze({ dx = table.freeze({ 0, 40, rubber = 0.4 }), scale = motion.swipe.scale, opacity = motion.swipe.opacity }),
})

local function mode(state)
    return if state.expanded then "expanded" else if state.peek then "peek" else "compact"
end

local function collapse(ctx)
    attention.dismiss(ctx.state)
    ctx.state.expanded = false
    ctx.state.peek = false
    ctx.state.settingsOpen = false
    ctx.state.motion = "mode"
end

local function toggle(ctx)
    attention.dismiss(ctx.state)
    ctx.state.expanded = not ctx.state.expanded
    ctx.state.peek = false
    ctx.state.motion = "mode"
end

local function hover(ctx, event)
    ctx.state.peek = event.phase == "began"
    if not ctx.state.expanded then ctx.state.motion = "mode" end
end

local function activate(ctx, target, current)
    if target == "none" then return end
    if target == "collapse" then collapse(ctx); return end
    if target == "toggle" then toggle(ctx); return end
    local id = preferences.targetID(ctx, target)
    if target ~= "expand" and target ~= "settings" and target ~= "next" and target ~= "previous" and not id then return end
    attention.dismiss(ctx.state)
    ctx.state.peek = false
    if target == "next" or target == "previous" then
        policy.step(ctx, if target == "next" then 1 else -1, current)
    else
        ctx.state.expanded = true
        ctx.state.settingsOpen = target == "settings"
        ctx.state.motion = if id then "promotion" else "mode"
        if id then ctx.state.primary = id; ctx.state.navigationPage = nil end
    end
end

local function swipe(ctx)
    if preferences.value(ctx, "swipeTarget") == "none" then return nil end
    local direction = preferences.value(ctx, "swipeDirection")
    return { axis = if direction == "left" or direction == "right" then "x" else "y",
        source = preferences.value(ctx, "swipeSource"), threshold = 6, lockDistance = 2, dominance = 1.3,
        commit = { distance = preferences.value(ctx, "swipeDistance"), velocity = 300, direction = direction },
        track = tracks[direction] }
end

local function gesture(ctx, event, current)
    if event.phase == "ended" and event.committed then activate(ctx, preferences.value(ctx, "swipeTarget"), current) end
end

local function key(ctx, event, current)
    if event.key == "escape" then collapse(ctx)
    elseif event.key == "left" then attention.dismiss(ctx.state); policy.step(ctx, -1, current)
    elseif event.key == "right" then attention.dismiss(ctx.state); policy.step(ctx, 1, current) end
end

return table.freeze({ mode = mode, collapse = collapse, toggle = toggle, hover = hover,
    gesture = gesture, key = key, activate = activate, swipe = swipe })
