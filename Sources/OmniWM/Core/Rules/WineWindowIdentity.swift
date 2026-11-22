// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

enum WineWindowIdentity {
    static let crossOverHelperBundleIdPrefix = "com.codeweavers.crossoverhelper."
    static let windowsExecutableSuffix = ".exe"

    static func isWineProcess(bundleId: String?, appName: String?) -> Bool {
        if let bundleId, !bundleId.isEmpty {
            return bundleId.lowercased().hasPrefix(crossOverHelperBundleIdPrefix)
        }
        guard let appName else { return false }
        return appName.lowercased().hasSuffix(windowsExecutableSuffix)
    }

    static func isMainWindow(_ facts: WindowRuleFacts) -> Bool {
        facts.ax.attributeFetchSucceeded
            && facts.ax.role == (kAXWindowRole as String)
            && facts.ax.isMain == true
            && isWineProcess(bundleId: facts.ax.bundleId, appName: facts.appName)
    }
}
