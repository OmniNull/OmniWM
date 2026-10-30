-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("../kit")
local palette = require("../palette")
local pencil = require("../pencil")
local cards = require("../cards")
local frame = require("../frame")
local f5 = table.freeze({ response = 2 * math.pi * 0.620 / 6.64, bounce = 0 })
local f6 = table.freeze({ response = 2 * math.pi * 0.700 / 6.64, bounce = 0 })

local function model(ctx)
    local brightness, microphone = ctx.data.brightness, ctx.data.microphone
    local available = brightness ~= nil and brightness.available == true
    local mixer, outputs = ctx.state.controlsMixer == true, ctx.state.controlsOutputs == true
    local audioApps = if mixer or cards.out(ctx, "controls-mixer") then ctx.data.audioApps else nil
    local devices = if outputs then ctx.data.outputs else nil
    local apps = if audioApps and audioApps.access == "granted" then audioApps.apps else {}
    local embedded = mixer and (frame.framed(ctx.data.settings) or not cards.out(ctx, "controls-mixer") and not cards.out(ctx, "controls-sliders"))
    local extra = if embedded then (if #apps > 0 then #apps * 32 + 8 else 40)
        elseif outputs then math.max(0, math.clamp(devices and #devices or 0, 1, 6) * 30 - 4) + 12 else 0
    local height = (if available then 132 else 92) + extra
    return { top = 160, height = height, totalHeight = 160 + height + 16,
        baseHeight = if available then 132 else 92, apps = apps, access = audioApps and audioApps.access,
        outputs = devices or {}, mixer = mixer, output = outputs, brightness = brightness,
        microphone = microphone, volume = ctx.data.volume, muted = ctx.data.muted, bright = available }
end

local function height(ctx)
    return model(ctx).totalHeight
end

local function box(c, props, x, y, w, h, r)
    props.w, props.h, props.radius = w * c.du, h * c.du, (r or 0) * c.du
    return ui.box(kit.at(c, props, x * c.du, y * c.du))
end

local function text(ctx, c, key, value, x, y, size, color, weight, width, trailing)
    local measured = if trailing then ctx.format.measure(value, { font = kit.font, size = size * c.rs, weight = weight }) else 0
    return kit.label(c, { key = key, text = value, align = "leading",
        x = (x - math.min(measured / c.du, width)) * c.du, y = y * c.du,
        size = size, color = color, weight = weight, maxWidth = width * c.du, lines = 1, decorative = true })
end

local function hover(key)
    return function(next, event)
        if event.phase == "began" then next.state.controlsSliderHot = key
        elseif next.state.controlsSliderHot == key then next.state.controlsSliderHot = nil end
    end
end

local function toggle(next, name)
    if name == "mixer" then
        next.state.controlsMixer = not next.state.controlsMixer
        next.state.controlsOutputs = false
        if next.state.controlsMixer and cards.out(next, "controls-sliders") then
            local m = model(next)
            cards.expose(next, "controls-mixer", "controls-sliders", m.height + 16)
        elseif not next.state.controlsMixer then cards.home(next, "controls-mixer") end
    else
        next.state.controlsOutputs = not next.state.controlsOutputs
        next.state.controlsMixer = false
        cards.home(next, "controls-mixer")
    end
    next.state.controlsSlider, next.state.controlsSliderValue = nil, nil
end

local function slider(ctx, c, key, x, y, width, level, muted, command, small, rightClick)
    local active = level ~= nil
    local hot = ctx.state.controlsSliderHot == key or ctx.state.controlsSlider == key
    local value = math.clamp(if ctx.state.controlsSlider == key then ctx.state.controlsSliderValue else level or 0, 0, 1)
    local thickness = if small then 9 else (if hot then 19 else 16)
    local tone = if muted then palette.roles.faint else palette.roles.mint
    local inner = kit.canvas((width + 16) * c.du, 34 * c.du, c.du, c.rs)
    local content = { key = key .. "-drawing", w = inner.w, h = inner.h, align = "topLeading", decorative = true,
        box(inner, { fill = palette.alpha("ink", if muted then 0.05 else 0.09) },
            8 + width / 2, 17, width, thickness, thickness / 2),
    }
    for _, path in pencil.draw(inner.w, inner.h,
        pencil.outline((8 + width / 2) * c.du, 17 * c.du, width * c.du, thickness * c.du, c.du,
            if hot then 1 else 0, 0), palette.alpha("ink", if active then 0.48 else 0.24)) do
        content[#content + 1] = path
    end
    if value > 0 then
        content[#content + 1] = box(inner, { key = key .. "-level", fill = tone, opacity = 0.55,
            animate = kit.springs.slide }, 8 + width * value / 2, 17, width * value, thickness - 4, (thickness - 4) / 2)
    end
    content[#content + 1] = box(inner, { key = key .. "-thumb", fill = palette.roles.ink,
        shadow = palette.alpha("deep", 0.3), shadowRadius = 2 * c.du, shadowOffset = { x = 0, y = c.du },
        animate = kit.springs.pop }, 8 + width * value, 17, if small then 4 else 5,
        thickness + (if small then 3 else 4), 2)
    local function update(next, event)
        local phase = event.phase
        if event.button == "right" then
            if phase == "down" and rightClick then toggle(next, "mixer") end
            return
        end
        if phase == "down" or phase == "began" or phase == "changed" then
            local fraction = math.clamp(((event.x or 0) / c.du - 8) / width, 0, 1)
            next.state.controlsSlider, next.state.controlsSliderValue = key, fraction
            omniwm.run(string.format("%s %.1f", command, fraction * 100))
        elseif phase == "up" or phase == "ended" or phase == "cancel" or phase == "cancelled" then
            if next.state.controlsSlider == key then
                next.state.controlsSlider, next.state.controlsSliderValue = nil, nil
            end
        end
    end
    return ui.stack(kit.at(c, { key = key, w = inner.w, h = inner.h,
        cursor = if active then "pointer" else nil, onHover = if active then hover(key) else nil,
        onPress = if active then update else nil, gesture = if active then { axis = "x", threshold = 0 } else nil,
        gestureEvents = if active then "all" else nil, onGesture = if active then update else nil,
        ui.stack(content),
    }, (x + width / 2) * c.du, y * c.du))
end

local function icon(c, key, name, x, y, muted, command)
    return ui.stack(kit.at(c, { key = key, w = 28 * c.du, h = 32 * c.du,
        cursor = if command then "pointer" else nil, onClick = command,
        ui.symbol({ name = name, size = 20 * c.du, color = if muted then palette.roles.alert else palette.roles.ink,
            opacity = if command then 0.85 else 0.5, decorative = true }),
    }, x * c.du, y * c.du))
end

local function row(ctx, c, spec)
    local level = spec.level
    local value = if ctx.state.controlsSlider == spec.key then ctx.state.controlsSliderValue else level
    return ui.stack({ key = spec.key .. "-row", w = c.w, h = c.h, align = "topLeading",
        appear = { opacity = 0, dy = 12 * c.du, delay = 0.2, animate = spec.spring },
        exit = { opacity = 0, dy = 12 * c.du, animate = kit.springs.close },
        icon(c, spec.key .. "-mute", spec.icon, 38, spec.y, spec.muted, spec.mute),
        slider(ctx, c, spec.key, 60, spec.y, 170, level, spec.muted, spec.command, false, spec.output),
        text(ctx, c, spec.key .. "-value", if value == nil then "Unavailable"
            elseif spec.muted then "Muted" else string.format("%d%%", math.floor(value * 100 + 0.5)),
            276, spec.y, if value == nil then 11.5 else 18.5,
            if spec.muted or value == nil then palette.roles.faint else palette.roles.ink, "semibold", 64, true),
    })
end

local function appRow(ctx, p, app)
    local cu = p.cu
    local c = kit.canvas(288 * cu, 28 * cu, cu, p.rs)
    return ui.stack({ key = "controls-app-" .. app.id, w = c.w, h = c.h, opacity = if app.playing then 1 else 0.55,
        ui.icon({ key = "controls-app-icon-" .. app.id, app = app.id, placeholder = "app", w = 20 * cu, h = 20 * cu,
            align = "topLeading", dx = 10 * cu, dy = 5 * cu }),
        text(ctx, c, nil, app.name, 38, 13, 12.5, palette.roles.ink, nil, 78),
        slider(ctx, c, "controls-app-slider-" .. app.id, 116, 14, 100, app.volume / 100, app.muted,
            "volume app " .. app.id .. " set", true),
        text(ctx, c, nil, string.format("%d%%", math.floor(app.volume + 0.5)),
            252, 14, 12, palette.roles.faint, nil, 32, true),
        ui.stack(kit.at(c, { key = "controls-app-mute-" .. app.id, w = 20 * cu, h = 24 * cu,
            cursor = "pointer", onClick = "volume app " .. app.id .. " mute",
            ui.symbol({ name = if app.muted then "speaker.slash" else "speaker.wave.2", size = 15 * cu,
                color = if app.muted then palette.roles.alert else palette.roles.ink, decorative = true }),
        }, 263 * cu, 14 * cu)),
    })
end

local function appList(ctx, p, m, listY)
    local cu = p.cu
    local list = { key = "controls-apps", w = 288 * cu, h = math.max(28, #m.apps * 32 - 4) * cu,
        align = "topLeading", dx = 12 * cu, dy = (listY or 0) * cu, gap = 4 * cu, center = false }
    for _, app in m.apps do list[#list + 1] = appRow(ctx, p, app) end
    if #m.apps == 0 then
        list[#list + 1] = ui.stack({ w = 288 * cu, h = 28 * cu,
        kit.label(kit.canvas(288 * cu, 28 * cu, cu, p.rs), { key = "controls-apps-empty",
            text = if m.access == "denied" then "Audio access denied" elseif m.access == "unknown" or m.access == nil then
            "Waiting for audio access" else "No app is playing sound", size = 12.5, color = palette.roles.faint }),
        })
    end
    return ui.column(list)
end

local function content(ctx, p, data)
    local m = data or model(ctx)
    local cu, offset = p.cu, if m.bright then 0 else -40
    local c = kit.canvas(p.w, m.height * cu, cu, p.rs)
    local items = { key = "controls-slider-card", w = c.w, h = c.h, align = "topLeading",
        ui.glass({ key = "controls-slider-veil", w = 288 * cu, h = c.h, align = "topLeading", dx = 12 * cu,
            backdrop = false, fill = palette.alpha("ink", palette.veil), blend = 0, rim = 0,
            shadow = 0, shadowRadius = 0,
            ui.shape({ key = "controls-slider-veil-shape", w = 288 * cu, h = c.h, radius = 14 * cu,
                animate = p.calm }),
        }),
    }
    if m.bright then
        items[#items + 1] = row(ctx, c, { key = "controls-brightness", icon = "sun.max", y = 26,
            level = m.brightness.value / 100, command = "brightness set", spring = f6 })
    end
    local mic = m.microphone
    items[#items + 1] = row(ctx, c, { key = "controls-microphone", icon = if mic and mic.muted then "mic.slash" else "mic",
        y = 66 + offset, level = mic and mic.volume and mic.volume / 100, muted = mic and mic.muted,
        mute = if mic and mic.muted ~= nil then "microphone mute" else nil, command = "microphone set", spring = f6 })
    items[#items + 1] = row(ctx, c, { key = "controls-volume", icon = if m.muted then "speaker.slash" else "speaker.wave.2",
        y = 106 + offset, level = m.volume and m.volume / 100, muted = m.muted,
        mute = if m.muted ~= nil then "volume mute" else nil,
        command = "volume set", output = true, spring = f5 })
    items[#items + 1] = ui.stack(kit.at(c, { key = "controls-outputs-toggle", w = 20 * cu, h = 30 * cu,
        cursor = "pointer", onClick = function(next) toggle(next, "outputs") end,
        ui.symbol({ name = if m.output then "chevron.up" else "chevron.down", size = 11 * cu,
            color = palette.roles.ink, opacity = 0.7, decorative = true }),
    }, 289 * cu, (106 + offset) * cu))
    local footerY = m.height - 8.5
    local toggleItems = { key = "controls-mixer-toggle", w = 40 * cu, h = 10 * cu,
        cursor = "pointer", onClick = function(next) toggle(next, "mixer") end }
    if m.mixer then
        toggleItems[#toggleItems + 1] = ui.symbol({ name = "chevron.up", size = 10 * cu,
            color = palette.roles.mint, decorative = true })
    else
        local t = kit.canvas(40 * cu, 10 * cu, cu, p.rs)
        for index = -1, 1 do
            toggleItems[#toggleItems + 1] = box(t, { fill = palette.alpha("ink", 0.4) }, 20 + 6.5 * index, 5, 3.2, 3.2, 1.6)
        end
    end
    items[#items + 1] = ui.stack(kit.at(c, toggleItems, 156 * cu, footerY * cu))
    local listY = 124 + offset
    if m.mixer then
        if p.frame then
            items[#items + 1] = appList(ctx, p, m, listY)
        elseif not cards.out(ctx, "controls-sliders") and not cards.out(ctx, "controls-mixer") then
            items[#items + 1] = cards.placeholder(p, "controls-mixer", 12, listY, 288, math.max(28, #m.apps * 32 - 4)) end
    elseif m.output then
        local count = math.min(#m.outputs, 6)
        local list = { key = "controls-outputs", w = 276 * cu, h = math.max(26, count * 30 - 4) * cu,
            align = "topLeading", dx = 18 * cu, dy = listY * cu, gap = 4 * cu, center = false, scroll = true }
        for _, output in m.outputs do
            local r = kit.canvas(276 * cu, 26 * cu, cu, p.rs)
            list[#list + 1] = ui.stack({ key = "controls-output-" .. output.id, w = r.w, h = r.h,
                radius = 8 * cu, fill = palette.alpha("ink", if output.default then 0.1 else 0),
                hover = palette.alpha("ink", 0.14), cursor = "pointer", onClick = function(next)
                    omniwm.run("volume output " .. output.id)
                    next.state.controlsOutputs = false
                end,
                text(ctx, r, nil, output.name, 10, 13, 13, if output.default then palette.roles.mint else palette.roles.ink,
                    if output.default then "semibold" else nil, 232),
                if output.default then ui.symbol({ name = "checkmark", size = 13 * cu, color = palette.roles.mint,
                    align = "trailing", dx = -10 * cu, decorative = true }) else nil,
            })
        end
        if count == 0 then list[#list + 1] = ui.stack({ w = 276 * cu, h = 26 * cu,
            kit.label(kit.canvas(276 * cu, 26 * cu, cu, p.rs), { key = "controls-outputs-empty", text = "No outputs",
                size = 13, color = palette.roles.faint }),
        }) end
        items[#items + 1] = ui.column(list)
    end
    return ui.stack({ key = "controls-slider-section", w = c.w, h = c.h + 16 * cu,
        align = "topLeading", dy = m.top * cu, ui.stack(items),
        if not m.bright then ui.stack({ key = "controls-display-settings", w = 128 * cu, h = 13 * cu,
            align = "topLeading", dx = (c.w - 128 * cu) / 2, dy = c.h + 1.5 * cu,
            cursor = "pointer", onClick = "brightness settings",
            kit.label(kit.canvas(128 * cu, 13 * cu, cu, p.rs), { text = "Display Settings",
                size = 11.5, color = palette.roles.faint }),
        }) else nil,
    })
end

return table.freeze({ model = model, height = height, content = content, appList = appList })
