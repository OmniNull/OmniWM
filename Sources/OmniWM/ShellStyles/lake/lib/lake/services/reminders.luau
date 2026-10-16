local function snapshot(ctx)
    return ctx.data.reminders
end

return table.freeze({ snapshot = snapshot,
    authorize = function() omniwm.run("reminders authorize") end,
    settings = function() omniwm.run("reminders settings") end,
    complete = function(id) omniwm.run("reminders complete " .. id) end,
    activity = function(ctx)
        local data = snapshot(ctx)
        return { priority = if data and data.access == "full" and data.total > 0 then 8 else 0,
            label = if data and data.access == "full" then tostring(data.total) .. " reminders" else "Reminders access needed" }
    end })
