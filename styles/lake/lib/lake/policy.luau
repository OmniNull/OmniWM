local preferences = require("./preferences")
local regionRank = table.freeze({ main = 0, auto = 1, side = 2, expanded = 3 })

local function select(ctx)
    local entries = {}
    for index, component in ctx.data.components or {} do
        if component.enabled then
            local activity = omniwm.components.activity(component.id)
            entries[#entries + 1] = { id = component.id, widget = component.widget, title = component.title, index = index,
                priority = activity and activity.priority or 0, since = activity and activity.since or 0,
                activity = activity, label = activity and activity.label or nil, region = preferences.region(ctx, component.id) }
        end
    end
    table.sort(entries, function(a, b)
        if a.id == b.id then return false end
        if a.id == ctx.state.primary then return true end
        if b.id == ctx.state.primary then return false end
        if a.region ~= b.region then return regionRank[a.region] < regionRank[b.region] end
        if a.priority ~= b.priority then return a.priority > b.priority end
        if a.since ~= b.since then return a.since > b.since end
        return a.index < b.index
    end)
    return entries
end

local function placed(entries, expanded)
    local primary
    for _, entry in entries do
        if expanded or entry.region == "auto" or entry.region == "main" then primary = entry; break end
    end
    local secondary
    for _, entry in entries do
        if entry ~= primary and entry.region == "side" then secondary = entry; break end
    end
    if not secondary then
        for _, entry in entries do
            if entry ~= primary and entry.region == "auto" then secondary = entry; break end
        end
    end
    return primary, secondary
end

local function step(ctx, delta, current)
    local ids = {}
    for _, component in ctx.data.components or {} do
        local region = preferences.region(ctx, component.id)
        if component.enabled and (ctx.state.expanded or region == "auto" or region == "main") then
            ids[#ids + 1] = component.id
        end
    end
    if #ids == 0 then return end
    local index = table.find(ids, current or ctx.state.primary) or 1
    ctx.state.primary = ids[(index - 1 + delta) % #ids + 1]
    ctx.state.navigationPage = nil
    ctx.state.motion = "promotion"
end

return table.freeze({ select = select, placed = placed, step = step })
