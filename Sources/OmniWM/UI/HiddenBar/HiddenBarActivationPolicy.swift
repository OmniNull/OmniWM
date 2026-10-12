// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit

struct HiddenBarActivationOwner: Equatable, Sendable {
    let pid: pid_t
    let allowsAuthoritativeEmpty: Bool
}

enum HiddenBarActivationPolicy {
    nonisolated static func activationTarget(
        for key: MenuBarItemKey,
        cachedItems: [ResolvedMenuBarItem]?,
        cachedIcons: [MenuBarItemKey: CapturedIcon],
        freshItems: [ResolvedMenuBarItem],
        freshIcons: [MenuBarItemKey: CapturedIcon]
    ) -> ResolvedMenuBarItem? {
        guard let cachedItem = cachedItems?.first(where: { $0.key == key }) else { return nil }
        let cachedSameProcessItems = cachedItems?.filter { $0.pid == cachedItem.pid } ?? []
        let freshSameProcessItems = freshItems.filter { $0.pid == cachedItem.pid }
        if let semanticIdentity = cachedItem.semanticIdentity {
            guard cachedSameProcessItems.count(where: { $0.semanticIdentity == semanticIdentity }) == 1 else {
                return nil
            }
            let matches = freshSameProcessItems.filter { $0.semanticIdentity == semanticIdentity }
            return matches.count == 1 ? matches[0] : nil
        }
        if cachedSameProcessItems.count == 1, freshSameProcessItems.count == 1,
           let item = freshSameProcessItems.first, item.semanticIdentity == nil
        {
            return item
        }
        guard let cachedIcon = cachedIcons[key] else { return nil }
        guard cachedSameProcessItems.allSatisfy({ cachedIcons[$0.key] != nil }),
              freshSameProcessItems.allSatisfy({ freshIcons[$0.key] != nil }),
              cachedSameProcessItems.count(where: { item in
                  guard let icon = cachedIcons[item.key] else { return false }
                  return HiddenBarIconCache.isVisuallyEqual(cachedIcon, icon)
              }) == 1
        else { return nil }
        let matches = freshSameProcessItems.filter { item in
            guard let freshIcon = freshIcons[item.key] else { return false }
            return HiddenBarIconCache.isVisuallyEqual(cachedIcon, freshIcon)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated static func activationOwner(
        bundleID: String,
        selectedItem: ResolvedMenuBarItem?,
        cachedItems: [ResolvedMenuBarItem]?,
        runningCandidates: [MenuBarAppCandidate]
    ) -> HiddenBarActivationOwner? {
        let candidatePIDs = Set(
            runningCandidates.lazy
                .filter { $0.bundleID == bundleID }
                .map(\.pid)
        )
        if let selectedItem {
            guard selectedItem.key.bundleID == bundleID,
                  candidatePIDs.contains(selectedItem.pid)
            else { return nil }
            return HiddenBarActivationOwner(pid: selectedItem.pid, allowsAuthoritativeEmpty: true)
        }
        let cachedPIDs = Set(
            (cachedItems ?? []).lazy
                .filter { $0.key.bundleID == bundleID }
                .map(\.pid)
        )
        if !cachedPIDs.isEmpty {
            guard cachedPIDs.count == 1, let pid = cachedPIDs.first,
                  candidatePIDs.contains(pid)
            else { return nil }
            return HiddenBarActivationOwner(pid: pid, allowsAuthoritativeEmpty: true)
        }
        guard candidatePIDs.count == 1, let pid = candidatePIDs.first else { return nil }
        return HiddenBarActivationOwner(pid: pid, allowsAuthoritativeEmpty: false)
    }

    nonisolated static func shouldResumeReconcealAfterFailedReveal(
        hasTemporaryReveals: Bool,
        activationInFlight: Bool
    ) -> Bool {
        hasTemporaryReveals && !activationInFlight
    }

    nonisolated static func activationContextIsValid(
        bundleID: String,
        pid: pid_t,
        configuredBundleIDs: Set<String>,
        temporarilyRevealedBundleIDs: Set<String>,
        runningCandidates: [MenuBarAppCandidate]
    ) -> Bool {
        configuredBundleIDs.contains(bundleID)
            && temporarilyRevealedBundleIDs.contains(bundleID)
            && runningCandidates.contains { $0.bundleID == bundleID && $0.pid == pid }
    }
}
