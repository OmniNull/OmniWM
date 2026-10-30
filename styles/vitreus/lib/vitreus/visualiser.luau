-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local spike = table.freeze({ response = 0.276, bounce = 0.43 })
local placements = table.freeze({ bottom = 0, corners = 1, top = 2, left = 3, right = 4 })

local function finite(value, default)
    return if type(value) == "number" and value == value and math.abs(value) < math.huge then value else default
end

local function plan(ctx, g, budget)
    local settings = ctx.data.settings or {}
    if settings.visualiser ~= true then return nil end
    local selected = settings.mon or ""
    local bar = ctx.data.bar or {}
    if selected ~= "" and selected ~= bar.monitorId and selected ~= bar.monitor
        and selected ~= g.island.display then return nil end
    local configured = math.clamp(math.floor(finite(settings.cols, 24) + 0.5), 6, 47)
    local available = math.clamp(math.floor(finite(budget, 47)), 0, 47)
    local layout = placements[settings.lay or "bottom"] or 0
    local corners = layout == 1
    local requested = if corners then 4 * math.clamp(math.floor(configured / 4), 2, 11) else configured
    local count = if corners then 4 * math.min(requested / 4, math.floor(available / 4))
        else math.min(configured, available)
    local n, m = if corners then configured else count, if corners then count / 4 else 0
    local size, u = g.size, g.k.u
    local bl = math.clamp(finite(settings.bl, 1), 0, 1)
    local widthFactor = 0.8 + 1.1 * bl
    local frame = g.frame
    local framed = frame ~= nil
    local vertical = frame and frame.vertical
    local thin = 8 * u
    local strip = if frame then frame.width else 46 * g.k.bu
    local left = if vertical then strip else thin
    local right, top = thin, if framed and not vertical and g.layout ~= "seg" then strip else thin
    local y0, y1 = if framed then top else 0, size.h - (if framed then thin else 0)
    local w, h = size.w - left - right, y1 - y0
    local mirrorX, mirrorY = frame and frame.edge == "right", frame and frame.edge == "fbottom"
    local bottomY, topY = if mirrorY then y0 else y1, if mirrorY then y1 else y0
    local bottomDirection = if mirrorY then 1 else -1
    local topDirection = -bottomDirection
    local leftX = if mirrorX then size.w - right * (if framed then 1 else 0)
        else left * (if framed then 1 else 0)
    local rightX = if mirrorX then left * (if framed then 1 else 0)
        else size.w - right * (if framed then 1 else 0)
    local sideDirection = if mirrorX then -1 else 1
    local width = if corners then 17 * u * widthFactor
        elseif count > 0 then (if layout > 2 then h else w) / count * widthFactor else 0
    local maxHeight = math.clamp(finite(settings.hgt, 150), 40, 300) * u
    local sensitivity = math.clamp(finite(settings.sens, 1), 0.3, 3)
    local columns = {}
    for index = 0, count - 1 do
        local t = (index + 0.5) / n
        local band = math.abs(2 * t - 1) * 23
        local taper = math.clamp(math.min(index + 0.5, n - index - 0.5) / (0.05 * n), 0, 1)
        local x, y, dx, dy = left + t * w, bottomY, 0, bottomDirection
        if corners then
            local position, corner = (math.floor(index / 4) + 0.5) / m, index % 4
            local angle = position * math.pi / 2
            local east, south = corner % 2 == 1, corner < 2
            x, y = if east then size.w - right else left, if south then bottomY else topY
            dx, dy = (if east then -1 else 1) * math.cos(angle),
                (if south then bottomDirection else topDirection) * math.sin(angle)
            band, taper = position * 23, 1
        elseif layout == 2 then
            y, dy = topY, topDirection
        elseif layout == 3 or layout == 4 then
            x, y = if layout == 3 then leftX else rightX, y0 + t * h
            dx, dy = if layout == 3 then sideDirection else -sideDirection, 0
        end
        if mirrorX then x, dx = size.w - x, -dx end
        if mirrorY then y, dy = size.h - y, -dy end
        columns[index + 1] = table.freeze({
            key = "visualiser-column-" .. index, index = index, band = band, taper = taper,
            baseX = x, baseY = y, dirX = dx, dirY = dy, rotation = math.deg(math.atan2(dx, -dy)),
            w = width, radius = width * 0.45, maxHeight = maxHeight, sensitivity = sensitivity,
        })
    end
    return table.freeze({ columns = table.freeze(columns), configured = configured,
        requested = requested, count = count, capped = count < requested, spike = spike,
        sourceBlend = (10 + 22 * bl) * u })
end

local function shapes(ctx, g, budget)
    local geometry = plan(ctx, g, budget)
    if not geometry then return nil end
    local cap = if geometry.capped then geometry.requested .. ":" .. geometry.count else nil
    if cap and ctx.state.visualiserCap ~= cap then
        omniwm.log("Visualiser capped from " .. geometry.requested .. " to " .. geometry.count .. " columns by the glass shape budget")
    end
    ctx.state.visualiserCap = cap
    if geometry.count == 0 then return nil end
    local result = {}
    for _, column in geometry.columns do
        local length = column.maxHeight + 3 * g.k.u
        local x = column.baseX + column.dirX * (column.maxHeight - 3 * g.k.u) / 2
        local y = column.baseY + column.dirY * (column.maxHeight - 3 * g.k.u) / 2
        result[#result + 1] = ui.shape({ key = column.key, align = "topLeading",
            dx = x - column.w / 2, dy = y - length / 2, w = column.w, h = length,
            radius = column.radius, rotate = column.rotation, hit = false,
            spectrum = { band = column.band / 23, gain = column.sensitivity, taper = column.taper,
                inset = 3 * g.k.u, threshold = 1, response = spike.response, bounce = spike.bounce },
        })
    end
    return result
end

return table.freeze({ plan = plan, spike = spike,
    shapes = shapes, content = function() return nil end })
