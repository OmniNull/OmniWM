local function init(instance)
    local saved = omniwm.store.get("note")
    instance.state.text = if type(saved) == "string" then saved else ""
end

local function save(instance, text)
    instance.state.text = text
    local accepted, err = omniwm.store.set("note", text)
    instance.state.error = if accepted then nil else tostring(err)
end

local function copy(instance, text)
    local request, err = omniwm.clipboard.copy(text, function(result)
        instance.state.error = if result.ok then nil else tostring(result.error)
    end)
    if not request then instance.state.error = tostring(err) end
end

return table.freeze({ init = init, save = save, copy = copy })
