local policy = require("../lib/lake/policy")
local slots = require("../lib/lake/slots")
local motion = require("../lib/lake/motion")
local intent = require("../lib/lake/intent")
local settings = require("../lib/lake/settings")
local preferences = require("../lib/lake/preferences")
local attention = require("../lib/lake/attention")

interval = 1

local function choose(ctx, id)
    attention.dismiss(ctx.state)
    ctx.state.primary = id
    ctx.state.navigationPage = nil
    ctx.state.motion = "promotion"
end

local function openSettings(ctx)
    intent.activate(ctx, "settings")
end

local function closeSettings(ctx)
    ctx.state.settingsOpen = false
end

function render(ctx)
    local island = ctx.data.island
    if island and ctx.state.settingsOpen then return settings.render(ctx, island, closeSettings) end
    local entries = policy.select(ctx)
    if not island then
        local row = { gap = 8 }
        for _, entry in entries do
            row[#row + 1] = ui.component{ id = entry.id, view = preferences.view(ctx, entry.widget, "compact") }
        end
        return ui.row(row)
    end
    local attentionID, attentionMode, accepts = attention.update(ctx, entries)
    local mode = attentionMode or intent.mode(ctx.state)
    local expanded = mode == "expanded"
    local geometry = slots.geometry(island, mode, preferences.value(ctx, "width"))
    local tree = { w = island.size.w, h = island.size.h, align = "top" }
    local panel
    local primaryEntry, secondaryEntry = policy.placed(entries, expanded)
    if attentionID then
        for _, entry in entries do if entry.id == attentionID then primaryEntry = entry; break end end
        if secondaryEntry == primaryEntry then secondaryEntry = nil end
    end
    local peeking = mode == "peek" and primaryEntry and preferences.hasView(ctx, primaryEntry.widget, "peek")
    for index, entry in { primaryEntry, secondaryEntry } do
        local primary = index == 1
        local component = ui.component{ id = entry.id,
            view = preferences.view(ctx, entry.widget, if primary and expanded then "expanded" else if primary and peeking then "peek" else "compact"),
            w = if primary then geometry.width else 80, h = if primary then geometry.height else 32,
            align = "top", dx = if primary then 0 else geometry.secondaryX,
            fill = if preferences.value(ctx, "appearance") == "solid" then preferences.color(ctx, "backgroundColor") else nil,
            material = if preferences.value(ctx, "appearance") == "translucent" then "ultraThin" else nil,
            radius = if primary and expanded then preferences.value(ctx, "radius") else 16, color = "#ffffff",
            accepts = if primary and #accepts > 0 then accepts else nil,
            onDropHover = if primary and #accepts > 0 then function() end else nil,
            animate = if ctx.state.motion == "promotion" then motion.promotion
                else if expanded then preferences.expandedMotion(ctx) else motion.shape[mode],
            pressScale = if primary then 0.99 else 0.96, pressAnimate = motion.feedback,
            hoverDelay = preferences.value(ctx, "hoverDelay"), hoverGrace = preferences.value(ctx, "hoverGrace"),
            onHover = if primary and preferences.value(ctx, "hoverPreview") then intent.hover else nil,
            focusable = primary, focusRing = false,
            keys = if primary then { "left", "right", "escape" } else nil,
            onKey = if primary then function(root, event) intent.key(root, event, entry.id) end else nil,
            onOutsidePress = if primary and expanded then intent.collapse else nil,
            gesture = if primary and expanded then intent.swipe(ctx) else nil,
            onGesture = if primary and expanded and preferences.value(ctx, "swipeTarget") ~= "none" then
                function(root, event) intent.gesture(root, event, entry.id) end else nil,
            props = { notchGap = if primary and not expanded then geometry.gap else 0,
                top = if primary and expanded then geometry.top + 46 else if primary and peeking then geometry.compactHeight else 0, secondary = not primary },
            onClick = if primary and preferences.value(ctx, "clickTarget") == "none" then nil else function(root)
                if primary then intent.activate(root, preferences.value(root, "clickTarget"), entry.id) else choose(root, entry.id) end
            end, onRightClick = if primary and preferences.value(ctx, "rightClickTarget") ~= "none" then function(root)
                intent.activate(root, preferences.value(root, "rightClickTarget"), entry.id)
            end else nil }
        local content = rawget(component, 1)
        if content and rawget(content, "mask") ~= true then
            if rawget(content, "appear") == nil then rawset(content, "appear", motion.appear) end
            if rawget(content, "exit") == nil then rawset(content, "exit", motion.exit) end
        end
        if primary then panel = component end
        tree[#tree + 1] = component
    end
    if not panel then
        tree[#tree + 1] = ui.box{ w = geometry.width, h = 32, fill = preferences.color(ctx, "backgroundColor"), radius = 16, align = "top",
            onClick = openSettings, onRightClick = openSettings, pressScale = 0.98,
            ui.text{ text = "Customize island", size = 11, color = "#a1a1aa" } }
    elseif mode == "peek" and not peeking then
        panel[#panel + 1] = ui.text{ key = "preview", text = primaryEntry.label or primaryEntry.title,
            size = 12, color = "#d4d4d8", maxWidth = math.max(1, geometry.width - 28),
            align = "top", dy = geometry.compactHeight + 10, animate = motion.content,
            appear = motion.appear, exit = motion.exit }
    elseif expanded then
        local tabs = { key = "navigation", gap = 4, pad = 4, align = "top", dy = geometry.top + 5,
            appear = motion.appear, exit = motion.exit }
        local pageSize = 3
        local selectedIndex = 1
        for index, entry in entries do if entry.id == primaryEntry.id then selectedIndex = index; break end end
        local pages = math.max(1, math.ceil(#entries / pageSize))
        local page = math.clamp(ctx.state.navigationPage or math.ceil(selectedIndex / pageSize), 1, pages)
        if pages > 1 then
            tabs[#tabs + 1] = ui.box{ key = "previous-page", w = 24, h = 28, radius = 9, hover = "#ffffff18",
                onClick = function(root) root.state.navigationPage = (page - 2) % pages + 1 end,
                ui.symbol{ name = "chevron.left", size = 11, color = "#a1a1aa" } }
        end
        for index = (page - 1) * pageSize + 1, math.min(page * pageSize, #entries) do
            local entry = entries[index]
            local selected = entry.id == primaryEntry.id
            tabs[#tabs + 1] = ui.box{ key = entry.id, pad = 7, radius = 9,
                fill = if selected then preferences.color(ctx, "highlightColor") else nil, hover = "#ffffff18",
                pressScale = 0.96, pressFill = "#ffffff30", pressAnimate = motion.feedback,
                onClick = function(root) choose(root, entry.id) end,
                ui.text{ text = entry.title, size = 10, maxWidth = math.max(40, (geometry.width - 212) / pageSize), color = if selected then "#ffffff" else "#a1a1aa" } }
        end
        if pages > 1 then
            tabs[#tabs + 1] = ui.box{ key = "next-page", w = 24, h = 28, radius = 9, hover = "#ffffff18",
                onClick = function(root) root.state.navigationPage = page % pages + 1 end,
                ui.symbol{ name = "chevron.right", size = 11, color = "#a1a1aa" } }
        end
        tabs[#tabs + 1] = ui.box{ key = "settings", w = 87, h = 28, radius = 9, fill = "#ffffff16", hover = "#ffffff24",
            pressScale = 0.94, pressAnimate = motion.feedback, onClick = openSettings, help = "Add and customize island widgets",
            ui.row{ gap = 5, ui.symbol{ name = "slider.horizontal.3", size = 12, color = "#ffffff" },
                ui.text{ text = "Widgets", size = 11, weight = "semibold", color = "#ffffff" } } }
        panel[#panel + 1] = ui.row(tabs)
    end
    return ui.stack(tree)
end

function trigger(ctx, event)
    if ctx.data.island and event.name == "settings" then openSettings(ctx) end
end
