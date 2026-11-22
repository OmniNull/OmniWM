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
        isWineWindow(facts) && facts.ax.isMain == true
    }

    static func isNonMainUnknownWindow(_ facts: WindowRuleFacts) -> Bool {
        isWineWindow(facts)
            && facts.ax.isMain != true
            && facts.ax.subrole == (kAXUnknownSubrole as String)
    }

    private static func isWineWindow(_ facts: WindowRuleFacts) -> Bool {
        facts.ax.attributeFetchSucceeded
            && facts.ax.role == (kAXWindowRole as String)
            && isWineProcess(bundleId: facts.ax.bundleId, appName: facts.appName)
    }
}
