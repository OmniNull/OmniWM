local function spring(response, bounce)
    return table.freeze({ response = response, bounce = bounce })
end

local content = spring(0.28, 0.12)
local disappear = spring(0.22, 0)

return table.freeze({
    shape = table.freeze({ compact = spring(0.30, 0.04), peek = spring(0.28, 0.12), expanded = spring(0.38, 0.18) }),
    promotion = spring(0.34, 0.16),
    content = content,
    feedback = spring(0.18, 0.02),
    digits = spring(0.30, 0),
    appear = table.freeze({ opacity = 0, scale = 0.88, animate = content }),
    exit = table.freeze({ opacity = 0, scale = 0.88, animate = disappear }),
    swipe = table.freeze({
        dy = table.freeze({ 0, -40, rubber = 0.4 }),
        scale = table.freeze({ 1, 0.94, rubber = 0.1 }),
        opacity = table.freeze({ 1, 0.8 }),
    }),
})
