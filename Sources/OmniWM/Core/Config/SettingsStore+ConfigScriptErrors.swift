// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

extension SettingsStore {
    func publishConfigScriptErrors(
        load: String?, callback: String?, overrides: [ConfigScriptShortcutOverride]? = nil
    ) {
        let callbackChanged = callback != configScriptCallbackError
        if callbackChanged { configScriptCallbackError = callback }
        let conflictsChanged = if let overrides {
            overrides != (configScriptShortcutConflicts?.overrides ?? [])
        } else {
            false
        }
        if conflictsChanged, let overrides {
            configScriptShortcutConflicts = ConfigScriptShortcutConflicts(overrides)
        }
        if load != configScriptLoadError {
            configScriptLoadError = load
            onConfigNoticeChanged?()
        } else if callbackChanged || conflictsChanged {
            onConfigScriptNoticeChanged?()
        }
    }
}
