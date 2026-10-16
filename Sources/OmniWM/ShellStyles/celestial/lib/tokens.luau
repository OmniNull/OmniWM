-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

local function scale(values: { [string]: number }): { [string]: number }
    local scaled = {}
    for name, value in values do
        scaled[name] = value * 4 / 3
    end
    return scaled
end

local steps = {
    extraSmall = 4,
    small = 8,
    medium = 12,
    large = 16,
    largeIncreased = 20,
    extraLarge = 28,
    extraLargeIncreased = 32,
    extraExtraLarge = 48,
}

return table.freeze({
    rounding = steps,
    spacing = steps,
    padding = steps,
    size = scale({ small = 11, smaller = 12, normal = 13, larger = 15, large = 18, extraLarge = 28 }),
    headline = scale({ large = 32, medium = 28, small = 24 }),
    title = scale({ large = 22, medium = 16, small = 14 }),
    body = scale({ large = 16, medium = 14, small = 12 }),
    label = scale({ large = 14, medium = 12, small = 11 }),
    icon = { small = 20, medium = 24, large = 32, extraLarge = 48 },
    bar = { inner = 40, popout = { battery = 250, network = 320, audio = 320, keyboard = 320 } },
    dashboard = {
        indicator = 3,
        indicatorGap = 5,
        user = 340,
        logo = 30,
        uptime = 30,
        dateTime = 110,
        media = 200,
        mediaSweep = 180,
        mediaThickness = 6,
        resourceThickness = 6,
        weather = 275,
        cover = 200,
        mediaTab = { w = 1000, h = 320, section = 300 },
        performance = {
            hero = 400,
            shape = 100,
            storageText = 160,
            network = { w = 390, h = 220 },
            battery = { w = 150, single = 400, h = 160 },
            placeholder = 700,
        },
    },
})
