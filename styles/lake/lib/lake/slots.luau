local function geometry(island, mode, expandedWidth)
    local notch = island.notch
    local gap = notch and notch.w or 88
    local compactHeight = math.min(island.size.h, math.max(32, notch and notch.h or 32))
    local available = math.max(1, island.size.w - 32)
    local compact = math.max(1, math.min(island.size.w - 110, gap + 140))
    local width = if mode == "expanded" then math.min(expandedWidth or 520, available)
        else if mode == "peek" then math.min(380, available) else compact
    local height = if mode == "expanded" then math.min(300, island.size.h)
        else if mode == "peek" then math.min(compactHeight + 48, island.size.h) else compactHeight
    return { width = width, height = height, compactHeight = compactHeight,
        top = notch and notch.h or 12, gap = gap, secondaryX = width / 2 + 46 }
end

return table.freeze({ geometry = geometry })
