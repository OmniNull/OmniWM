local defaults = table.freeze({ appearance = "solid", width = 520, radius = 28, hoverPreview = true, hoverDelay = 0.16,
    hoverGrace = 0.12, springResponse = 0.38, springBounce = 0.18,
    backgroundColor = "#000000", highlightColor = "#ffffff22", clickTarget = "toggle", rightClickTarget = "settings",
    swipeTarget = "collapse", swipeDirection = "up", swipeSource = "both", swipeDistance = 40 })
local targets = table.freeze({ "toggle", "expand", "collapse", "settings", "next", "previous", "none" })
local regions = table.freeze({ "auto", "main", "side", "expanded" })

local function value(ctx, key)
    local settings = ctx.data.settings
    local result = settings and settings[key]
    return if result == nil then defaults[key] else result
end

local function validColor(text)
    return type(text) == "string" and (#text == 7 or #text == 9) and string.match(text, "^#%x+$") ~= nil
end

local function color(ctx, key)
    local text = value(ctx, key)
    return if validColor(text) then text else defaults[key]
end

local function targetID(ctx, target)
    local id = type(target) == "string" and string.match(target, "^component:(.+)$")
    if not id then return nil end
    for _, component in ctx.data.components or {} do
        if component.id == id and component.enabled then return id end
    end
    return nil
end

local function validate(ctx, key, value)
    if key == "backgroundColor" or key == "highlightColor" then
        if not validColor(value) then return "Use #RRGGBB or #RRGGBBAA for this color." end
    elseif key == "clickTarget" or key == "rightClickTarget" or key == "swipeTarget" then
        if not table.find(targets, value) and not targetID(ctx, value) then
            return "Choose toggle, expand, collapse, settings, next, previous, none, or component:<enabled ID>."
        end
    end
    return nil
end

local function region(ctx, id)
    for _, entry in (ctx.data.settings and ctx.data.settings.regions) or {} do
        local name, placement = string.match(entry, "^([^:]+):([^:]+)$")
        if name == id and table.find(regions, placement) then return placement end
    end
    return "auto"
end

local function assigningRegion(ctx, id, placement)
    assert(table.find(regions, placement), "invalid lake region")
    local result = {}
    for _, component in ctx.data.components or {} do
        local assigned = if component.id == id then placement else region(ctx, component.id)
        if assigned ~= "auto" then result[#result + 1] = component.id .. ":" .. assigned end
    end
    return result
end

local function expandedMotion(ctx)
    return { response = value(ctx, "springResponse"), bounce = value(ctx, "springBounce") }
end

local function hasView(ctx, widget, wanted)
    for _, entry in ctx.data.catalog or {} do
        if entry.widget == widget then return table.find(entry.views or {}, wanted) ~= nil end
    end
    return false
end

local function view(ctx, widget, wanted)
    for _, entry in ctx.data.catalog or {} do
        if entry.widget == widget then
            local views = entry.views or {}
            return if table.find(views, wanted) then wanted else views[1] or wanted
        end
    end
    return wanted
end

return table.freeze({ value = value, color = color, validate = validate, targetID = targetID, region = region, regions = regions,
    assigningRegion = assigningRegion, expandedMotion = expandedMotion, hasView = hasView, view = view })
