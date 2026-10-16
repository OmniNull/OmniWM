local motion = require("./motion")

local function label(text, options)
    return ui.text{ text = text, size = options.size or 48, style = "mono",
        weight = options.weight or "light", color = options.color or "#ffffff" }
end

local function render(value, options)
    options = options or {}
    local text = tostring(value)
    local count = utf8.len(text)
    if not count or count > 16 then return label(text, options) end
    local size = options.size or 48
    local width = options.width or size * 0.64
    local height = options.height or size * 1.25
    local animation = options.animate or motion.digits
    local row = { key = options.key or "digits", gap = options.gap or 0 }
    local index = 0
    for _, code in utf8.codes(text) do
        index += 1
        local key = tostring(count - index)
        if code >= 48 and code <= 57 then
            local strip = { key = "strip", w = width, gap = 0, align = "topLeading",
                dy = -(code - 48) * height, animate = animation, appear = { animate = "none" } }
            for digit = 0, 9 do
                strip[#strip + 1] = ui.box{ key = tostring(digit), w = width, h = height,
                    label(tostring(digit), options) }
            end
            row[#row + 1] = ui.stack{ key = "digit:" .. key, w = width, h = height,
                ui.path{ key = "clip", d = "M0 0 H1 V1 H0 Z", viewBox = { 0, 0, 1, 1 },
                    w = width, h = height, mask = true }, ui.column(strip) }
        else
            row[#row + 1] = ui.box{ key = "literal:" .. key, h = height, label(utf8.char(code), options) }
        end
    end
    return ui.row(row)
end

return table.freeze({ render = render })
