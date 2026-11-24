// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin

@MainActor
final class ConfigScriptEventInput {
    let apps: AppInfoCache
    var session: ConfigScriptSessionToken

    func cachedBundleID(for pid: pid_t) -> String? {
        apps.cachedBundleId(for: pid)
    }

    init(_ controller: WMController) {
        apps = controller.appInfoCache
        session = controller.scriptSession
    }
}

extension WMController {
    func registerConfigEventInput() -> ConfigScriptEventInput {
        if let registeredEventInput { return registeredEventInput }
        let input = ConfigScriptEventInput(self)
        registeredEventInput = input
        return input
    }
}
