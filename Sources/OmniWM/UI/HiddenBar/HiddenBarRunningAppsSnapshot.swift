// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct MenuBarAppCandidate: Equatable, Sendable {
    let bundleID: String
    let pid: pid_t
}

struct HiddenBarRunningAppsSnapshot {
    let bundleIDs: Set<String>
    let candidates: [MenuBarAppCandidate]

    static func current() -> HiddenBarRunningAppsSnapshot {
        let applications = NSWorkspace.shared.runningApplications
        var bundleIDs: Set<String> = []
        var candidates: [MenuBarAppCandidate] = []
        bundleIDs.reserveCapacity(applications.count)
        candidates.reserveCapacity(applications.count)
        for app in applications {
            guard let bundleID = app.bundleIdentifier else { continue }
            bundleIDs.insert(bundleID)
            candidates.append(MenuBarAppCandidate(bundleID: bundleID, pid: app.processIdentifier))
        }
        return HiddenBarRunningAppsSnapshot(bundleIDs: bundleIDs, candidates: candidates)
    }

    static func menuOwnerPIDs(for bundleIDs: Set<String>) -> Set<pid_t> {
        guard !bundleIDs.isEmpty else { return [] }
        return Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.bundleIdentifier.map(bundleIDs.contains) == true ? app.processIdentifier : nil
        })
    }

    func verifiedMenuItemBundleIDs(
        for itemsByBundleID: [String: [ResolvedMenuBarItem]],
        ownerBundleID: (pid_t) -> String? = { pid in
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bundleURL = app.bundleURL, let executableURL = app.executableURL,
                  let bundle = Bundle(url: bundleURL),
                  bundle.bundleIdentifier == app.bundleIdentifier,
                  bundle.executableURL == executableURL
            else { return nil }
            return app.bundleIdentifier
        }
    ) -> Set<String> {
        Set(itemsByBundleID.compactMap { bundleID, items in
            guard items.contains(where: { item in
                item.key.bundleID == bundleID
                    && candidates.contains(MenuBarAppCandidate(bundleID: bundleID, pid: item.pid))
                    && ownerBundleID(item.pid) == bundleID
            }) else { return nil }
            return bundleID
        })
    }
}
