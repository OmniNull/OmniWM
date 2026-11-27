// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension SettingsStore {
    func publishConfigScriptErrors(load: String?, callback: String?) {
        let callbackChanged = callback != configScriptCallbackError
        if callbackChanged { configScriptCallbackError = callback }
        if load != configScriptLoadError {
            configScriptLoadError = load
        } else if callbackChanged {
            onConfigScriptCallbackErrorChanged?()
        }
    }
}
