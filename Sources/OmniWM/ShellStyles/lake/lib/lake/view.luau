local foreground = "#ffffff"
local secondary = "#a1a1aa"
local motion = require("./motion")

local function compact(ctx, icon, text, color)
    local props = ctx.view.props or {}
    return ui.row{ gap = 8, pad = 6,
        ui.symbol{ name = icon, size = 15, color = color or foreground },
        ui.box{ w = props.notchGap or 0, h = 1 },
        ui.text{ text = text, size = 11, weight = "semibold", color = foreground, maxWidth = 64 } }
end

local function button(symbol, action)
    return ui.box{ w = 36, h = 32, radius = 10, hover = "#ffffff22", onClick = action,
        pressScale = 0.94, pressFill = "#ffffff30", pressAnimate = motion.feedback,
        ui.symbol{ name = symbol, size = 16, color = foreground } }
end

return table.freeze({ compact = compact, button = button, foreground = foreground, secondary = secondary })
