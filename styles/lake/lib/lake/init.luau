local function extend(base, changes)
    local result = table.clone(base)
    for key, value in changes do
        if key == "views" then
            result.views = table.clone(base.views or {})
            for name, view in value do result.views[name] = view end
        else
            result[key] = value
        end
    end
    return result
end

return table.freeze({ extend = extend })
