// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices

struct MenuBarItemKey: Hashable, Sendable {
    let bundleID: String
    let ordinal: Int
}

struct MenuBarItemSemanticIdentity: Equatable, Hashable, Sendable {
    let identifier: String?
    let title: String?
    let accessibilityDescription: String?
    let help: String?
}

struct ResolvedMenuBarItem: Sendable {
    let key: MenuBarItemKey
    let pid: pid_t
    let bounds: CGRect
    let semanticIdentity: MenuBarItemSemanticIdentity?

    init(
        key: MenuBarItemKey,
        pid: pid_t,
        bounds: CGRect,
        semanticIdentity: MenuBarItemSemanticIdentity? = nil
    ) {
        self.key = key
        self.pid = pid
        self.bounds = bounds
        self.semanticIdentity = semanticIdentity
    }
}

struct MenuBarItemResolution: Sendable {
    let itemsByBundleID: [String: [ResolvedMenuBarItem]]

    static let empty = MenuBarItemResolution(itemsByBundleID: [:])

    var items: [ResolvedMenuBarItem] {
        itemsByBundleID.values.flatMap { $0 }
    }
}

struct MenuBarItemActivationCandidate: Sendable {
    let pid: pid_t
    let useAXPress: Bool
}

enum MenuBarItemActivation: Sendable {
    case axPressed
    case clickFrame(CGRect)
    case unavailable
}

enum MenuBarItemLocator {
    private static let messagingTimeoutSeconds: Float = 0.1
    private static let settlePollInterval: TimeInterval = 0.05
    private static let locateDeadline: Duration = .seconds(2)

    static func resolveItems(
        candidates: [MenuBarAppCandidate],
        bundleIDs: Set<String>,
        allowEmptyBundleIDs: Set<String>,
        job: RunLoopJob
    ) throws -> MenuBarItemResolution {
        guard !bundleIDs.isEmpty else { return .empty }

        var resolved: [String: [ResolvedMenuBarItem]] = [:]
        let clock = ContinuousClock()
        var tracker = MenuBarItemSampleTracker(clock: clock, startedAt: clock.now)
        while resolved.count < bundleIDs.count {
            guard tracker.shouldContinue(at: clock.now) else { break }
            try job.checkCancellation()
            for bundleID in bundleIDs where resolved[bundleID] == nil {
                try job.checkCancellation()
                if let items = try resolveStableItems(
                    candidates: candidates,
                    bundleID: bundleID,
                    allowEmptyBundleIDs: allowEmptyBundleIDs,
                    job: job,
                    tracker: &tracker
                ) {
                    resolved[bundleID] = items
                }
            }
            if resolved.count < bundleIDs.count {
                Thread.sleep(forTimeInterval: settlePollInterval)
            }
        }
        for bundleID in allowEmptyBundleIDs where resolved[bundleID] == nil {
            try job.checkCancellation()
            guard let pid = tracker.authoritativeEmptyPID(for: bundleID),
                  let sample = try itemSample(
                      candidates: candidates,
                      bundleID: bundleID,
                      allowEmpty: true,
                      job: job
                  ),
                  sample.pid == pid, sample.items.isEmpty
            else { continue }
            resolved[bundleID] = []
        }
        return MenuBarItemResolution(itemsByBundleID: resolved)
    }

    private static func resolveStableItems(
        candidates: [MenuBarAppCandidate],
        bundleID: String,
        allowEmptyBundleIDs: Set<String>,
        job: RunLoopJob,
        tracker: inout MenuBarItemSampleTracker
    ) throws -> [ResolvedMenuBarItem]? {
        let attempt = tracker.beginAttempt(for: bundleID)
        guard let sample = try itemSample(
            candidates: candidates,
            bundleID: bundleID,
            allowEmpty: allowEmptyBundleIDs.contains(bundleID),
            job: job
        ) else {
            tracker.discardSample(for: bundleID)
            return nil
        }
        let frames = sample.items.map(\.frame)
        guard tracker.recordSample(pid: sample.pid, frames: frames, for: bundleID, attempt: attempt) else {
            return nil
        }
        return sample.items.enumerated().map { ordinal, item in
            ResolvedMenuBarItem(
                key: MenuBarItemKey(bundleID: bundleID, ordinal: ordinal),
                pid: sample.pid,
                bounds: item.frame,
                semanticIdentity: semanticIdentity(of: item.element)
            )
        }
    }

    static func activate(
        candidates: [MenuBarItemActivationCandidate],
        target: ResolvedMenuBarItem,
        job: RunLoopJob
    ) throws -> MenuBarItemActivation {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: locateDeadline)
        var previousFrames: [pid_t: CGRect] = [:]

        while clock.now < deadline {
            try job.checkCancellation()
            for candidate in candidates where candidate.pid == target.pid {
                try job.checkCancellation()
                guard let elements = itemElements(pid: candidate.pid), target.key.ordinal < elements.count else {
                    previousFrames.removeValue(forKey: candidate.pid)
                    continue
                }
                let item = elements[target.key.ordinal]
                guard item.frame == target.bounds else {
                    previousFrames.removeValue(forKey: candidate.pid)
                    continue
                }
                if item.frame == previousFrames[candidate.pid] {
                    try job.checkCancellation()
                    guard semanticIdentity(of: item.element) == target.semanticIdentity else { return .unavailable }
                    if candidate.useAXPress {
                        if performAXAction(
                            item.element,
                            "AXPress" as CFString,
                            noteKey: "hiddenBarAXPressFailed"
                        ) == .success {
                            return .axPressed
                        }
                    }
                    return .clickFrame(item.frame)
                }
                previousFrames[candidate.pid] = item.frame
            }
            Thread.sleep(forTimeInterval: settlePollInterval)
        }
        return .unavailable
    }

    private static func itemSample(
        candidates: [MenuBarAppCandidate],
        bundleID: String,
        allowEmpty: Bool,
        job: RunLoopJob
    ) throws -> (pid: pid_t, items: [MenuBarItemElement])? {
        var emptyPID: pid_t?
        for candidate in candidates where candidate.bundleID == bundleID {
            try job.checkCancellation()
            guard let items = itemElements(pid: candidate.pid) else { continue }
            if !items.isEmpty {
                return (candidate.pid, items)
            }
            if emptyPID == nil {
                emptyPID = candidate.pid
            }
        }
        guard allowEmpty, let emptyPID else { return nil }
        return (emptyPID, [])
    }

    private struct MenuBarItemElement {
        let element: AXUIElement
        let frame: CGRect
    }

    private static func itemElements(pid: pid_t) -> [MenuBarItemElement]? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)
        defer { AXUIElementSetMessagingTimeout(appElement, 0) }

        var extrasRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXExtrasMenuBar" as CFString, &extrasRef) == .success,
              let extras = extrasRef, CFGetTypeID(extras) == AXUIElementGetTypeID()
        else { return nil }

        let extrasElement = unsafeDowncast(extras as AnyObject, to: AXUIElement.self)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(extrasElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }

        var items: [MenuBarItemElement] = []
        items.reserveCapacity(children.count)
        for child in children {
            guard let frame = frame(of: child), !frame.isEmpty else { return nil }
            items.append(MenuBarItemElement(
                element: child,
                frame: frame
            ))
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    private static func semanticIdentity(of element: AXUIElement) -> MenuBarItemSemanticIdentity? {
        if let identifier = stringAttribute("AXIdentifier", of: element) {
            return MenuBarItemSemanticIdentity(
                identifier: identifier,
                title: nil,
                accessibilityDescription: nil,
                help: nil
            )
        }
        let identity = MenuBarItemSemanticIdentity(
            identifier: nil,
            title: stringAttribute(kAXTitleAttribute, of: element),
            accessibilityDescription: stringAttribute(kAXDescriptionAttribute, of: element),
            help: stringAttribute(kAXHelpAttribute, of: element)
        )
        guard identity.identifier != nil || identity.title != nil
            || identity.accessibilityDescription != nil || identity.help != nil
        else { return nil }
        return identity
    }

    private static func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let value = valueRef as? String
        else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &valueRef) == .success,
              let valueRef, CFGetTypeID(valueRef) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        let value = unsafeDowncast(valueRef as AnyObject, to: AXValue.self)
        guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
        return rect
    }
}
