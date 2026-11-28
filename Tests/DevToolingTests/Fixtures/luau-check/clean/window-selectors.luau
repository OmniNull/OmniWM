--!strict
omniwm.command("Window selectors", function(ctx: ConfigContext)
    local id = ctx.windowId
    if not id then return end
    omniwm.dispatch("window", "move-to-workspace", id, 2)
    omniwm.dispatch("window", "move-column-to-index", id, 1)
    omniwm.dispatch("window", "place-in-own-column", id, 2)
    omniwm.dispatch("window", "assign-to-scratchpad", id, 1)
end)
