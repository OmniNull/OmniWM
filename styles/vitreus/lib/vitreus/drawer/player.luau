-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local kit = require("../kit")
local palette = require("../palette")
local cards = require("../cards")
local frame = require("../frame")
local entrance = table.freeze({ response = 2 * math.pi * 0.52 / 6.64, bounce = 0 })

local function tasks(ctx)
    local bar = ctx.data.bar
    local rows = {}
    for order, workspace in (bar and bar.workspaces) or {} do
        for _, app in workspace.windows do
            for _, window in app.windows do
                rows[#rows + 1] = { id = window.id, title = if window.title ~= "" then window.title else app.name,
                    app = app.bundle, active = window.focused, workspace = workspace.name,
                    sortTitle = string.lower(if window.title ~= "" then window.title else app.name),
                    number = tonumber(workspace.name) or tonumber(workspace.id) or order }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.active ~= b.active then return a.active end
        if a.number ~= b.number then return a.number < b.number end
        if a.sortTitle ~= b.sortTitle then return a.sortTitle < b.sortTitle end
        return a.id < b.id
    end)
    while #rows > 12 do table.remove(rows) end
    return rows
end

local function model(ctx, count: number)
    local hidden = ctx.data.hiddenBar
    local apps = (hidden and hidden.items) or {}
    local mediaHeight = if (not frame.framed(ctx.data.settings) or ctx.data.media) and not cards.out(ctx, "player-album") then 148 else 0
    local top = 8 + mediaHeight + (if mediaHeight > 0 then 8 else 0)
    local taskHeight = math.min(math.max(1, count), 6) * 40 - 4
    local trayTop = top + taskHeight + 8
    local trayCount = math.min(#apps, 3)
    local bottom = if trayCount > 0 then trayTop + 26 + trayCount * 40 - 4 else top + taskHeight
    return { apps = apps, trayCount = trayCount, top = top, taskHeight = taskHeight,
        trayTop = trayTop, height = bottom + 11.5 }
end

local function height(ctx)
    local count = 0
    local bar = ctx.data.bar
    for _, workspace in (bar and bar.workspaces) or {} do
        for _, app in workspace.windows do count += #app.windows end
    end
    local m = model(ctx, math.min(count, 12))
    if not frame.framed(ctx.data.settings) and cards.out(ctx, "player-windows") then
        return if cards.out(ctx, "player-album") then 22 else 176
    end
    return m.height
end

local function label(c, key, value, x, y, size, color, weight, width)
    return kit.label(c, { key = key, text = value, align = "leading", x = x * c.du, y = y * c.du,
        size = size, color = color, weight = weight, maxWidth = width * c.du, lines = 1, decorative = true })
end

local function hover(name, id)
    return function(next, event)
        if event.phase == "began" then next.state[name] = id
        elseif next.state[name] == id then next.state[name] = nil end
    end
end

local function taskRow(ctx, p, task)
    local cu = p.cu
    local c = kit.canvas(288 * cu, 36 * cu, cu, p.rs)
    local hot = ctx.state.playerTaskHot == task.id
    local closing = ctx.state.playerCloseHot == task.id
    return ui.stack({ key = "player-task-" .. task.id, w = c.w, h = c.h, align = "topLeading", radius = 12 * cu,
        fill = palette.alpha("ink", if task.active then 0.11 else 0.05),
        hover = palette.alpha("ink", if task.active then 0.19 else 0.13), cursor = "pointer",
        onHover = hover("playerTaskHot", task.id),
        onPress = function(next, event)
            if event.phase ~= "down" then return end
            if event.button == "middle" then omniwm.run("window close " .. task.id)
            elseif event.button == "left" then
                omniwm.run("window focus " .. task.id)
                p.close(next)
            end
        end,
        ui.icon({ key = "player-task-icon-" .. task.id, app = task.app, placeholder = "app",
            w = 22 * cu, h = 22 * cu, align = "topLeading", dx = 8 * cu, dy = 7 * cu }),
        label(c, "player-task-title-" .. task.id, task.title, 38, 18, 14.5,
            if task.active then palette.roles.mint else palette.roles.ink, if task.active then "bold" else nil, 186),
        ui.stack(kit.at(c, { key = "player-task-badge-" .. task.id, w = 24 * cu, h = 18 * cu,
            radius = 9 * cu, fill = palette.alpha("ink", 0.08),
            kit.label(kit.canvas(24 * cu, 18 * cu, cu, p.rs), { key = "player-task-workspace-" .. task.id, text = task.workspace,
                size = 12, weight = "bold", opacity = 0.8, maxWidth = 24 * cu, lines = 1 }),
        }, 240 * cu, 18 * cu)),
        ui.stack(kit.at(c, { key = "player-task-close-" .. task.id, w = 22 * cu, h = 22 * cu, cursor = "pointer",
            onHover = hover("playerCloseHot", task.id), onClick = "window close " .. task.id,
            ui.box({ w = 20 * cu, h = 20 * cu, radius = 10 * cu,
                fill = palette.alpha(if closing then "alert" else "ink", if closing then 0.9 else 0.09),
                opacity = if hot then 1 else 0 }),
            ui.path({ w = 22 * cu, h = 22 * cu, decorative = true, opacity = if hot then 0.7 else 0,
                d = string.format("M %.3f %.3f L %.3f %.3f M %.3f %.3f L %.3f %.3f",
                    7.5 * cu, 7.5 * cu, 14.5 * cu, 14.5 * cu, 14.5 * cu, 7.5 * cu, 7.5 * cu, 14.5 * cu),
                fill = 0, border = palette.roles.ink, borderWidth = 1.4 * cu }),
        }, 268 * cu, 18 * cu)),
    })
end

local function background(p, app)
    local cu = p.cu
    local c = kit.canvas(288 * cu, 36 * cu, cu, p.rs)
    return ui.stack({ key = "player-background-" .. app.id, w = c.w, h = c.h, radius = 12 * cu,
        fill = palette.alpha("ink", 0.05), hover = palette.alpha("ink", 0.13), cursor = "pointer",
        onClick = "hidden-bar activate " .. app.id,
        if app.image then ui.image({ image = app.image, w = 22 * cu, h = 22 * cu, align = "topLeading",
            dx = 8 * cu, dy = 7 * cu }) else ui.symbol({ name = "app.dashed", size = 20 * cu, color = palette.roles.faint,
            align = "topLeading", dx = 8 * cu, dy = 7 * cu }),
        label(c, nil, app.name, 38, 18, 14.5, palette.roles.ink, nil, 236),
    })
end

local function windowList(ctx, p)
    local rows, cu = tasks(ctx), p.cu
    local m = model(ctx, #rows)
    local c = kit.canvas(p.w, p.h, cu, p.rs)
    local items = { key = "player-f3", w = p.w, h = p.h - (p.header or 0), align = "topLeading", dy = p.header or 0,
        appear = { opacity = 0, dy = 12 * cu, delay = 0.2, animate = entrance },
        exit = { opacity = 0, dy = 12 * cu, animate = kit.springs.close },
    }
    local list = { key = "player-tasks", w = 288 * cu, h = m.taskHeight * cu, align = "topLeading",
        dx = (p.w - 288 * cu) / 2, dy = m.top * cu, gap = 4 * cu, center = false, scroll = true,
    }
    for _, task in rows do list[#list + 1] = taskRow(ctx, p, task) end
    if #rows == 0 then
        list[#list + 1] = ui.stack({ w = 288 * cu, h = 36 * cu,
            kit.label(kit.canvas(288 * cu, 36 * cu, cu, p.rs), { key = "player-empty", text = "No active windows",
                size = 14, color = palette.roles.faint }),
        })
    end
    items[#items + 1] = ui.column(list)
    if m.trayCount > 0 then
        items[#items + 1] = label(c, "player-background-heading", "BACKGROUND APPS", 26, m.trayTop + 11,
            15.5, palette.roles.ink, "bold", 276)
        local apps = { key = "player-background-list", w = 288 * cu, gap = 4 * cu,
            dx = (p.w - 288 * cu) / 2, dy = (m.trayTop + 26) * cu, align = "topLeading", center = false }
        for index = 1, m.trayCount do apps[#apps + 1] = background(p, m.apps[index]) end
        items[#items + 1] = ui.column(apps)
    end
    return { ui.stack(items) }
end

local function content(ctx, p)
    if p.frame then return windowList(ctx, p) end
    local m = model(ctx, #tasks(ctx))
    local result = {}
    if not cards.out(ctx, "player-windows") then result[#result + 1] = cards.placeholder(p, "player-windows", 0,
        m.top + (p.header or 0) / p.cu, 328, math.max(36, m.height - m.top)) end
    if not cards.out(ctx, "player-album") then result[#result + 1] = cards.placeholder(p, "player-album", 10,
        (p.header or 0) / p.cu - 2, 308, 168) end
    return result
end

local function sections(ctx, p)
    local m = model(ctx, #tasks(ctx))
    return { { id = "player-windows", gripY = math.max(0, m.height - m.top - 10), x = 0, y = m.top + (p.header or 0) / p.cu, w = 328, h = math.max(36, m.height - m.top),
        content = function(next, offer)
            local full = table.clone(offer)
            full.h += m.top * offer.cu
            local items = windowList(next, full)
            return { ui.stack({ w = offer.w, h = full.h, align = "topLeading", dy = -m.top * offer.cu,
                table.unpack(items) }) }
        end } }
end

return table.freeze({ content = content, height = height, sections = sections })
