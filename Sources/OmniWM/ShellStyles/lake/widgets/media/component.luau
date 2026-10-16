local service = require("../lib/lake/services/media")
local view = require("../lib/lake/view")
local waveform = omniwm.asset("@self/waveform.metal")

local function sameTrack(a, b)
    return a.bundle == b.bundle and a.title == b.title and a.artist == b.artist and a.album == b.album
end

local function clock(seconds)
    local value = math.floor(seconds)
    return string.format("%d:%02d", math.floor(value / 60), value % 60)
end

local function compact(ctx)
    local media = service.snapshot(ctx)
    if not media.playing then
        return view.compact(ctx, "music.note", if media.available then "Paused" else "Music", "#fb7185")
    end
    local props = ctx.view.props or {}
    local wing = if props.secondary then 24 else 36
    local art = if media.artwork then ui.image{ key = "artwork", image = media.artwork, w = 20, h = 20, radius = 5 }
        else ui.symbol{ name = "music.note", size = 15, color = "#fb7185" }
    return ui.row{ key = "compact-media", gap = 6, pad = 6,
        ui.box{ w = wing, h = 20, art },
        ui.box{ w = props.notchGap or 0, h = 1 },
        ui.shader{ key = "waveform", source = waveform, audio = true, w = wing, h = 20 } }
end

local function scrubber(ctx, media, width, labels)
    local position = service.position(ctx)
    if not position then
        return ui.text{ text = if media.available then "Live or position unavailable" else "Start playback in a media app",
            size = 11, maxWidth = width, color = view.secondary }
    end
    local scrub = ctx.state.scrub
    local fraction = if scrub and not scrub.cancelled and sameTrack(scrub.track, media) and scrub.duration == position.duration
        then scrub.value else position.fraction
    local slider = ui.slider{ key = "seek", w = width, h = 14, value = fraction, color = "#fb7185",
        onChange = function(next, event)
            if event.phase == "cancelled" then next.state.scrub = nil; return end
            if not event.value then return end
            local current = service.snapshot(next)
            local duration = next.select("media", "duration")
            local value = math.clamp(event.value, 0, 1)
            local active = next.state.scrub
            if event.phase == "began" then
                next.state.scrub = if sameTrack(media, current) and duration == position.duration
                    then { track = media, duration = duration, value = value } else { cancelled = true }
            elseif event.phase == "changed" or event.phase == "ended" then
                local valid = active and not active.cancelled and sameTrack(active.track, current) and active.duration == duration
                if event.phase == "ended" then
                    next.state.scrub = nil
                    if valid then service.seek(value * duration) end
                else
                    next.state.scrub = if valid then { track = active.track, duration = duration, value = value }
                        else { cancelled = true }
                end
            end
        end }
    if not labels then return slider end
    return ui.column{ gap = 6, slider, ui.row{ w = width,
        ui.text{ text = clock(fraction * position.duration), size = 11, color = view.secondary },
        ui.box{ grow = 1 }, ui.text{ text = clock(position.duration), size = 11, color = view.secondary } } }
end

local function peek(ctx)
    local media = service.snapshot(ctx)
    local width = math.max(1, math.min(ctx.view.w or 380, 380) - 28)
    local row = { key = "peek-controls", gap = 12, w = width, align = "top",
        dy = (ctx.view.props or {}).top or 32 }
    if media.available then row[#row + 1] = view.button(if media.playing then "pause.fill" else "play.fill", service.toggle) end
    local contentWidth = math.max(1, width - (if media.available then 48 else 0))
    row[#row + 1] = ui.column{ gap = 3, center = false, w = contentWidth,
        ui.text{ key = "peek-title", text = media.title, size = 11, weight = "semibold",
            maxWidth = contentWidth, color = view.foreground },
        scrubber(ctx, media, contentWidth, false) }
    return ui.stack{ align = "top", compact(ctx), ui.row(row) }
end

local function expanded(ctx)
    local media = service.snapshot(ctx)
    local width = math.max(1, math.min(ctx.view.w or 520, 520) - 48)
    local art = if media.artwork then ui.image{ image = media.artwork, w = 72, h = 72, radius = 14 }
        else ui.box{ w = 72, h = 72, fill = "#ffffff14", radius = 14,
            ui.symbol{ name = "music.note", size = 30, color = "#fb7185" } }
    local content = { gap = 16, align = "top", dy = (ctx.view.props or {}).top or 0,
        ui.row{ gap = 16, art, ui.column{ gap = 6, center = false,
            ui.text{ text = media.title, size = 17, weight = "semibold", maxWidth = math.max(1, width - 88), color = view.foreground },
            ui.text{ text = media.artist, size = 13, maxWidth = math.max(1, width - 88), color = view.secondary } } },
        scrubber(ctx, media, width, true) }
    if media.available then content[#content + 1] = ui.row{ gap = 20,
        view.button("backward.fill", service.previous),
        view.button(if media.playing then "pause.fill" else "play.fill", service.toggle),
        view.button("forward.fill", service.next) } end
    return ui.column(content)
end

return { views = { compact = compact, peek = peek, expanded = expanded }, activity = function(ctx)
    local media = service.snapshot(ctx)
    return { priority = if media.playing then 50 else 2, label = media.title }
end }
