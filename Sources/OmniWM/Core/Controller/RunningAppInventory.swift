// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct RunningAppInfo: Identifiable {
    let id: String
    let pid: pid_t?
    let bundleId: String?
    let appName: String
    let icon: NSImage?
    let windowSize: CGSize

    var trackedWindowSize: CGSize? {
        guard windowSize.width > 0, windowSize.height > 0 else { return nil }
        return windowSize
    }
}

struct TrackedAppGroups {
    struct App {
        let token: WindowToken
        let bundleId: String?
        let displayName: String
        let hasName: Bool
    }

    private enum Identity: Hashable {
        case bundle(String)
        case process(pid_t)
    }

    private var seen: Set<Identity> = []
    private var visitedProcesses: Set<pid_t> = []
    private var tokens: [WindowToken] = []
    private(set) var apps: [App] = []
    private(set) var order: [Int] = []
    private var mergedOrder: [Int] = []

    @MainActor
    mutating func collect(
        windows: WindowModel.ReadView, cache: AppInfoCache, liveIcon: ((WindowToken, NSImage?) -> Void)? = nil
    ) {
        seen.removeAll(keepingCapacity: true)
        visitedProcesses.removeAll(keepingCapacity: true)
        apps.removeAll(keepingCapacity: true)
        windows.collectStandardWindowTokens(into: &tokens)
        for token in tokens {
            if let liveIcon {
                let info = cache.info(for: token.pid)
                if append(token, bundleId: info?.bundleId, name: info?.name) { liveIcon(token, info?.icon) }
            } else {
                guard visitedProcesses.insert(token.pid).inserted else { continue }
                cache.withCachedIdentity(for: token.pid) { bundleId, name in
                    _ = append(token, bundleId: bundleId, name: name)
                }
            }
        }
        order.removeAll(keepingCapacity: true)
        order.append(contentsOf: apps.indices)
        var runLength = 1
        while runLength < order.count {
            mergeOrder(runLength: runLength)
            swap(&order, &mergedOrder)
            runLength *= 2
        }
    }

    static func key(bundleId: String?, pid: pid_t) -> String {
        bundleId ?? "pid:\(pid)"
    }

    private mutating func append(
        _ token: WindowToken, bundleId: borrowing String?, name: borrowing String?
    ) -> Bool {
        let identity = (copy bundleId).map(Identity.bundle) ?? .process(token.pid)
        guard seen.insert(identity).inserted else { return false }
        apps.append(App(
            token: token, bundleId: copy bundleId, displayName: (copy name) ?? "Unknown", hasName: name != nil
        ))
        return true
    }

    private mutating func mergeOrder(runLength: Int) {
        mergedOrder.removeAll(keepingCapacity: true)
        mergedOrder.reserveCapacity(order.count)
        let apps = apps.span
        let indices = order.span
        for start in stride(from: 0, to: indices.count, by: runLength * 2) {
            let middle = min(start + runLength, indices.count)
            let end = min(middle + runLength, indices.count)
            var left = start
            var right = middle
            while left < middle, right < end {
                if apps[indices[right]].displayName < apps[indices[left]].displayName {
                    mergedOrder.append(indices[right])
                    right += 1
                } else {
                    mergedOrder.append(indices[left])
                    left += 1
                }
            }
            for index in left ..< middle { mergedOrder.append(indices[index]) }
            for index in right ..< end { mergedOrder.append(indices[index]) }
        }
    }
}

enum RunningAppInventory {
    @MainActor
    static func rulePickerCandidates(
        trackedApplications: [RunningAppInfo],
        runningApplications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> [RunningAppInfo] {
        let systemApplications = runningApplications.compactMap { app -> RunningAppInfo? in
            guard app.activationPolicy == .regular else { return nil }
            let bundleId = app.bundleIdentifier
            return RunningAppInfo(
                id: bundleId ?? "pid:\(app.processIdentifier)",
                pid: app.processIdentifier,
                bundleId: bundleId,
                appName: app.localizedName
                    ?? app.executableURL?.deletingPathExtension().lastPathComponent
                    ?? bundleId
                    ?? "Process \(app.processIdentifier)",
                icon: app.icon,
                windowSize: .zero
            )
        }
        return merge(systemApplications: systemApplications, trackedApplications: trackedApplications)
    }

    static func merge(
        systemApplications: [RunningAppInfo],
        trackedApplications: [RunningAppInfo]
    ) -> [RunningAppInfo] {
        var applicationsById: [String: RunningAppInfo] = [:]
        for application in systemApplications where applicationsById[application.id] == nil {
            applicationsById[application.id] = application
        }
        let applicationIdByPidId = Dictionary(
            uniqueKeysWithValues: systemApplications.compactMap { app in
                app.pid.map { ("pid:\($0)", app.id) }
            }
        )

        for tracked in trackedApplications {
            let id = applicationsById[tracked.id] != nil
                ? tracked.id
                : applicationIdByPidId[tracked.id] ?? tracked.id
            guard let system = applicationsById[id] else {
                applicationsById[id] = tracked
                continue
            }
            applicationsById[id] = RunningAppInfo(
                id: id,
                pid: tracked.pid ?? system.pid,
                bundleId: tracked.bundleId ?? system.bundleId,
                appName: tracked.appName == "Unknown" ? system.appName : tracked.appName,
                icon: tracked.icon ?? system.icon,
                windowSize: tracked.windowSize
            )
        }

        return applicationsById.values.sorted {
            let nameOrder = $0.appName.localizedStandardCompare($1.appName)
            return nameOrder == .orderedSame ? $0.id < $1.id : nameOrder == .orderedAscending
        }
    }
}
