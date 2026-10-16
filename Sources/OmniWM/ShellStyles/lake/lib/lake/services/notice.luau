local function emit(instance, kind)
    local state = instance.state
    state.noticeSerial = (state.noticeSerial or 0) % 2147483647 + 1
    state.notice = { id = kind .. ":" .. tostring(state.noticeSerial), seconds = math.clamp(instance.options.alertSeconds or 4, 1, 10) }
end

return table.freeze({ emit = emit })
