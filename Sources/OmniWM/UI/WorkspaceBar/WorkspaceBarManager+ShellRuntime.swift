// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMAutomation

extension WorkspaceBarManager {
    func applyShellRuntimeRequest(_ request: borrowing ShellRuntimeRequest) -> ExternalCommandResult {
        switch request {
        case let .set(key, value):
            let previous = shellVars[key]
            if let previous, previous.utf8.elementsEqual(value.utf8) { return .executed }
            guard previous != nil || shellVars.count < ShellRuntimeLimits.countLimit else { return .invalidArguments }
            shellVars[key] = value
        case let .unset(key):
            guard shellVars.removeValue(forKey: key) != nil else { return .noChange }
        case let .toggle(widget):
            return toggleShell(widget) ? .executed : .notFound
        case let .trigger(widget, name, value):
            return shellHost?.trigger(widget, name: name, value: value) == true ? .executed : .notFound
        }
        shellHost?.updateVars()
        return .executed
    }
}
