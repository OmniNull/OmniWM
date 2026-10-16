interval = 60

local function collapse(ctx)
    ctx.state.expanded = false
end

function render(ctx)
    local island = ctx.data.island
    if not island then return ui.box{ w = 0, h = 0 } end
    local expanded = ctx.state.expanded == true
    local width = math.min(if expanded then 340 else 220, island.size.w)
    local padding = if expanded then 12 else 8
    local top = math.max(island.menuBar, island.notch and island.notch.h or 0) + 8
    return ui.box{ w = island.size.w, h = island.size.h, align = "top",
        ui.box{ key = "capsule", w = width, h = if expanded then 164 else 36,
            dy = top, align = "top", pad = padding, radius = if expanded then 24 else 18,
            fill = "#000000",
            animate = { response = 0.3, bounce = 0.12 },
            focusable = true, focusRing = false, keys = { "escape" },
            onClick = function(next) next.state.expanded = not next.state.expanded end,
            onOutsidePress = if expanded then collapse else nil,
            onKey = function(next, event)
                if event.key == "escape" then collapse(next) end
            end,
            ui.component{ id = "desk-clock", view = if expanded then "expanded" else "compact",
                w = math.max(1, width - padding * 2), h = if expanded then 140 else 20 } } }
end
