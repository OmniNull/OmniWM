-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local roles = table.freeze({
    tint = "secondaryContainer",
    panel = "surface",
    ink = "foreground",
    faint = "secondaryForeground",
    mint = "accent",
    mintlo = "accent",
    minthi = "secondaryContainerForeground",
    onmint = "accentForeground",
    deep = "shadow",
    off = "border",
    alert = "error",
})

local function alpha(name: string, value: number): string
    local amount = if value ~= value then 0 else math.clamp(value, 0, 1)
    return string.format("%s/%.3f", roles[name] or name, amount)
end

return table.freeze({
    roles = roles,
    veil = 0.08,
    alpha = alpha,
})
