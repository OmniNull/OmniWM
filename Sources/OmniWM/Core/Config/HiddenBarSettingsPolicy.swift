// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum HiddenBarSettingsPolicy {
    static let protectedSystemHostBundleIDs: Set<String> = [
        "com.apple.MenuBarAgent",
        "com.apple.controlcenter",
        "com.apple.systemuiserver"
    ]

    static func normalizedBundleIDs(
        _ bundleIDs: [String],
        additionalProtectedBundleIDs: Set<String> = []
    ) -> [String] {
        var seen: Set<String> = []
        var normalized: [String] = []
        normalized.reserveCapacity(bundleIDs.count)
        for rawBundleID in bundleIDs {
            let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bundleID.isEmpty,
                  !protectedSystemHostBundleIDs.contains(bundleID),
                  !additionalProtectedBundleIDs.contains(bundleID),
                  seen.insert(bundleID).inserted
            else { continue }
            normalized.append(bundleID)
        }
        return normalized
    }

    static func validatedRehideIntervalSeconds(_ value: Double) -> Double {
        guard value.isFinite else { return SettingsExport.HiddenBar.defaults().rehideIntervalSeconds }
        return min(max(value, 2), 30)
    }
}
