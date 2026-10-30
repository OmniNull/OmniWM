-- SPDX-License-Identifier: GPL-2.0-only
-- Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

local limit = 9
local textLimit = 1024
local idLimit = 2147483647

local function clean(text)
    if type(text) ~= "string" or not utf8.len(text) then return nil end
    local trimmed = string.match(text, "^%s*(.-)%s*$")
    local stop = math.min(#trimmed, textLimit)
    while stop > 0 and not utf8.len(string.sub(trimmed, 1, stop)) do
        stop -= 1
    end
    trimmed = string.sub(trimmed, 1, stop)
    return if trimmed == "" then nil else trimmed
end

local function save(instance)
    local saved, err = omniwm.store.set("tasks", { items = instance.state.items })
    instance.state.error = if saved then nil else "Not saved: " .. tostring(err)
end

local function init(instance)
    local items, used, top = {}, {}, 0
    local cached = omniwm.store.get("tasks")
    local list = type(cached) == "table" and cached.items
    if type(list) == "table" then
        for _, entry in ipairs(list) do
            if #items >= limit then break end
            local text = type(entry) == "table" and clean(entry.text)
            if text then
                local id = entry.id
                local item = { text = text, done = entry.done == true }
                if type(id) == "number" and id % 1 == 0 and id >= 1 and id <= idLimit and not used[id] then
                    item.id = id
                    used[id] = true
                    top = math.max(top, id)
                end
                items[#items + 1] = item
            end
        end
    end
    for _, item in items do
        if not item.id then
            top += 1
            item.id = top
        end
    end
    instance.state.items = items
    instance.state.top = top
    instance.state.error = nil
end

local function find(instance, id)
    for index, item in instance.state.items do
        if item.id == id then return index, item end
    end
    return nil, nil
end

local function add(instance, text)
    local value = clean(text)
    local items = instance.state.items
    if not value or #items >= limit or instance.state.top >= idLimit then return false end
    instance.state.top += 1
    items[#items + 1] = { id = instance.state.top, text = value, done = false }
    save(instance)
    return true
end

local function toggle(instance, id)
    local _, item = find(instance, id)
    if not item then return end
    item.done = not item.done
    save(instance)
end

local function remove(instance, id)
    local index = find(instance, id)
    if not index then return end
    table.remove(instance.state.items, index)
    save(instance)
end

return table.freeze({ limit = limit, init = init, add = add, toggle = toggle, remove = remove })
