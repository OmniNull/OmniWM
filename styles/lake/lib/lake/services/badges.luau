local function snapshot(ctx)
    local data = ctx.data.badges
    if not data then return nil end
    local result = {}
    for bundle, label in data do result[#result + 1] = { bundle = bundle, label = label } end
    table.sort(result, function(a, b) return a.bundle < b.bundle end)
    return result
end

return table.freeze({ snapshot = snapshot, activity = function(ctx)
    local badges = ctx.data.badges
    local count = 0
    for _ in badges or {} do count += 1 end
    return { priority = if count > 0 then 15 else 0,
        label = badges and tostring(count) .. " apps with badges" or "Badges unavailable" }
end })
